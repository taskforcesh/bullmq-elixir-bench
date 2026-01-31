#!/usr/bin/env elixir

# BullMQ Elixir vs Oban - Comprehensive Benchmark
#
# This script benchmarks both BullMQ (Redis) and Oban (PostgreSQL) for comparison.
#
# Prerequisites:
#   - Redis running on localhost:6379
#   - PostgreSQL running on localhost:5432
#
# Setup:
#   mix setup
#
# Usage:
#   mix bench.compare
#
# Options:
#   --jobs N          Number of jobs for insertion tests (default: 10000)
#   --process-jobs N  Number of jobs for processing tests (default: 5000)
#   --concurrency N   Worker concurrency level (default: 100)
#   --job-duration N  Simulated job duration in ms (default: 10)
#   --runs N          Number of benchmark runs (default: 3)

defmodule ComparisonBenchmark do
  @moduledoc """
  Benchmark comparing BullMQ Elixir (Redis) vs Oban (PostgreSQL).
  Tests job insertion, bulk insertion, and job processing throughput.
  """

  alias BullmqObanBench.Repo
  alias BullmqObanBench.ObanWorker
  alias BullMQ.{Queue, Worker, RedisConnection}

  @default_jobs 10_000
  @default_process_jobs 5_000
  @default_concurrency 100
  @default_job_duration 10  # milliseconds
  @default_runs 3

  def run(opts \\ []) do
    job_count = Keyword.get(opts, :jobs, @default_jobs)
    process_job_count = Keyword.get(opts, :process_jobs, @default_process_jobs)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    job_duration = Keyword.get(opts, :job_duration, @default_job_duration)
    runs = Keyword.get(opts, :runs, @default_runs)

    redis_config = Application.get_env(:bullmq_oban_bench, :redis)
    redis_opts = [host: redis_config[:host], port: redis_config[:port]]

    IO.puts("""

    ╔═══════════════════════════════════════════════════════════════════════════════╗
    ║           BullMQ Elixir vs Oban - Performance Comparison                      ║
    ╠═══════════════════════════════════════════════════════════════════════════════╣
    ║  BullMQ: Redis-backed job queue (in-memory)                                   ║
    ║  Oban:   PostgreSQL-backed job queue (disk-based, ACID compliant)             ║
    ╚═══════════════════════════════════════════════════════════════════════════════╝

    Configuration:
      Jobs for insertion tests: #{job_count}
      Jobs for processing tests: #{process_job_count}
      Concurrency: #{concurrency}
      Job duration: #{job_duration}ms
      Runs per test: #{runs} (best result used)
      Redis: #{redis_config[:host]}:#{redis_config[:port]}
      PostgreSQL: #{Application.get_env(:bullmq_oban_bench, BullmqObanBench.Repo)[:hostname]}

    """)

    # Setup Redis connection
    redis_conn = :benchmark_redis_conn
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: redis_conn))

    # Ensure Oban is available (not started with queues yet)
    ensure_oban_stopped()

    all_results = []

    # === Test 1: Single Job Insertion ===
    IO.puts("═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 1: Single Job Insertion (#{job_count} jobs)")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    bullmq_single_results = run_multiple(runs, fn ->
      IO.write("    BullMQ run... ")
      result = benchmark_bullmq_single_insert(redis_conn, job_count)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      result
    end)

    oban_single_results = run_multiple(runs, fn ->
      IO.write("    Oban run... ")
      result = benchmark_oban_single_insert(job_count)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      result
    end)

    bullmq_single_best = best_result(bullmq_single_results)
    oban_single_best = best_result(oban_single_results)

    IO.puts("\n  Best results:")
    IO.puts("    BullMQ: #{format_rate(bullmq_single_best.rate)} jobs/sec")
    IO.puts("    Oban:   #{format_rate(oban_single_best.rate)} jobs/sec")

    all_results = [{:single_insert, bullmq_single_best, oban_single_best} | all_results]

    # === Test 2: Bulk Job Insertion ===
    IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 2: Bulk Job Insertion (#{job_count} jobs in batches of 1000)")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    bullmq_bulk_results = run_multiple(runs, fn ->
      IO.write("    BullMQ run... ")
      result = benchmark_bullmq_bulk_insert(redis_conn, job_count)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      result
    end)

    oban_bulk_results = run_multiple(runs, fn ->
      IO.write("    Oban run... ")
      result = benchmark_oban_bulk_insert(job_count)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      result
    end)

    bullmq_bulk_best = best_result(bullmq_bulk_results)
    oban_bulk_best = best_result(oban_bulk_results)

    IO.puts("\n  Best results:")
    IO.puts("    BullMQ: #{format_rate(bullmq_bulk_best.rate)} jobs/sec")
    IO.puts("    Oban:   #{format_rate(oban_bulk_best.rate)} jobs/sec")

    all_results = [{:bulk_insert, bullmq_bulk_best, oban_bulk_best} | all_results]

    # === Test 3: Job Processing ===
    IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 3: Job Processing (#{process_job_count} jobs, #{job_duration}ms work, concurrency=#{concurrency})")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    bullmq_proc_results = run_multiple(runs, fn ->
      IO.write("    BullMQ run... ")
      result = benchmark_bullmq_processing(redis_conn, redis_opts, process_job_count, concurrency, job_duration)
      IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
      result
    end)

    oban_proc_results = run_multiple(runs, fn ->
      IO.write("    Oban run... ")
      result = benchmark_oban_processing(process_job_count, concurrency, job_duration)
      IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
      result
    end)

    bullmq_proc_best = best_result(bullmq_proc_results)
    oban_proc_best = best_result(oban_proc_results)

    IO.puts("\n  Best results:")
    IO.puts("    BullMQ: #{format_rate(bullmq_proc_best.rate)} jobs/sec")
    IO.puts("    Oban:   #{format_rate(oban_proc_best.rate)} jobs/sec")

    all_results = [{:processing, bullmq_proc_best, oban_proc_best} | all_results]

    # === Test 4: CPU-Intensive Job Processing ===
    IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 4: CPU-Intensive Processing (#{process_job_count} jobs, concurrency=#{concurrency})")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    bullmq_cpu_results = run_multiple(runs, fn ->
      IO.write("    BullMQ run... ")
      result = benchmark_bullmq_cpu_processing(redis_conn, redis_opts, process_job_count, concurrency)
      IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
      result
    end)

    oban_cpu_results = run_multiple(runs, fn ->
      IO.write("    Oban run... ")
      result = benchmark_oban_cpu_processing(process_job_count, concurrency)
      IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
      result
    end)

    bullmq_cpu_best = best_result(bullmq_cpu_results)
    oban_cpu_best = best_result(oban_cpu_results)

    IO.puts("\n  Best results:")
    IO.puts("    BullMQ: #{format_rate(bullmq_cpu_best.rate)} jobs/sec")
    IO.puts("    Oban:   #{format_rate(oban_cpu_best.rate)} jobs/sec")

    all_results = [{:cpu_processing, bullmq_cpu_best, oban_cpu_best} | all_results]

    # Print summary
    all_results = Enum.reverse(all_results)
    print_summary(all_results, job_count, process_job_count, concurrency, job_duration, runs)

    # Cleanup
    ensure_oban_stopped()
    try do
      GenServer.stop(redis_conn)
    catch
      :exit, _ -> :ok
    end

    all_results
  end

  defp run_multiple(n, fun) do
    Enum.map(1..n, fn _ ->
      result = fun.()
      # Small delay between runs
      Process.sleep(500)
      result
    end)
  end

  defp best_result(results) do
    Enum.max_by(results, & &1.rate)
  end

  # ============================================================================
  # BullMQ Benchmarks
  # ============================================================================

  defp benchmark_bullmq_single_insert(conn, job_count) do
    queue_name = "bullmq_single_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq_queue(conn, queue_name)

    start_time = System.monotonic_time(:microsecond)

    for i <- 1..job_count do
      {:ok, _} = Queue.add(queue_name, "bench_job", %{index: i}, connection: conn)
    end

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    cleanup_bullmq_queue(conn, queue_name)

    %{jobs: job_count, time_ms: time_ms, rate: job_count / (time_ms / 1000)}
  end

  defp benchmark_bullmq_bulk_insert(conn, job_count) do
    queue_name = "bullmq_bulk_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq_queue(conn, queue_name)

    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}

    start_time = System.monotonic_time(:microsecond)

    # Use larger chunks (5000) with larger internal chunk_size (1000) for better pipelining
    Enum.chunk_every(jobs, 5000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn, chunk_size: 1000)
    end)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    cleanup_bullmq_queue(conn, queue_name)

    %{jobs: job_count, time_ms: time_ms, rate: job_count / (time_ms / 1000)}
  end

  defp benchmark_bullmq_processing(conn, redis_opts, job_count, concurrency, job_duration) do
    queue_name = "bullmq_proc_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq_queue(conn, queue_name)

    processed = :counters.new(1, [:atomics])

    # Add jobs
    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}
    Enum.chunk_every(jobs, 1000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    # Create worker connection
    worker_conn = :"bullmq_worker_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn))

    # Start worker
    {:ok, worker} = Worker.start_link(
      queue: queue_name,
      connection: worker_conn,
      concurrency: concurrency,
      processor: fn _job ->
        Process.sleep(job_duration)
        :counters.add(processed, 1, 1)
        {:ok, nil}
      end
    )

    start_time = System.monotonic_time(:microsecond)

    theoretical_min = div(job_count * job_duration, concurrency)
    timeout = max(theoretical_min * 3, 120_000)
    wait_for_completion(processed, job_count, timeout)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000
    final_count = :counters.get(processed, 1)

    Worker.close(worker)
    Process.sleep(100)
    try do
      GenServer.stop(worker_conn)
    catch
      :exit, _ -> :ok
    end
    cleanup_bullmq_queue(conn, queue_name)

    %{jobs: final_count, time_ms: time_ms, rate: final_count / (time_ms / 1000)}
  end

  defp benchmark_bullmq_cpu_processing(conn, redis_opts, job_count, concurrency) do
    queue_name = "bullmq_cpu_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq_queue(conn, queue_name)

    processed = :counters.new(1, [:atomics])

    # Add jobs
    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}
    Enum.chunk_every(jobs, 1000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    worker_conn = :"bullmq_cpu_worker_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn))

    {:ok, worker} = Worker.start_link(
      queue: queue_name,
      connection: worker_conn,
      concurrency: concurrency,
      processor: fn _job ->
        # CPU-intensive work: calculate fibonacci
        cpu_work(1000)
        :counters.add(processed, 1, 1)
        {:ok, nil}
      end
    )

    start_time = System.monotonic_time(:microsecond)

    timeout = 300_000  # 5 minutes max
    wait_for_completion(processed, job_count, timeout)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000
    final_count = :counters.get(processed, 1)

    Worker.close(worker)
    Process.sleep(100)
    try do
      GenServer.stop(worker_conn)
    catch
      :exit, _ -> :ok
    end
    cleanup_bullmq_queue(conn, queue_name)

    %{jobs: final_count, time_ms: time_ms, rate: final_count / (time_ms / 1000)}
  end

  defp cleanup_bullmq_queue(conn, queue_name) do
    case RedisConnection.command(conn, ["KEYS", "bull:#{queue_name}*"]) do
      {:ok, [_ | _] = keys} ->
        RedisConnection.command(conn, ["DEL" | keys])
      _ -> :ok
    end
  end

  # ============================================================================
  # Oban Benchmarks
  # ============================================================================

  defp benchmark_oban_single_insert(job_count) do
    ensure_oban_running()
    cleanup_oban_jobs()

    start_time = System.monotonic_time(:microsecond)

    for i <- 1..job_count do
      %{index: i}
      |> ObanWorker.new()
      |> Oban.insert!()
    end

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    cleanup_oban_jobs()

    %{jobs: job_count, time_ms: time_ms, rate: job_count / (time_ms / 1000)}
  end

  defp benchmark_oban_bulk_insert(job_count) do
    ensure_oban_running()
    cleanup_oban_jobs()

    changesets = for i <- 1..job_count do
      ObanWorker.new(%{index: i})
    end

    start_time = System.monotonic_time(:microsecond)

    Enum.chunk_every(changesets, 1000)
    |> Enum.each(fn batch ->
      Oban.insert_all(batch)
    end)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    cleanup_oban_jobs()

    %{jobs: job_count, time_ms: time_ms, rate: job_count / (time_ms / 1000)}
  end

  defp benchmark_oban_processing(job_count, concurrency, job_duration) do
    cleanup_oban_jobs()

    # Ensure Oban is running with queues disabled
    ensure_oban_running()

    changesets = for i <- 1..job_count do
      ObanWorker.new(%{index: i, duration_ms: job_duration, type: "sleep"})
    end

    Enum.chunk_every(changesets, 1000)
    |> Enum.each(fn batch ->
      Oban.insert_all(batch)
    end)

    # Start the benchmark queue with specified concurrency
    Oban.start_queue(queue: :benchmark, limit: concurrency)

    start_time = System.monotonic_time(:microsecond)

    theoretical_min = div(job_count * job_duration, concurrency)
    timeout = max(theoretical_min * 3, 120_000)
    wait_for_oban_completion(job_count, timeout)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    completed = count_oban_completed()

    # Stop the queue
    Oban.stop_queue(queue: :benchmark)
    cleanup_oban_jobs()

    %{jobs: completed, time_ms: time_ms, rate: completed / (time_ms / 1000)}
  end

  defp benchmark_oban_cpu_processing(job_count, concurrency) do
    cleanup_oban_jobs()

    ensure_oban_running()

    changesets = for i <- 1..job_count do
      ObanWorker.new(%{index: i, type: "cpu"})
    end

    Enum.chunk_every(changesets, 1000)
    |> Enum.each(fn batch ->
      Oban.insert_all(batch)
    end)

    # Start the benchmark queue
    Oban.start_queue(queue: :benchmark, limit: concurrency)

    start_time = System.monotonic_time(:microsecond)

    timeout = 300_000
    wait_for_oban_completion(job_count, timeout)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    completed = count_oban_completed()

    # Stop the queue
    Oban.stop_queue(queue: :benchmark)
    cleanup_oban_jobs()

    %{jobs: completed, time_ms: time_ms, rate: completed / (time_ms / 1000)}
  end

  defp cleanup_oban_jobs do
    Repo.delete_all(Oban.Job)
  end

  defp count_oban_completed do
    import Ecto.Query
    Repo.aggregate(from(j in Oban.Job, where: j.state == "completed"), :count)
  end

  defp wait_for_oban_completion(target, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_oban(target, deadline)
  end

  defp do_wait_oban(target, deadline) do
    completed = count_oban_completed()
    now = System.monotonic_time(:millisecond)

    cond do
      completed >= target -> :ok
      now >= deadline -> :timeout
      true ->
        Process.sleep(100)
        do_wait_oban(target, deadline)
    end
  end

  # Ensure Oban is running (start if not already running)
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

  defp stop_oban do
    case Process.whereis(Oban) do
      nil -> :ok
      pid ->
        try do
          Supervisor.stop(pid, :normal, 10_000)
        catch
          :exit, _ -> :ok
        end
        # Wait for it to fully stop
        wait_for_oban_stop(50)  # Max 50 iterations = 5 seconds
    end
  end

  defp wait_for_oban_stop(0), do: :timeout
  defp wait_for_oban_stop(remaining) do
    case Process.whereis(Oban) do
      nil -> :ok
      _pid ->
        Process.sleep(100)
        wait_for_oban_stop(remaining - 1)
    end
  end

  defp ensure_oban_stopped, do: stop_oban()

  # ============================================================================
  # Helpers
  # ============================================================================

  defp wait_for_completion(counter, target, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(counter, target, deadline)
  end

  defp do_wait(counter, target, deadline) do
    current = :counters.get(counter, 1)
    now = System.monotonic_time(:millisecond)

    cond do
      current >= target -> :ok
      now >= deadline -> :timeout
      true ->
        Process.sleep(50)
        do_wait(counter, target, deadline)
    end
  end

  defp cpu_work(iterations) do
    Enum.reduce(1..iterations, 0, fn i, acc ->
      :math.sin(i) + :math.cos(i) + acc
    end)
  end

  defp format_rate(rate) do
    cond do
      rate >= 1000 -> "#{Float.round(rate / 1000, 1)}K"
      true -> Float.round(rate, 1)
    end
  end

  defp print_summary(results, insert_jobs, process_jobs, concurrency, job_duration, runs) do
    IO.puts("""

    ╔═══════════════════════════════════════════════════════════════════════════════╗
    ║                         BENCHMARK SUMMARY                                     ║
    ║                     (Best of #{runs} runs per test)                                  ║
    ╚═══════════════════════════════════════════════════════════════════════════════╝

    """)

    IO.puts("┌─────────────────────────────────┬───────────────────┬───────────────────┬────────────────┐")
    IO.puts("│ Test                            │ BullMQ (Redis)    │ Oban (PostgreSQL) │ Difference     │")
    IO.puts("├─────────────────────────────────┼───────────────────┼───────────────────┼────────────────┤")

    for {test_name, bullmq_result, oban_result} <- results do
      diff_pct = ((bullmq_result.rate - oban_result.rate) / oban_result.rate) * 100

      test_label = case test_name do
        :single_insert -> "Single Job Insert (#{insert_jobs})"
        :bulk_insert -> "Bulk Insert (#{insert_jobs})"
        :processing -> "Processing (#{process_jobs}, #{job_duration}ms)"
        :cpu_processing -> "CPU Processing (#{process_jobs})"
      end

      bullmq_str = "#{format_rate(bullmq_result.rate)} jobs/sec"
      oban_str = "#{format_rate(oban_result.rate)} jobs/sec"
      diff_str = if diff_pct >= 0, do: "+#{Float.round(diff_pct, 1)}%", else: "#{Float.round(diff_pct, 1)}%"

      IO.puts("│ #{String.pad_trailing(test_label, 31)} │ #{String.pad_trailing(bullmq_str, 17)} │ #{String.pad_trailing(oban_str, 17)} │ #{String.pad_trailing(diff_str, 14)} │")
    end

    IO.puts("└─────────────────────────────────┴───────────────────┴───────────────────┴────────────────┘")

    IO.puts("""

    Notes:
    • Positive difference = BullMQ faster
    • Negative difference = Oban faster
    • BullMQ uses Redis (in-memory data store, optimized for speed)
    • Oban uses PostgreSQL (disk-based, ACID compliant, transactional)

    Test Configuration:
    • Concurrency: #{concurrency}
    • Job duration (processing test): #{job_duration}ms
    • Runs per test: #{runs}

    """)

    # Print CSV for easy data extraction
    IO.puts("═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("CSV Output (for charts):")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("test,bullmq_rate,oban_rate,difference_pct")
    for {test_name, bullmq_result, oban_result} <- results do
      diff_pct = ((bullmq_result.rate - oban_result.rate) / oban_result.rate) * 100
      IO.puts("#{test_name},#{Float.round(bullmq_result.rate, 1)},#{Float.round(oban_result.rate, 1)},#{Float.round(diff_pct, 1)}")
    end
  end
end

# Parse command line arguments
{opts, _, _} = OptionParser.parse(System.argv(),
  strict: [
    jobs: :integer,
    process_jobs: :integer,
    concurrency: :integer,
    job_duration: :integer,
    runs: :integer
  ]
)

ComparisonBenchmark.run(opts)
