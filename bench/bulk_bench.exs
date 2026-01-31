#!/usr/bin/env elixir

# Bulk Insert Benchmark - Detailed bulk insertion analysis
#
# Tests bulk insertion performance at various batch sizes.
#
# Usage:
#   mix bench.bulk
#
# Options:
#   --sizes 10000,50000,100000   Comma-separated list of job counts
#   --runs N                     Number of runs per test (default: 3)

defmodule BulkBenchmark do
  @moduledoc """
  Detailed bulk insertion benchmark comparing BullMQ and Oban
  at various job counts to analyze scaling characteristics.
  """

  alias BullmqObanBench.Repo
  alias BullmqObanBench.ObanWorker
  alias BullMQ.{Queue, RedisConnection}

  @default_sizes [10_000, 50_000, 100_000]
  @default_runs 3

  def run(opts \\ []) do
    sizes = Keyword.get(opts, :sizes, @default_sizes)
    runs = Keyword.get(opts, :runs, @default_runs)

    redis_config = Application.get_env(:bullmq_oban_bench, :redis)
    redis_opts = [host: redis_config[:host], port: redis_config[:port]]

    IO.puts("""

    ╔═══════════════════════════════════════════════════════════════════════════════╗
    ║           Bulk Insert Benchmark - Scaling Analysis                            ║
    ╠═══════════════════════════════════════════════════════════════════════════════╣
    ║  Testing bulk insert performance at various job counts                        ║
    ╚═══════════════════════════════════════════════════════════════════════════════╝

    Configuration:
      Job counts: #{inspect(sizes)}
      Runs per test: #{runs} (best result used)

    """)

    # Setup
    redis_conn = :bulk_bench_redis
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: redis_conn))
    ensure_oban_running()

    results = for size <- sizes do
      IO.puts("═══════════════════════════════════════════════════════════════════════════════")
      IO.puts("  Testing #{format_number(size)} jobs")
      IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

      bullmq_results = run_multiple(runs, fn ->
        IO.write("    BullMQ run... ")
        rate = benchmark_bullmq_bulk(redis_conn, size)
        IO.puts("#{format_rate(rate)} jobs/sec")
        rate
      end)

      oban_results = run_multiple(runs, fn ->
        IO.write("    Oban run... ")
        rate = benchmark_oban_bulk(size)
        IO.puts("#{format_rate(rate)} jobs/sec")
        rate
      end)

      bullmq_best = Enum.max(bullmq_results)
      oban_best = Enum.max(oban_results)

      IO.puts("\n  Best: BullMQ #{format_rate(bullmq_best)} vs Oban #{format_rate(oban_best)}\n")

      {size, bullmq_best, oban_best}
    end

    print_summary(results, runs)

    # Cleanup
    stop_oban()
    GenServer.stop(redis_conn)
  end

  defp run_multiple(n, fun) do
    Enum.map(1..n, fn _ ->
      result = fun.()
      Process.sleep(500)
      result
    end)
  end

  defp benchmark_bullmq_bulk(conn, count) do
    queue_name = "bulk_bench_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq(conn, queue_name)

    jobs = for i <- 1..count, do: {"job", %{i: i}, []}

    start = System.monotonic_time(:microsecond)

    Enum.chunk_every(jobs, 5000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn, chunk_size: 1000)
    end)

    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000

    cleanup_bullmq(conn, queue_name)
    count / (elapsed_ms / 1000)
  end

  defp benchmark_oban_bulk(count) do
    Repo.delete_all(Oban.Job)

    changesets = for i <- 1..count, do: ObanWorker.new(%{i: i})

    start = System.monotonic_time(:microsecond)

    Enum.chunk_every(changesets, 1000)
    |> Enum.each(fn batch ->
      Oban.insert_all(batch)
    end)

    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000

    Repo.delete_all(Oban.Job)
    count / (elapsed_ms / 1000)
  end

  defp cleanup_bullmq(conn, queue_name) do
    case RedisConnection.command(conn, ["KEYS", "bull:#{queue_name}*"]) do
      {:ok, [_ | _] = keys} -> RedisConnection.command(conn, ["DEL" | keys])
      _ -> :ok
    end
  end

  defp ensure_oban_running do
    case Process.whereis(Oban) do
      nil -> Oban.start_link(repo: Repo, queues: false, plugins: false, log: false)
      _ -> :ok
    end
  end

  defp stop_oban do
    case Process.whereis(Oban) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 5000)
    end
  catch
    :exit, _ -> :ok
  end

  defp format_rate(rate) when rate >= 1000, do: "#{Float.round(rate / 1000, 1)}K"
  defp format_rate(rate), do: "#{Float.round(rate, 1)}"

  defp format_number(n) when n >= 1000, do: "#{div(n, 1000)}K"
  defp format_number(n), do: "#{n}"

  defp print_summary(results, runs) do
    IO.puts("""

    ╔═══════════════════════════════════════════════════════════════════════════════╗
    ║                      BULK INSERT SUMMARY                                      ║
    ║                     (Best of #{runs} runs per test)                                  ║
    ╚═══════════════════════════════════════════════════════════════════════════════╝

    """)

    IO.puts("┌────────────────┬───────────────────┬───────────────────┬────────────────┐")
    IO.puts("│ Job Count      │ BullMQ (Redis)    │ Oban (PostgreSQL) │ Difference     │")
    IO.puts("├────────────────┼───────────────────┼───────────────────┼────────────────┤")

    for {size, bullmq_rate, oban_rate} <- results do
      diff_pct = ((bullmq_rate - oban_rate) / oban_rate) * 100
      diff_str = if diff_pct >= 0, do: "+#{Float.round(diff_pct, 1)}%", else: "#{Float.round(diff_pct, 1)}%"

      IO.puts("│ #{String.pad_trailing(format_number(size), 14)} │ #{String.pad_trailing("#{format_rate(bullmq_rate)} jobs/sec", 17)} │ #{String.pad_trailing("#{format_rate(oban_rate)} jobs/sec", 17)} │ #{String.pad_trailing(diff_str, 14)} │")
    end

    IO.puts("└────────────────┴───────────────────┴───────────────────┴────────────────┘")

    IO.puts("\nCSV Output:")
    IO.puts("job_count,bullmq_rate,oban_rate,difference_pct")
    for {size, bullmq_rate, oban_rate} <- results do
      diff_pct = ((bullmq_rate - oban_rate) / oban_rate) * 100
      IO.puts("#{size},#{Float.round(bullmq_rate, 1)},#{Float.round(oban_rate, 1)},#{Float.round(diff_pct, 1)}")
    end
  end
end

# Parse command line arguments
{opts, _, _} = OptionParser.parse(System.argv(),
  strict: [sizes: :string, runs: :integer]
)

opts = case Keyword.get(opts, :sizes) do
  nil -> opts
  sizes_str ->
    sizes = sizes_str |> String.split(",") |> Enum.map(&String.to_integer/1)
    Keyword.put(opts, :sizes, sizes)
end

BulkBenchmark.run(opts)
