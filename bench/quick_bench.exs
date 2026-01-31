#!/usr/bin/env elixir

# Quick Benchmark - Fast sanity check
#
# Runs a quick comparison with minimal jobs to verify setup is working.
#
# Usage:
#   mix bench.quick

defmodule QuickBenchmark do
  @moduledoc """
  Quick sanity check benchmark with minimal job counts.
  Good for verifying the setup is working correctly.
  """

  alias BullmqObanBench.Repo
  alias BullmqObanBench.ObanWorker
  alias BullMQ.{Queue, Worker, RedisConnection}

  def run do
    redis_config = Application.get_env(:bullmq_oban_bench, :redis)
    redis_opts = [host: redis_config[:host], port: redis_config[:port]]

    IO.puts("""

    ╔═══════════════════════════════════════════════════════════════════════════════╗
    ║              Quick Benchmark - Sanity Check                                   ║
    ╚═══════════════════════════════════════════════════════════════════════════════╝

    Running quick tests with 1000 jobs each...

    """)

    # Setup Redis connection
    redis_conn = :quick_bench_redis
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: redis_conn))

    # Ensure Oban is running
    ensure_oban_running()

    # Test 1: Single Insert
    IO.puts("Test 1: Single Job Insertion (1000 jobs)")
    IO.puts("─────────────────────────────────────────")

    bullmq_rate = benchmark_bullmq_single(redis_conn, 1000)
    IO.puts("  BullMQ: #{format_rate(bullmq_rate)} jobs/sec")

    oban_rate = benchmark_oban_single(1000)
    IO.puts("  Oban:   #{format_rate(oban_rate)} jobs/sec")
    IO.puts("")

    # Test 2: Bulk Insert
    IO.puts("Test 2: Bulk Job Insertion (1000 jobs)")
    IO.puts("─────────────────────────────────────────")

    bullmq_bulk_rate = benchmark_bullmq_bulk(redis_conn, 1000)
    IO.puts("  BullMQ: #{format_rate(bullmq_bulk_rate)} jobs/sec")

    oban_bulk_rate = benchmark_oban_bulk(1000)
    IO.puts("  Oban:   #{format_rate(oban_bulk_rate)} jobs/sec")
    IO.puts("")

    # Test 3: Processing
    IO.puts("Test 3: Job Processing (500 jobs, 5ms work)")
    IO.puts("─────────────────────────────────────────")

    bullmq_proc_rate = benchmark_bullmq_processing(redis_conn, redis_opts, 500, 50, 5)
    IO.puts("  BullMQ: #{format_rate(bullmq_proc_rate)} jobs/sec")

    oban_proc_rate = benchmark_oban_processing(500, 50, 5)
    IO.puts("  Oban:   #{format_rate(oban_proc_rate)} jobs/sec")

    IO.puts("""

    ═══════════════════════════════════════════════════════════════════════════════
    Quick benchmark complete! For comprehensive results, run:
      mix bench.compare
    ═══════════════════════════════════════════════════════════════════════════════
    """)

    # Cleanup
    stop_oban()
    try do
      GenServer.stop(redis_conn)
    catch
      :exit, _ -> :ok
    end
  end

  defp benchmark_bullmq_single(conn, count) do
    queue_name = "quick_single_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq(conn, queue_name)

    start = System.monotonic_time(:microsecond)
    for i <- 1..count do
      {:ok, _} = Queue.add(queue_name, "job", %{i: i}, connection: conn)
    end
    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000

    cleanup_bullmq(conn, queue_name)
    count / (elapsed_ms / 1000)
  end

  defp benchmark_bullmq_bulk(conn, count) do
    queue_name = "quick_bulk_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq(conn, queue_name)

    jobs = for i <- 1..count, do: {"job", %{i: i}, []}

    start = System.monotonic_time(:microsecond)
    {:ok, _} = Queue.add_bulk(queue_name, jobs, connection: conn)
    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000

    cleanup_bullmq(conn, queue_name)
    count / (elapsed_ms / 1000)
  end

  defp benchmark_bullmq_processing(conn, redis_opts, count, concurrency, duration_ms) do
    queue_name = "quick_proc_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq(conn, queue_name)

    processed = :counters.new(1, [:atomics])
    jobs = for i <- 1..count, do: {"job", %{i: i}, []}
    {:ok, _} = Queue.add_bulk(queue_name, jobs, connection: conn)

    worker_conn = :"quick_worker_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn))

    {:ok, worker} = Worker.start_link(
      queue: queue_name,
      connection: worker_conn,
      concurrency: concurrency,
      processor: fn _job ->
        Process.sleep(duration_ms)
        :counters.add(processed, 1, 1)
        {:ok, nil}
      end
    )

    start = System.monotonic_time(:microsecond)
    wait_for_count(processed, count, 60_000)
    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000

    Worker.close(worker)
    Process.sleep(100)
    try do
      GenServer.stop(worker_conn)
    catch
      :exit, _ -> :ok
    end
    cleanup_bullmq(conn, queue_name)

    count / (elapsed_ms / 1000)
  end

  defp benchmark_oban_single(count) do
    Repo.delete_all(Oban.Job)

    start = System.monotonic_time(:microsecond)
    for i <- 1..count do
      %{i: i} |> ObanWorker.new() |> Oban.insert!()
    end
    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000

    Repo.delete_all(Oban.Job)
    count / (elapsed_ms / 1000)
  end

  defp benchmark_oban_bulk(count) do
    Repo.delete_all(Oban.Job)

    changesets = for i <- 1..count, do: ObanWorker.new(%{i: i})

    start = System.monotonic_time(:microsecond)
    Oban.insert_all(changesets)
    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000

    Repo.delete_all(Oban.Job)
    count / (elapsed_ms / 1000)
  end

  defp benchmark_oban_processing(count, concurrency, duration_ms) do
    Repo.delete_all(Oban.Job)

    changesets = for i <- 1..count do
      ObanWorker.new(%{i: i, type: "sleep", duration_ms: duration_ms})
    end
    Oban.insert_all(changesets)

    Oban.start_queue(queue: :benchmark, limit: concurrency)

    start = System.monotonic_time(:microsecond)
    wait_for_oban(count, 60_000)
    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000

    Oban.stop_queue(queue: :benchmark)
    Repo.delete_all(Oban.Job)

    count / (elapsed_ms / 1000)
  end

  defp cleanup_bullmq(conn, queue_name) do
    case RedisConnection.command(conn, ["KEYS", "bull:#{queue_name}*"]) do
      {:ok, [_ | _] = keys} -> RedisConnection.command(conn, ["DEL" | keys])
      _ -> :ok
    end
  end

  defp wait_for_count(counter, target, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(counter, target, deadline)
  end

  defp do_wait(counter, target, deadline) do
    if :counters.get(counter, 1) >= target do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(20)
        do_wait(counter, target, deadline)
      end
    end
  end

  defp wait_for_oban(target, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_oban(target, deadline)
  end

  defp do_wait_oban(target, deadline) do
    import Ecto.Query
    completed = Repo.aggregate(from(j in Oban.Job, where: j.state == "completed"), :count)

    if completed >= target do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(50)
        do_wait_oban(target, deadline)
      end
    end
  end

  defp ensure_oban_running do
    case Process.whereis(Oban) do
      nil ->
        Oban.start_link(repo: Repo, queues: false, plugins: false, log: false)
      _ ->
        :ok
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
end

QuickBenchmark.run()
