#!/usr/bin/env elixir

# BullMQ Elixir - Concurrency Scaling Benchmark
#
# This script measures how throughput scales with increasing concurrency
# for both CPU-intensive and dummy (minimal work) jobs.
#
# Usage:
#   mix run bench/concurrency_scaling_bench.exs
#
# Options:
#   --jobs N          Number of jobs per test (default: 5000)
#   --max-concurrency Maximum concurrency to test (default: 400)
#   --step N          Concurrency step size (default: 50)

defmodule ConcurrencyScalingBenchmark do
  @moduledoc """
  Benchmark measuring how BullMQ Elixir throughput scales with concurrency.
  Tests both CPU-intensive and dummy (minimal work) jobs.
  """

  alias BullMQ.{Queue, Worker, RedisConnection}

  @default_jobs 5000
  @default_max_concurrency 400
  @default_step 50

  # Module function for telemetry (avoid warnings)
  @doc false
  def noop_handler(_event, _measurements, _metadata, _config), do: :ok

  def run(opts \\ []) do
    job_count = Keyword.get(opts, :jobs, @default_jobs)
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    step = Keyword.get(opts, :step, @default_step)

    redis_config = Application.get_env(:bullmq_oban_bench, :redis)
    redis_opts = [host: redis_config[:host], port: redis_config[:port]]

    IO.puts("""

    ╔═══════════════════════════════════════════════════════════════════════════════╗
    ║         BullMQ Elixir - Concurrency Scaling Benchmark                         ║
    ╚═══════════════════════════════════════════════════════════════════════════════╝

    Configuration:
      Jobs per test: #{job_count}
      Max concurrency: #{max_concurrency}
      Step size: #{step}
      Redis: #{redis_config[:host]}:#{redis_config[:port]}

    """)

    # Setup Redis connection
    redis_conn = :scaling_bench_redis
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: redis_conn))

    concurrency_levels = [1, 10, 25] ++ Enum.to_list(step..max_concurrency//step)
    concurrency_levels = Enum.uniq(concurrency_levels) |> Enum.sort()

    # ============================================================================
    # Test 1: Dummy Jobs (minimal work) - Single Worker
    # ============================================================================
    IO.puts("═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 1: Dummy Jobs (minimal work) - Single Worker")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    dummy_results = for concurrency <- concurrency_levels do
      IO.write("  Concurrency #{String.pad_leading(to_string(concurrency), 3)}... ")
      result = benchmark_dummy_jobs(redis_conn, redis_opts, job_count, concurrency)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      {concurrency, result}
    end

    # ============================================================================
    # Test 2: CPU-Intensive Jobs - Single Worker
    # ============================================================================
    IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 2: CPU-Intensive Jobs - Single Worker")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    cpu_results = for concurrency <- concurrency_levels do
      IO.write("  Concurrency #{String.pad_leading(to_string(concurrency), 3)}... ")
      result = benchmark_cpu_jobs(redis_conn, redis_opts, job_count, concurrency)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      {concurrency, result}
    end

    # ============================================================================
    # Test 3: Multiple Workers with High Concurrency
    # ============================================================================
    IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 3: Multiple Workers (Dummy Jobs)")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    multi_worker_configs = [
      {1, 300},   # 1 worker, 300 concurrency = 300 total
      {2, 150},   # 2 workers, 150 each = 300 total
      {3, 100},   # 3 workers, 100 each = 300 total
      {4, 75},    # 4 workers, 75 each = 300 total
      {6, 50},    # 6 workers, 50 each = 300 total
      {1, 400},   # 1 worker, 400 concurrency
      {2, 200},   # 2 workers, 200 each = 400 total
      {4, 100},   # 4 workers, 100 each = 400 total
    ]

    multi_dummy_results = for {num_workers, concurrency_per_worker} <- multi_worker_configs do
      total = num_workers * concurrency_per_worker
      IO.write("  #{num_workers} worker(s) × #{concurrency_per_worker} concurrency (#{total} total)... ")
      result = benchmark_multi_worker_dummy(redis_conn, redis_opts, job_count, num_workers, concurrency_per_worker)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      {{num_workers, concurrency_per_worker}, result}
    end

    # ============================================================================
    # Test 4: Multiple Workers with CPU Jobs
    # ============================================================================
    IO.puts("\n═══════════════════════════════════════════════════════════════════════════════")
    IO.puts("  Test 4: Multiple Workers (CPU Jobs)")
    IO.puts("═══════════════════════════════════════════════════════════════════════════════\n")

    multi_cpu_results = for {num_workers, concurrency_per_worker} <- multi_worker_configs do
      total = num_workers * concurrency_per_worker
      IO.write("  #{num_workers} worker(s) × #{concurrency_per_worker} concurrency (#{total} total)... ")
      result = benchmark_multi_worker_cpu(redis_conn, redis_opts, job_count, num_workers, concurrency_per_worker)
      IO.puts("#{format_rate(result.rate)} jobs/sec")
      {{num_workers, concurrency_per_worker}, result}
    end

    # Print summary and CSV data for charting
    print_summary(dummy_results, cpu_results, multi_dummy_results, multi_cpu_results, job_count)

    # Cleanup
    try do
      GenServer.stop(redis_conn)
    catch
      :exit, _ -> :ok
    end
  end

  # ============================================================================
  # Benchmark Functions
  # ============================================================================

  defp benchmark_dummy_jobs(conn, redis_opts, job_count, concurrency) do
    queue_name = "dummy_#{:erlang.unique_integer([:positive])}"
    cleanup_queue(conn, queue_name)

    processed = :counters.new(1, [:atomics])

    # Add jobs
    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}
    Enum.chunk_every(jobs, 1000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    # Create worker connection
    worker_conn = :"dummy_worker_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn))

    # Start worker - dummy job (almost no work)
    {:ok, worker} = Worker.start_link(
      queue: queue_name,
      connection: worker_conn,
      concurrency: concurrency,
      processor: fn _job ->
        :counters.add(processed, 1, 1)
        {:ok, nil}
      end
    )

    start_time = System.monotonic_time(:microsecond)

    timeout = 120_000
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
    cleanup_queue(conn, queue_name)

    %{jobs: final_count, time_ms: time_ms, rate: final_count / (time_ms / 1000)}
  end

  defp benchmark_cpu_jobs(conn, redis_opts, job_count, concurrency) do
    queue_name = "cpu_#{:erlang.unique_integer([:positive])}"
    cleanup_queue(conn, queue_name)

    processed = :counters.new(1, [:atomics])

    # Add jobs
    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}
    Enum.chunk_every(jobs, 1000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    worker_conn = :"cpu_worker_#{:erlang.unique_integer([:positive])}"
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

    timeout = 300_000
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
    cleanup_queue(conn, queue_name)

    %{jobs: final_count, time_ms: time_ms, rate: final_count / (time_ms / 1000)}
  end

  defp benchmark_multi_worker_dummy(conn, redis_opts, job_count, num_workers, concurrency_per_worker) do
    queue_name = "multi_dummy_#{:erlang.unique_integer([:positive])}"
    cleanup_queue(conn, queue_name)

    processed = :counters.new(1, [:atomics])

    # Add jobs
    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}
    Enum.chunk_every(jobs, 1000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    # Start multiple workers
    workers = for i <- 1..num_workers do
      worker_conn = :"multi_dummy_worker_#{i}_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn))

      {:ok, worker} = Worker.start_link(
        queue: queue_name,
        connection: worker_conn,
        concurrency: concurrency_per_worker,
        processor: fn _job ->
          :counters.add(processed, 1, 1)
          {:ok, nil}
        end
      )

      {worker, worker_conn}
    end

    start_time = System.monotonic_time(:microsecond)

    timeout = 120_000
    wait_for_completion(processed, job_count, timeout)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000
    final_count = :counters.get(processed, 1)

    # Cleanup workers
    for {worker, worker_conn} <- workers do
      Worker.close(worker)
      Process.sleep(50)
      try do
        GenServer.stop(worker_conn)
      catch
        :exit, _ -> :ok
      end
    end

    cleanup_queue(conn, queue_name)

    %{jobs: final_count, time_ms: time_ms, rate: final_count / (time_ms / 1000)}
  end

  defp benchmark_multi_worker_cpu(conn, redis_opts, job_count, num_workers, concurrency_per_worker) do
    queue_name = "multi_cpu_#{:erlang.unique_integer([:positive])}"
    cleanup_queue(conn, queue_name)

    processed = :counters.new(1, [:atomics])

    # Add jobs
    jobs = for i <- 1..job_count, do: {"bench_job", %{index: i}, []}
    Enum.chunk_every(jobs, 1000)
    |> Enum.each(fn batch ->
      {:ok, _} = Queue.add_bulk(queue_name, batch, connection: conn)
    end)

    # Start multiple workers
    workers = for i <- 1..num_workers do
      worker_conn = :"multi_cpu_worker_#{i}_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn))

      {:ok, worker} = Worker.start_link(
        queue: queue_name,
        connection: worker_conn,
        concurrency: concurrency_per_worker,
        processor: fn _job ->
          cpu_work(1000)
          :counters.add(processed, 1, 1)
          {:ok, nil}
        end
      )

      {worker, worker_conn}
    end

    start_time = System.monotonic_time(:microsecond)

    timeout = 300_000
    wait_for_completion(processed, job_count, timeout)

    end_time = System.monotonic_time(:microsecond)
    time_ms = (end_time - start_time) / 1000
    final_count = :counters.get(processed, 1)

    # Cleanup workers
    for {worker, worker_conn} <- workers do
      Worker.close(worker)
      Process.sleep(50)
      try do
        GenServer.stop(worker_conn)
      catch
        :exit, _ -> :ok
      end
    end

    cleanup_queue(conn, queue_name)

    %{jobs: final_count, time_ms: time_ms, rate: final_count / (time_ms / 1000)}
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp cpu_work(iterations) do
    Enum.reduce(1..iterations, 0, fn i, acc -> rem(acc + i * i, 1_000_000) end)
  end

  defp wait_for_completion(counter, target, timeout) do
    start = System.monotonic_time(:millisecond)
    do_wait_for_completion(counter, target, start, timeout)
  end

  defp do_wait_for_completion(counter, target, start, timeout) do
    current = :counters.get(counter, 1)
    elapsed = System.monotonic_time(:millisecond) - start

    cond do
      current >= target ->
        :ok
      elapsed > timeout ->
        :timeout
      true ->
        Process.sleep(10)
        do_wait_for_completion(counter, target, start, timeout)
    end
  end

  defp cleanup_queue(conn, queue_name) do
    keys = BullMQ.Keys.new(queue_name)
    all_keys = [
      BullMQ.Keys.wait(keys),
      BullMQ.Keys.active(keys),
      BullMQ.Keys.paused(keys),
      BullMQ.Keys.completed(keys),
      BullMQ.Keys.failed(keys),
      BullMQ.Keys.delayed(keys),
      BullMQ.Keys.prioritized(keys),
      BullMQ.Keys.stalled(keys),
      BullMQ.Keys.limiter(keys),
      BullMQ.Keys.meta(keys),
      BullMQ.Keys.events(keys),
      BullMQ.Keys.pc(keys),
      BullMQ.Keys.marker(keys)
    ]
    BullMQ.RedisConnection.command(conn, ["DEL" | all_keys])
    # Also delete job data keys
    case BullMQ.RedisConnection.command(conn, ["KEYS", "bull:#{queue_name}:*"]) do
      {:ok, job_keys} when is_list(job_keys) and length(job_keys) > 0 ->
        BullMQ.RedisConnection.command(conn, ["DEL" | job_keys])
      _ -> :ok
    end
  end

  defp format_rate(rate) when rate >= 1000 do
    "#{Float.round(rate / 1000, 1)}K"
  end
  defp format_rate(rate), do: "#{round(rate)}"

  defp print_summary(dummy_results, cpu_results, multi_dummy_results, multi_cpu_results, job_count) do
    IO.puts("""

    ╔═══════════════════════════════════════════════════════════════════════════════╗
    ║                    CONCURRENCY SCALING SUMMARY                                ║
    ╚═══════════════════════════════════════════════════════════════════════════════╝

    """)

    # Single worker scaling table
    IO.puts("Single Worker Scaling (#{job_count} jobs per test):")
    IO.puts("┌─────────────┬──────────────────┬──────────────────┐")
    IO.puts("│ Concurrency │ Dummy Jobs/sec   │ CPU Jobs/sec     │")
    IO.puts("├─────────────┼──────────────────┼──────────────────┤")

    Enum.zip(dummy_results, cpu_results)
    |> Enum.each(fn {{conc, dummy}, {_, cpu}} ->
      IO.puts("│ #{String.pad_leading(to_string(conc), 11)} │ #{String.pad_leading(format_rate(dummy.rate), 16)} │ #{String.pad_leading(format_rate(cpu.rate), 16)} │")
    end)

    IO.puts("└─────────────┴──────────────────┴──────────────────┘")

    # Multi-worker table
    IO.puts("\nMultiple Workers Comparison:")
    IO.puts("┌─────────┬─────────────┬───────────┬──────────────────┬──────────────────┐")
    IO.puts("│ Workers │ Concurrency │ Total     │ Dummy Jobs/sec   │ CPU Jobs/sec     │")
    IO.puts("├─────────┼─────────────┼───────────┼──────────────────┼──────────────────┤")

    Enum.zip(multi_dummy_results, multi_cpu_results)
    |> Enum.each(fn {{{num_workers, conc}, dummy}, {_, cpu}} ->
      total = num_workers * conc
      IO.puts("│ #{String.pad_leading(to_string(num_workers), 7)} │ #{String.pad_leading(to_string(conc), 11)} │ #{String.pad_leading(to_string(total), 9)} │ #{String.pad_leading(format_rate(dummy.rate), 16)} │ #{String.pad_leading(format_rate(cpu.rate), 16)} │")
    end)

    IO.puts("└─────────┴─────────────┴───────────┴──────────────────┴──────────────────┘")

    # CSV output for charts
    IO.puts("""

    ═══════════════════════════════════════════════════════════════════════════════
    CSV Output (for charting):
    ═══════════════════════════════════════════════════════════════════════════════

    # Single Worker Scaling
    concurrency,dummy_rate,cpu_rate
    """)

    for {{conc, dummy}, {_, cpu}} <- Enum.zip(dummy_results, cpu_results) do
      IO.puts("#{conc},#{Float.round(dummy.rate, 1)},#{Float.round(cpu.rate, 1)}")
    end

    IO.puts("""

    # Multiple Workers
    workers,concurrency_per_worker,total_concurrency,dummy_rate,cpu_rate
    """)

    for {{{num_workers, conc}, dummy}, {_, cpu}} <- Enum.zip(multi_dummy_results, multi_cpu_results) do
      total = num_workers * conc
      IO.puts("#{num_workers},#{conc},#{total},#{Float.round(dummy.rate, 1)},#{Float.round(cpu.rate, 1)}")
    end
  end
end

# Parse command line arguments
{opts, _, _} = OptionParser.parse(System.argv(),
  strict: [
    jobs: :integer,
    max_concurrency: :integer,
    step: :integer
  ]
)

ConcurrencyScalingBenchmark.run(opts)
