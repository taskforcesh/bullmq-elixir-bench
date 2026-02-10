# Benchmark to test bulk insert performance at different batch sizes

alias BullMQ.{Queue, RedisConnection}
alias BullmqObanBench.Repo

defmodule BatchSizeBench do
  def run do
    redis_config = Application.get_env(:bullmq_oban_bench, :redis)
    redis_opts = [host: redis_config[:host], port: redis_config[:port]]

    redis_conn = :batch_bench_conn
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: redis_conn))

    # Ensure Oban is running
    ensure_oban_running()

    total_jobs = 50_000
    batch_sizes = [100, 250, 500, 1000, 2000]
    runs_per_test = 3

    IO.puts("\n╔═══════════════════════════════════════════════════════════════════╗")
    IO.puts("║  Bulk Insert Performance by Batch Size (#{total_jobs} jobs total)  ║")
    IO.puts("╚═══════════════════════════════════════════════════════════════════╝\n")

    IO.puts("Batch Size │ BullMQ (jobs/s) │ Oban (jobs/s)  │ Winner")
    IO.puts("───────────┼─────────────────┼────────────────┼────────")

    for batch_size <- batch_sizes do
      # BullMQ test - run 3 times, take best
      bullmq_rates = for _ <- 1..runs_per_test do
        test_bullmq_bulk(redis_conn, total_jobs, batch_size)
      end
      bullmq_rate = Enum.max(bullmq_rates)

      # Oban test - run 3 times, take best
      oban_rates = for _ <- 1..runs_per_test do
        test_oban_bulk(total_jobs, batch_size)
      end
      oban_rate = Enum.max(oban_rates)

      winner = if bullmq_rate > oban_rate, do: "BullMQ", else: "Oban"
      diff = if bullmq_rate > oban_rate do
        "+#{round((bullmq_rate / oban_rate - 1) * 100)}%"
      else
        "-#{round((1 - bullmq_rate / oban_rate) * 100)}%"
      end

      IO.puts("#{String.pad_leading(to_string(batch_size), 10)} │ #{String.pad_leading(format_rate(bullmq_rate), 15)} │ #{String.pad_leading(format_rate(oban_rate), 14)} │ #{winner} (#{diff})")
    end

    IO.puts("")
  end

  defp test_bullmq_bulk(conn, total_jobs, batch_size) do
    queue_name = "bulk_bench_#{:erlang.unique_integer([:positive])}"
    jobs = for i <- 1..total_jobs, do: {"bench_job", %{index: i}, []}

    # Cleanup
    case RedisConnection.command(conn, ["KEYS", "bull:#{queue_name}*"]) do
      {:ok, [_ | _] = keys} -> RedisConnection.command(conn, ["DEL" | keys])
      _ -> :ok
    end

    start_time = System.monotonic_time(:microsecond)

    jobs
    |> Enum.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    # Cleanup
    case RedisConnection.command(conn, ["KEYS", "bull:#{queue_name}*"]) do
      {:ok, [_ | _] = keys} -> RedisConnection.command(conn, ["DEL" | keys])
      _ -> :ok
    end

    total_jobs / (time_ms / 1000)
  end

  defp test_oban_bulk(total_jobs, batch_size) do
    # Cleanup
    BullmqObanBench.Repo.query!("TRUNCATE oban_jobs")

    changesets = for i <- 1..total_jobs do
      BullmqObanBench.ObanWorker.new(%{index: i})
    end

    start_time = System.monotonic_time(:microsecond)

    changesets
    |> Enum.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      Oban.insert_all(batch)
    end)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    # Cleanup
    BullmqObanBench.Repo.query!("TRUNCATE oban_jobs")

    total_jobs / (time_ms / 1000)
  end

  defp format_rate(rate) when rate >= 1000 do
    "#{Float.round(rate / 1000, 1)}K"
  end
  defp format_rate(rate) do
    "#{round(rate)}"
  end

  defp ensure_oban_running do
    case Process.whereis(Oban) do
      nil ->
        case Oban.start_link(repo: Repo, queues: false, plugins: false, log: false) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      _pid ->
        :ok
    end
  end
end

BatchSizeBench.run()
