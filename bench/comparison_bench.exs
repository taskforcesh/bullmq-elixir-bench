#!/usr/bin/env elixir

# BullMQ Elixir vs Oban - Comprehensive Benchmark
#
# This script benchmarks both BullMQ (Redis) and Oban (PostgreSQL) for comparison.
# Some features:
# - Proper timing (starts before processing begins)
# - Full statistics (mean, median, std-dev, min, max, p95, p99)
# - Sustained workload testing for measuring stability over time
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
#   mix bench.compare --sustained-duration 60  # Run with 60s sustained test
#
# Options:
#   --jobs N              Number of jobs for insertion tests (default: 50000)
#   --process-jobs N      Number of jobs for processing tests (default: 50000)
#   --concurrency N       Worker concurrency level (default: 100)
#   --job-duration N      Simulated job duration in ms (default: 10)
#   --runs N              Number of benchmark runs (default: 5)
#   --sustained-duration N  Duration in seconds for sustained workload test (default: 0 = disabled)
#
# Note on theoretical limits:
#   With 10ms work per job and N workers, max throughput = N × 100 jobs/sec
#   Example: 100 workers × 100 jobs/sec = 10,000 jobs/sec theoretical max

defmodule BenchStats do
  @moduledoc """
  Statistical functions for benchmark analysis.
  Provides mean, std-dev, median, percentiles, min, max.
  """

  def calculate(rates) when is_list(rates) and length(rates) > 0 do
    sorted = Enum.sort(rates)
    n = length(sorted)
    mean = Enum.sum(rates) / n

    variance = if n > 1 do
      Enum.map(rates, fn x -> :math.pow(x - mean, 2) end)
      |> Enum.sum()
      |> Kernel./(n - 1)
    else
      0.0
    end

    std_dev = :math.sqrt(variance)

    %{
      mean: mean,
      median: percentile(sorted, 50),
      std_dev: std_dev,
      min: List.first(sorted),
      max: List.last(sorted),
      p50: percentile(sorted, 50),
      p95: percentile(sorted, 95),
      p99: percentile(sorted, 99),
      count: n,
      all_rates: rates
    }
  end

  defp percentile(sorted, p) when p >= 0 and p <= 100 do
    n = length(sorted)
    if n == 1 do
      hd(sorted)
    else
      # Using linear interpolation
      rank = (p / 100) * (n - 1)
      lower_idx = trunc(rank)
      upper_idx = min(lower_idx + 1, n - 1)
      fraction = rank - lower_idx

      lower = Enum.at(sorted, lower_idx)
      upper = Enum.at(sorted, upper_idx)
      lower + fraction * (upper - lower)
    end
  end

  def format_stats(stats) do
    """
    Mean: #{format_rate(stats.mean)} | Median: #{format_rate(stats.median)} | StdDev: #{format_rate(stats.std_dev)}
    Min: #{format_rate(stats.min)} | Max: #{format_rate(stats.max)} | P95: #{format_rate(stats.p95)} | P99: #{format_rate(stats.p99)}
    """
  end

  defp format_rate(rate) when is_number(rate) do
    cond do
      rate >= 1000 -> "#{Float.round(rate / 1000, 2)}K"
      true -> "#{Float.round(rate * 1.0, 1)}"
    end
  end
end

defmodule ComparisonBenchmark do
  @moduledoc """
  Benchmark comparing BullMQ Elixir (Redis) vs Oban (PostgreSQL).
  Tests job insertion, bulk insertion, and job processing throughput.
  """

  alias BullmqObanBench.Repo

  # Module functions for telemetry handlers (avoids performance penalty from anonymous functions)
  @doc false
  def oban_completion_handler(_event, _measurements, _metadata, counter) do
    :counters.add(counter, 1, 1)
  end
  alias BullmqObanBench.ObanWorker
  alias BullMQ.{Queue, Worker, RedisConnection}

  @default_jobs 50_000
  @default_process_jobs 50_000
  @default_concurrency 100
  @default_job_duration 10  # milliseconds
  @default_runs 5  # More runs for better statistical significance
  @default_sustained_duration 0  # seconds (0 = skip sustained test)

  def run(opts \\ []) do
    job_count = Keyword.get(opts, :jobs, @default_jobs)
    process_job_count = Keyword.get(opts, :process_jobs, @default_process_jobs)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    job_duration = Keyword.get(opts, :job_duration, @default_job_duration)
    runs = Keyword.get(opts, :runs, @default_runs)
    sustained_duration = Keyword.get(opts, :sustained_duration, @default_sustained_duration)

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
      Runs per test: #{runs} (full statistics collected)
      Sustained test: #{if sustained_duration > 0, do: "#{sustained_duration}s", else: "disabled (use --sustained-duration N)"}
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

    bullmq_single_stats = BenchStats.calculate(Enum.map(bullmq_single_results, & &1.rate))
    oban_single_stats = BenchStats.calculate(Enum.map(oban_single_results, & &1.rate))

    IO.puts("\n  Statistics (jobs/sec):")
    IO.puts("    BullMQ: #{BenchStats.format_stats(bullmq_single_stats)}")
    IO.puts("    Oban:   #{BenchStats.format_stats(oban_single_stats)}")

    all_results = [{:single_insert, bullmq_single_stats, oban_single_stats} | all_results]

    # === Test 1b: Concurrent Single Job Insertion ===
    insert_concurrency = 10
    IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 1b: Concurrent Single Job Insertion (#{job_count} jobs, concurrency=#{insert_concurrency})")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    bullmq_concurrent_results = run_multiple(runs, fn ->
      IO.write("    BullMQ run... ")
      result = benchmark_bullmq_concurrent_insert(redis_opts, job_count, insert_concurrency)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      result
    end)

    oban_concurrent_results = run_multiple(runs, fn ->
      IO.write("    Oban run... ")
      result = benchmark_oban_concurrent_insert(job_count, insert_concurrency)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      result
    end)

    bullmq_concurrent_stats = BenchStats.calculate(Enum.map(bullmq_concurrent_results, & &1.rate))
    oban_concurrent_stats = BenchStats.calculate(Enum.map(oban_concurrent_results, & &1.rate))

    IO.puts("\n  Statistics (jobs/sec):")
    IO.puts("    BullMQ: #{BenchStats.format_stats(bullmq_concurrent_stats)}")
    IO.puts("    Oban:   #{BenchStats.format_stats(oban_concurrent_stats)}")

    all_results = [{:concurrent_insert, bullmq_concurrent_stats, oban_concurrent_stats} | all_results]

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

    bullmq_bulk_stats = BenchStats.calculate(Enum.map(bullmq_bulk_results, & &1.rate))
    oban_bulk_stats = BenchStats.calculate(Enum.map(oban_bulk_results, & &1.rate))

    IO.puts("\n  Statistics (jobs/sec):")
    IO.puts("    BullMQ: #{BenchStats.format_stats(bullmq_bulk_stats)}")
    IO.puts("    Oban:   #{BenchStats.format_stats(oban_bulk_stats)}")

    all_results = [{:bulk_insert, bullmq_bulk_stats, oban_bulk_stats} | all_results]

    # === Test 2b: Concurrent Bulk Job Insertion ===
    IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 2b: Concurrent Bulk Job Insertion (#{job_count} jobs, batches of 1000, concurrency=#{insert_concurrency})")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    bullmq_concurrent_bulk_results = run_multiple(runs, fn ->
      IO.write("    BullMQ run... ")
      result = benchmark_bullmq_concurrent_bulk_insert(redis_opts, job_count, insert_concurrency)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      result
    end)

    oban_concurrent_bulk_results = run_multiple(runs, fn ->
      IO.write("    Oban run... ")
      result = benchmark_oban_concurrent_bulk_insert(job_count, insert_concurrency)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      result
    end)

    bullmq_concurrent_bulk_stats = BenchStats.calculate(Enum.map(bullmq_concurrent_bulk_results, & &1.rate))
    oban_concurrent_bulk_stats = BenchStats.calculate(Enum.map(oban_concurrent_bulk_results, & &1.rate))

    IO.puts("\n  Best results:")
    IO.puts("\n  Statistics (jobs/sec):")
    IO.puts("    BullMQ: #{BenchStats.format_stats(bullmq_concurrent_bulk_stats)}")
    IO.puts("    Oban:   #{BenchStats.format_stats(oban_concurrent_bulk_stats)}")

    all_results = [{:concurrent_bulk_insert, bullmq_concurrent_bulk_stats, oban_concurrent_bulk_stats} | all_results]

    # Define worker concurrency levels to test
    worker_concurrencies = [10, concurrency]  # 10 and 100 workers

    # === Tests 3a/3b: Job Processing with 10ms simulated work ===
    all_results = Enum.reduce(worker_concurrencies, all_results, fn worker_concurrency, acc ->
      IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
      IO.puts("  Test 3: Processing #{job_duration}ms work (#{process_job_count} jobs, workers=#{worker_concurrency})")
      IO.puts("  Theoretical max with #{worker_concurrency} workers @ #{job_duration}ms: #{div(worker_concurrency * 1000, job_duration)} jobs/sec")
      IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

      bullmq_proc_results = run_multiple(runs, fn ->
        IO.write("    BullMQ run... ")
        result = benchmark_bullmq_processing(redis_conn, redis_opts, process_job_count, worker_concurrency, job_duration)
        IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
        result
      end)

      oban_proc_results = run_multiple(runs, fn ->
        IO.write("    Oban run... ")
        result = benchmark_oban_processing(process_job_count, worker_concurrency, job_duration)
        IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
        result
      end)

      bullmq_proc_stats = BenchStats.calculate(Enum.map(bullmq_proc_results, & &1.rate))
      oban_proc_stats = BenchStats.calculate(Enum.map(oban_proc_results, & &1.rate))

      IO.puts("\n  Statistics (jobs/sec):")
      IO.puts("    BullMQ: #{BenchStats.format_stats(bullmq_proc_stats)}")
      IO.puts("    Oban:   #{BenchStats.format_stats(oban_proc_stats)}")

      test_key = if worker_concurrency == 10, do: :processing_10w, else: :processing_100w
      [{test_key, bullmq_proc_stats, oban_proc_stats} | acc]
    end)

    # === Tests 4a/4b: CPU-bound work ===
    all_results = Enum.reduce(worker_concurrencies, all_results, fn worker_concurrency, acc ->
      IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
      IO.puts("  Test 4: CPU-bound work (#{process_job_count} jobs, workers=#{worker_concurrency})")
      IO.puts("  Each job does 1000 sin/cos calculations")
      IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

      bullmq_cpu_results = run_multiple(runs, fn ->
        IO.write("    BullMQ run... ")
        result = benchmark_bullmq_cpu_processing(redis_conn, redis_opts, process_job_count, worker_concurrency)
        IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
        result
      end)

      oban_cpu_results = run_multiple(runs, fn ->
        IO.write("    Oban run... ")
        result = benchmark_oban_cpu_processing(process_job_count, worker_concurrency)
        IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
        result
      end)

      bullmq_cpu_stats = BenchStats.calculate(Enum.map(bullmq_cpu_results, & &1.rate))
      oban_cpu_stats = BenchStats.calculate(Enum.map(oban_cpu_results, & &1.rate))

      IO.puts("\n  Statistics (jobs/sec):")
      IO.puts("    BullMQ: #{BenchStats.format_stats(bullmq_cpu_stats)}")
      IO.puts("    Oban:   #{BenchStats.format_stats(oban_cpu_stats)}")

      test_key = if worker_concurrency == 10, do: :cpu_work_10w, else: :cpu_work_100w
      [{test_key, bullmq_cpu_stats, oban_cpu_stats} | acc]
    end)

    # === Tests 5a/5b: True minimal work (pure queue overhead) ===
    all_results = Enum.reduce(worker_concurrencies, all_results, fn worker_concurrency, acc ->
      IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
      IO.puts("  Test 5: Pure queue overhead (#{process_job_count} jobs, workers=#{worker_concurrency})")
      IO.puts("  Jobs just increment counter and return (no actual work)")
      IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

      bullmq_minimal_results = run_multiple(runs, fn ->
        IO.write("    BullMQ run... ")
        result = benchmark_bullmq_minimal_processing(redis_conn, redis_opts, process_job_count, worker_concurrency)
        IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
        result
      end)

      oban_minimal_results = run_multiple(runs, fn ->
        IO.write("    Oban run... ")
        result = benchmark_oban_minimal_processing(process_job_count, worker_concurrency)
        IO.puts("#{format_rate(result.rate)} jobs/sec (#{round(result.time_ms)}ms)")
        result
      end)

      bullmq_minimal_stats = BenchStats.calculate(Enum.map(bullmq_minimal_results, & &1.rate))
      oban_minimal_stats = BenchStats.calculate(Enum.map(oban_minimal_results, & &1.rate))

      IO.puts("\n  Statistics (jobs/sec):")
      IO.puts("    BullMQ: #{BenchStats.format_stats(bullmq_minimal_stats)}")
      IO.puts("    Oban:   #{BenchStats.format_stats(oban_minimal_stats)}")

      test_key = if worker_concurrency == 10, do: :minimal_10w, else: :minimal_100w
      [{test_key, bullmq_minimal_stats, oban_minimal_stats} | acc]
    end)

    # === Test 5: Sustained Workload (optional) ===
    all_results = if sustained_duration > 0 do
      IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
      IO.puts("  Test 5: Sustained Workload (#{sustained_duration}s, #{job_duration}ms work, #{concurrency} workers)")
      IO.puts("  This test measures throughput stability over time")
      IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

      IO.puts("  Running BullMQ sustained test...")
      bullmq_sustained = benchmark_bullmq_sustained(redis_conn, redis_opts, sustained_duration, concurrency, job_duration)
      IO.puts("  BullMQ completed: #{length(bullmq_sustained.samples)} samples collected")

      IO.puts("\n  Running Oban sustained test...")
      oban_sustained = benchmark_oban_sustained(sustained_duration, concurrency, job_duration)
      IO.puts("  Oban completed: #{length(oban_sustained.samples)} samples collected")

      bullmq_sustained_stats = BenchStats.calculate(bullmq_sustained.samples)
      oban_sustained_stats = BenchStats.calculate(oban_sustained.samples)

      IO.puts("\n  Sustained Statistics (jobs/sec sampled every second):")
      IO.puts("    BullMQ: #{BenchStats.format_stats(bullmq_sustained_stats)}")
      IO.puts("    Oban:   #{BenchStats.format_stats(oban_sustained_stats)}")

      # Add sustained stats with overall throughput
      bullmq_overall = Map.put(bullmq_sustained_stats, :overall_rate, bullmq_sustained.overall_rate)
      oban_overall = Map.put(oban_sustained_stats, :overall_rate, oban_sustained.overall_rate)

      [{:sustained, bullmq_overall, oban_overall} | all_results]
    else
      all_results
    end

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

  defp benchmark_bullmq_concurrent_insert(redis_opts, job_count, concurrency) do
    queue_name = "bullmq_concurrent_#{:erlang.unique_integer([:positive])}"

    # Create a pool of connections for concurrent inserts
    connections = for i <- 1..concurrency do
      conn_name = :"bullmq_insert_conn_#{:erlang.unique_integer([:positive])}_#{i}"
      {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: conn_name))
      conn_name
    end

    # Cleanup queue using first connection
    cleanup_bullmq_queue(hd(connections), queue_name)

    # Distribute jobs across workers
    jobs_per_worker = div(job_count, concurrency)

    start_time = System.monotonic_time(:microsecond)

    # Run concurrent inserts
    tasks = connections
    |> Enum.with_index()
    |> Enum.map(fn {conn, idx} ->
      Task.async(fn ->
        start_idx = idx * jobs_per_worker + 1
        end_idx = start_idx + jobs_per_worker - 1
        for i <- start_idx..end_idx do
          {:ok, _} = Queue.add(queue_name, "bench_job", %{index: i}, connection: conn)
        end
      end)
    end)

    Task.await_many(tasks, 120_000)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    # Cleanup
    cleanup_bullmq_queue(hd(connections), queue_name)

    # Stop connections
    for conn <- connections do
      if pid = Process.whereis(conn), do: GenServer.stop(pid)
    end

    %{jobs: job_count, time_ms: time_ms, rate: job_count / (time_ms / 1000)}
  end

  defp benchmark_bullmq_bulk_insert(conn, job_count) do
    queue_name = "bullmq_bulk_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq_queue(conn, queue_name)

    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}

    start_time = System.monotonic_time(:microsecond)

    # Use larger chunks (5000) for better pipelining
    Enum.chunk_every(jobs, 5000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    cleanup_bullmq_queue(conn, queue_name)

    %{jobs: job_count, time_ms: time_ms, rate: job_count / (time_ms / 1000)}
  end

  defp benchmark_bullmq_concurrent_bulk_insert(redis_opts, job_count, concurrency) do
    queue_name = "bullmq_concurrent_bulk_#{:erlang.unique_integer([:positive])}"
    batch_size = 1000

    # Create a pool of connections for concurrent inserts
    connections = for i <- 1..concurrency do
      conn_name = :"bullmq_bulk_conn_#{:erlang.unique_integer([:positive])}_#{i}"
      {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: conn_name))
      conn_name
    end

    # Cleanup queue using first connection
    cleanup_bullmq_queue(hd(connections), queue_name)

    # Distribute jobs across workers
    jobs_per_worker = div(job_count, concurrency)

    start_time = System.monotonic_time(:microsecond)

    # Run concurrent bulk inserts
    tasks = connections
    |> Enum.with_index()
    |> Enum.map(fn {conn, idx} ->
      Task.async(fn ->
        start_idx = idx * jobs_per_worker + 1
        end_idx = start_idx + jobs_per_worker - 1
        jobs = for i <- start_idx..end_idx, do: {"bench_job", %{index: i}, []}

        # Insert in batches
        Enum.chunk_every(jobs, batch_size)
        |> Enum.each(fn batch ->
          {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
        end)
      end)
    end)

    Task.await_many(tasks, 120_000)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    # Cleanup
    cleanup_bullmq_queue(hd(connections), queue_name)

    # Stop connections
    for conn <- connections do
      if pid = Process.whereis(conn), do: GenServer.stop(pid)
    end

    %{jobs: job_count, time_ms: time_ms, rate: job_count / (time_ms / 1000)}
  end

  defp benchmark_bullmq_processing(conn, redis_opts, job_count, concurrency, job_duration) do
    queue_name = "bullmq_proc_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq_queue(conn, queue_name)

    processed = :counters.new(1, [:atomics])

    # Add jobs FIRST (before timing and worker start)
    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}
    Enum.chunk_every(jobs, 1000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    # Create worker connection with pool_size matching concurrency
    worker_conn = :"bullmq_worker_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn, pool_size: concurrency))

    # Start timing BEFORE worker starts to measure actual processing time
    start_time = System.monotonic_time(:microsecond)

    # Start worker (timing is now running)
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

    # Add jobs FIRST (before timing and worker start)
    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}
    Enum.chunk_every(jobs, 1000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    # Create worker connection with pool_size matching concurrency
    worker_conn = :"bullmq_cpu_worker_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn, pool_size: concurrency))

    # Start timing BEFORE worker starts to measure actual processing time
    start_time = System.monotonic_time(:microsecond)

    # Start worker (timing is now running)
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

  defp benchmark_bullmq_minimal_processing(conn, redis_opts, job_count, concurrency) do
    queue_name = "bullmq_minimal_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq_queue(conn, queue_name)

    processed = :counters.new(1, [:atomics])

    # Add jobs FIRST (before timing and worker start)
    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}
    Enum.chunk_every(jobs, 1000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    # Create worker connection with pool_size matching concurrency
    worker_conn = :"bullmq_minimal_worker_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn, pool_size: concurrency))

    # Start timing BEFORE worker starts to measure actual processing time
    start_time = System.monotonic_time(:microsecond)

    # Start worker (timing is now running)
    {:ok, worker} = Worker.start_link(
      queue: queue_name,
      connection: worker_conn,
      concurrency: concurrency,
      processor: fn _job ->
        # TRUE minimal work: just increment counter and return
        :counters.add(processed, 1, 1)
        {:ok, nil}
      end
    )

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
  # Sustained Workload Benchmarks
  # ============================================================================

  defp benchmark_bullmq_sustained(conn, redis_opts, duration_seconds, concurrency, job_duration) do
    queue_name = "bullmq_sustained_#{:erlang.unique_integer([:positive])}"
    cleanup_bullmq_queue(conn, queue_name)

    processed = :counters.new(1, [:atomics])
    samples = :ets.new(:bullmq_samples, [:set, :public])

    # Create worker connection with pool_size matching concurrency
    worker_conn = :"bullmq_sustained_worker_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn, pool_size: concurrency))

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

    # Calculate how many jobs we need for the duration
    # With 10ms work and 100 concurrency, we can process ~10k jobs/sec
    # Add a buffer to ensure we don't run out
    theoretical_rate = concurrency * (1000 / job_duration)
    jobs_needed = round(theoretical_rate * duration_seconds * 1.5)

    # Add jobs in the background
    job_feeder = Task.async(fn ->
      jobs = for i <- 1..jobs_needed, do: {"bench_job", %{index: i}, []}
      Enum.chunk_every(jobs, 1000)
      |> Enum.each(fn batch ->
        {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
      end)
    end)

    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + (duration_seconds * 1000)

    # Sample throughput every second
    sample_throughput(processed, samples, start_time, end_time, 1000)

    # Wait for job feeder to finish
    Task.await(job_feeder, 60_000)

    total_processed = :counters.get(processed, 1)
    actual_duration_ms = System.monotonic_time(:millisecond) - start_time

    # Collect samples
    sample_list = :ets.tab2list(samples)
    |> Enum.sort_by(fn {time, _rate} -> time end)
    |> Enum.map(fn {_time, rate} -> rate end)

    :ets.delete(samples)

    # Cleanup
    Worker.close(worker)
    Process.sleep(100)
    try do
      GenServer.stop(worker_conn)
    catch
      :exit, _ -> :ok
    end
    cleanup_bullmq_queue(conn, queue_name)

    %{
      samples: sample_list,
      overall_rate: total_processed / (actual_duration_ms / 1000),
      total_jobs: total_processed,
      duration_ms: actual_duration_ms
    }
  end

  defp benchmark_oban_sustained(duration_seconds, concurrency, job_duration) do
    cleanup_oban_jobs()
    ensure_oban_running()

    processed = :counters.new(1, [:atomics])
    samples = :ets.new(:oban_samples, [:set, :public])

    # Attach telemetry handler to track completions
    handler_id = "sustained_completion_handler_#{:erlang.unique_integer([:positive])}"
    :telemetry.attach(
      handler_id,
      [:oban, :job, :stop],
      &ComparisonBenchmark.oban_completion_handler/4,
      processed
    )

    # Calculate how many jobs we need for the duration
    theoretical_rate = concurrency * (1000 / job_duration)
    jobs_needed = round(theoretical_rate * duration_seconds * 1.5)

    # Add jobs
    changesets = for i <- 1..jobs_needed do
      ObanWorker.new(%{index: i, duration_ms: job_duration, type: "sleep"})
    end

    Enum.chunk_every(changesets, 1000)
    |> Enum.each(fn batch ->
      Oban.insert_all(batch)
    end)

    # Start the benchmark queue
    Oban.start_queue(queue: :benchmark, limit: concurrency)

    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + (duration_seconds * 1000)

    # Sample throughput every second
    sample_throughput(processed, samples, start_time, end_time, 1000)

    total_processed = :counters.get(processed, 1)
    actual_duration_ms = System.monotonic_time(:millisecond) - start_time

    # Collect samples
    sample_list = :ets.tab2list(samples)
    |> Enum.sort_by(fn {time, _rate} -> time end)
    |> Enum.map(fn {_time, rate} -> rate end)

    :ets.delete(samples)

    # Cleanup
    :telemetry.detach(handler_id)
    Oban.stop_queue(queue: :benchmark)
    cleanup_oban_jobs()

    %{
      samples: sample_list,
      overall_rate: total_processed / (actual_duration_ms / 1000),
      total_jobs: total_processed,
      duration_ms: actual_duration_ms
    }
  end

  defp sample_throughput(counter, samples, start_time, end_time, interval_ms) do
    last_count = :counters.get(counter, 1)
    do_sample(counter, samples, start_time, end_time, interval_ms, last_count, 0)
  end

  defp do_sample(counter, samples, start_time, end_time, interval_ms, last_count, sample_num) do
    now = System.monotonic_time(:millisecond)

    if now >= end_time do
      :ok
    else
      Process.sleep(interval_ms)
      current_count = :counters.get(counter, 1)
      rate = (current_count - last_count) * (1000 / interval_ms)
      :ets.insert(samples, {sample_num, rate})

      # Print progress every 10 seconds
      elapsed = div(now - start_time, 1000)
      if rem(sample_num + 1, 10) == 0 do
        IO.puts("    #{elapsed}s: #{format_rate(rate)} jobs/sec (total: #{current_count})")
      end

      do_sample(counter, samples, start_time, end_time, interval_ms, current_count, sample_num + 1)
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

  defp benchmark_oban_concurrent_insert(job_count, concurrency) do
    ensure_oban_running()
    cleanup_oban_jobs()

    # Distribute jobs across workers
    jobs_per_worker = div(job_count, concurrency)

    start_time = System.monotonic_time(:microsecond)

    # Run concurrent inserts - Oban uses the connection pool automatically
    tasks = for idx <- 0..(concurrency - 1) do
      Task.async(fn ->
        start_idx = idx * jobs_per_worker + 1
        end_idx = start_idx + jobs_per_worker - 1
        for i <- start_idx..end_idx do
          %{index: i}
          |> ObanWorker.new()
          |> Oban.insert!()
        end
      end)
    end

    Task.await_many(tasks, 120_000)

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

  defp benchmark_oban_concurrent_bulk_insert(job_count, concurrency) do
    ensure_oban_running()
    cleanup_oban_jobs()

    batch_size = 1000
    jobs_per_worker = div(job_count, concurrency)

    start_time = System.monotonic_time(:microsecond)

    # Run concurrent bulk inserts - Oban uses the connection pool automatically
    tasks = for idx <- 0..(concurrency - 1) do
      Task.async(fn ->
        start_idx = idx * jobs_per_worker + 1
        end_idx = start_idx + jobs_per_worker - 1

        changesets = for i <- start_idx..end_idx do
          ObanWorker.new(%{index: i})
        end

        # Insert in batches
        Enum.chunk_every(changesets, batch_size)
        |> Enum.each(fn batch ->
          Oban.insert_all(batch)
        end)
      end)
    end

    Task.await_many(tasks, 120_000)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    cleanup_oban_jobs()

    %{jobs: job_count, time_ms: time_ms, rate: job_count / (time_ms / 1000)}
  end

  defp benchmark_oban_processing(job_count, concurrency, job_duration) do
    cleanup_oban_jobs()

    # Ensure Oban is running with queues disabled
    ensure_oban_running()

    # Use counter for fair comparison (same as BullMQ)
    processed = :counters.new(1, [:atomics])

    # Attach telemetry handler to track completions
    handler_id = "benchmark_completion_handler_#{:erlang.unique_integer([:positive])}"
    :telemetry.attach(
      handler_id,
      [:oban, :job, :stop],
      &ComparisonBenchmark.oban_completion_handler/4,
      processed
    )

    changesets = for i <- 1..job_count do
      ObanWorker.new(%{index: i, duration_ms: job_duration, type: "sleep"})
    end

    Enum.chunk_every(changesets, 1000)
    |> Enum.each(fn batch ->
      Oban.insert_all(batch)
    end)

    # Start timing BEFORE queue starts to measure actual processing time
    start_time = System.monotonic_time(:microsecond)

    # Start the benchmark queue (timing is now running)
    Oban.start_queue(queue: :benchmark, limit: concurrency)

    theoretical_min = div(job_count * job_duration, concurrency)
    timeout = max(theoretical_min * 3, 120_000)
    wait_for_completion(processed, job_count, timeout)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    completed = :counters.get(processed, 1)

    # Cleanup
    :telemetry.detach(handler_id)

    # Stop the queue
    Oban.stop_queue(queue: :benchmark)
    cleanup_oban_jobs()

    %{jobs: completed, time_ms: time_ms, rate: completed / (time_ms / 1000)}
  end

  defp benchmark_oban_cpu_processing(job_count, concurrency) do
    cleanup_oban_jobs()

    ensure_oban_running()

    # Use counter for fair comparison (same as BullMQ)
    processed = :counters.new(1, [:atomics])

    # Attach telemetry handler to track completions
    handler_id = "benchmark_cpu_completion_handler_#{:erlang.unique_integer([:positive])}"
    :telemetry.attach(
      handler_id,
      [:oban, :job, :stop],
      &ComparisonBenchmark.oban_completion_handler/4,
      processed
    )

    changesets = for i <- 1..job_count do
      ObanWorker.new(%{index: i, type: "cpu"})
    end

    Enum.chunk_every(changesets, 1000)
    |> Enum.each(fn batch ->
      Oban.insert_all(batch)
    end)

    # Start timing BEFORE queue starts to measure actual processing time
    start_time = System.monotonic_time(:microsecond)

    # Start the benchmark queue (timing is now running)
    Oban.start_queue(queue: :benchmark, limit: concurrency)

    timeout = 300_000
    wait_for_completion(processed, job_count, timeout)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    completed = :counters.get(processed, 1)

    # Cleanup
    :telemetry.detach(handler_id)

    # Stop the queue
    Oban.stop_queue(queue: :benchmark)
    cleanup_oban_jobs()

    %{jobs: completed, time_ms: time_ms, rate: completed / (time_ms / 1000)}
  end

  defp benchmark_oban_minimal_processing(job_count, concurrency) do
    cleanup_oban_jobs()

    ensure_oban_running()

    # Use counter for fair comparison (same as BullMQ)
    processed = :counters.new(1, [:atomics])

    # Attach telemetry handler to track completions
    handler_id = "benchmark_minimal_completion_handler_#{:erlang.unique_integer([:positive])}"
    :telemetry.attach(
      handler_id,
      [:oban, :job, :stop],
      &ComparisonBenchmark.oban_completion_handler/4,
      processed
    )

    # Create jobs with no type - will hit the minimal perform clause
    changesets = for i <- 1..job_count do
      ObanWorker.new(%{index: i})
    end

    Enum.chunk_every(changesets, 1000)
    |> Enum.each(fn batch ->
      Oban.insert_all(batch)
    end)

    # Start timing BEFORE queue starts to measure actual processing time
    start_time = System.monotonic_time(:microsecond)

    # Start the benchmark queue (timing is now running)
    Oban.start_queue(queue: :benchmark, limit: concurrency)

    timeout = 300_000
    wait_for_completion(processed, job_count, timeout)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000

    completed = :counters.get(processed, 1)

    # Cleanup
    :telemetry.detach(handler_id)

    # Stop the queue
    Oban.stop_queue(queue: :benchmark)
    cleanup_oban_jobs()

    %{jobs: completed, time_ms: time_ms, rate: completed / (time_ms / 1000)}
  end

  defp cleanup_oban_jobs do
    Repo.delete_all(Oban.Job)
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
      true -> "#{Float.round(rate, 1)}"
    end
  end

  defp print_summary(results, insert_jobs, process_jobs, concurrency, job_duration, runs) do
    IO.puts("""

    ╔═══════════════════════════════════════════════════════════════════════════════╗
    ║                         BENCHMARK SUMMARY                                     ║
    ║                  (Statistics from #{runs} runs per test)                             ║
    ╚═══════════════════════════════════════════════════════════════════════════════╝

    """)

    # Main comparison table using MEAN values
    IO.puts("═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  MEAN THROUGHPUT COMPARISON (jobs/sec)")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("┌─────────────────────────────────┬───────────────────┬───────────────────┬────────────────┐")
    IO.puts("│ Test                            │ BullMQ (Redis)    │ Oban (PostgreSQL) │ Difference     │")
    IO.puts("├─────────────────────────────────┼───────────────────┼───────────────────┼────────────────┤")

    for {test_name, bullmq_stats, oban_stats} <- results do
      diff_pct = ((bullmq_stats.mean - oban_stats.mean) / oban_stats.mean) * 100

      test_label = case test_name do
        :single_insert -> "Single Job Insert (#{insert_jobs})"
        :concurrent_insert -> "Concurrent Insert (#{insert_jobs}, c=10)"
        :bulk_insert -> "Bulk Insert (#{insert_jobs})"
        :concurrent_bulk_insert -> "Concurrent Bulk (#{insert_jobs}, c=10)"
        :processing_10w -> "10ms work (#{process_jobs}, w=10)"
        :processing_100w -> "10ms work (#{process_jobs}, w=100)"
        :cpu_work_10w -> "CPU work (#{process_jobs}, w=10)"
        :cpu_work_100w -> "CPU work (#{process_jobs}, w=100)"
        :minimal_10w -> "Pure overhead (#{process_jobs}, w=10)"
        :minimal_100w -> "Pure overhead (#{process_jobs}, w=100)"
        :sustained -> "Sustained workload (sampled)"
      end

      bullmq_str = "#{format_rate(bullmq_stats.mean)} jobs/sec"
      oban_str = "#{format_rate(oban_stats.mean)} jobs/sec"
      diff_str = if diff_pct >= 0, do: "+#{Float.round(diff_pct, 1)}%", else: "#{Float.round(diff_pct, 1)}%"

      IO.puts("│ #{String.pad_trailing(test_label, 31)} │ #{String.pad_trailing(bullmq_str, 17)} │ #{String.pad_trailing(oban_str, 17)} │ #{String.pad_trailing(diff_str, 14)} │")
    end

    IO.puts("└─────────────────────────────────┴───────────────────┴───────────────────┴────────────────┘")

    # Detailed statistics table
    IO.puts("""

    ═══════════════════════════════════════════════════════════════════════════════
      DETAILED STATISTICS (all values in jobs/sec)
    ═══════════════════════════════════════════════════════════════════════════════
    """)

    for {test_name, bullmq_stats, oban_stats} <- results do
      test_label = case test_name do
        :single_insert -> "Single Job Insert"
        :concurrent_insert -> "Concurrent Insert"
        :bulk_insert -> "Bulk Insert"
        :concurrent_bulk_insert -> "Concurrent Bulk Insert"
        :processing_10w -> "Processing 10ms work (10 workers)"
        :processing_100w -> "Processing 10ms work (100 workers)"
        :cpu_work_10w -> "CPU-bound work (10 workers)"
        :cpu_work_100w -> "CPU-bound work (100 workers)"
        :minimal_10w -> "Pure overhead (10 workers)"
        :minimal_100w -> "Pure overhead (100 workers)"
        :sustained -> "Sustained Workload"
      end

      IO.puts("  #{test_label}")
      IO.puts("  ─────────────────────────────────────────────────────────────────────────────")
      IO.puts("  │ Metric     │ BullMQ                │ Oban                  │")
      IO.puts("  ├────────────┼───────────────────────┼───────────────────────┤")
      IO.puts("  │ Mean       │ #{String.pad_trailing(format_rate(bullmq_stats.mean), 21)} │ #{String.pad_trailing(format_rate(oban_stats.mean), 21)} │")
      IO.puts("  │ Median     │ #{String.pad_trailing(format_rate(bullmq_stats.median), 21)} │ #{String.pad_trailing(format_rate(oban_stats.median), 21)} │")
      IO.puts("  │ Std Dev    │ #{String.pad_trailing(format_rate(bullmq_stats.std_dev), 21)} │ #{String.pad_trailing(format_rate(oban_stats.std_dev), 21)} │")
      IO.puts("  │ Min        │ #{String.pad_trailing(format_rate(bullmq_stats.min), 21)} │ #{String.pad_trailing(format_rate(oban_stats.min), 21)} │")
      IO.puts("  │ Max        │ #{String.pad_trailing(format_rate(bullmq_stats.max), 21)} │ #{String.pad_trailing(format_rate(oban_stats.max), 21)} │")
      IO.puts("  │ P95        │ #{String.pad_trailing(format_rate(bullmq_stats.p95), 21)} │ #{String.pad_trailing(format_rate(oban_stats.p95), 21)} │")
      IO.puts("  │ P99        │ #{String.pad_trailing(format_rate(bullmq_stats.p99), 21)} │ #{String.pad_trailing(format_rate(oban_stats.p99), 21)} │")
      IO.puts("  └────────────┴───────────────────────┴───────────────────────┘\n")
    end

    IO.puts("""

    Notes:
    • Positive difference = BullMQ faster
    • Negative difference = Oban faster
    • BullMQ uses Redis (in-memory data store, optimized for speed)
    • Oban uses PostgreSQL (disk-based, ACID compliant, transactional)
    • For 10ms work tests, theoretical max with N workers: N × 100 jobs/sec

    Test Configuration:
    • Concurrency: #{concurrency}
    • Job duration (processing test): #{job_duration}ms
    • Runs per test: #{runs}

    """)

    # Print CSV for easy data extraction
    IO.puts("═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("CSV Output (for charts - MEAN values):")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("test,bullmq_mean,bullmq_median,bullmq_stddev,bullmq_min,bullmq_max,bullmq_p95,oban_mean,oban_median,oban_stddev,oban_min,oban_max,oban_p95,difference_pct")
    for {test_name, bullmq_stats, oban_stats} <- results do
      diff_pct = ((bullmq_stats.mean - oban_stats.mean) / oban_stats.mean) * 100
      IO.puts("#{test_name},#{Float.round(bullmq_stats.mean, 1)},#{Float.round(bullmq_stats.median, 1)},#{Float.round(bullmq_stats.std_dev, 1)},#{Float.round(bullmq_stats.min, 1)},#{Float.round(bullmq_stats.max, 1)},#{Float.round(bullmq_stats.p95, 1)},#{Float.round(oban_stats.mean, 1)},#{Float.round(oban_stats.median, 1)},#{Float.round(oban_stats.std_dev, 1)},#{Float.round(oban_stats.min, 1)},#{Float.round(oban_stats.max, 1)},#{Float.round(oban_stats.p95, 1)},#{Float.round(diff_pct, 1)}")
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
    runs: :integer,
    sustained_duration: :integer
  ]
)

ComparisonBenchmark.run(opts)
