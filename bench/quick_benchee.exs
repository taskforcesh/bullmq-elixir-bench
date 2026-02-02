#!/usr/bin/env elixir

# Quick Benchee benchmark
#
# Usage:
#   mix run bench/quick_benchee.exs

alias BullmqObanBench.BenchmarkObanWorker
alias BullmqObanBench.ObanWorker
alias BullmqObanBench.Repo
alias BullMQ.Queue
alias BullMQ.RedisConnection
alias BullMQ.Worker

################ Helpers ################

defmodule BenchmarkHelpers do
  alias BullMQ.RedisConnection
  alias BullmqObanBench.Repo

  def ensure_oban_running do
    case Process.whereis(Oban) do
      nil -> Oban.start_link(repo: Repo, queues: false, plugins: false, log: false)
      _ -> :ok
    end
  end

  def cleanup_bullmq(redis_conn, queue_name) do
    case RedisConnection.command(redis_conn, ["KEYS", "bull:#{queue_name}*"]) do
      {:ok, [_ | _] = keys} -> RedisConnection.command(redis_conn, ["DEL" | keys])
      _ -> :ok
    end
  end

  def cleanup_oban do
    Repo.delete_all(Oban.Job)
  end

  def wait_for_counter(counter, target, timeout) do
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
        Process.sleep(10)
        do_wait(counter, target, deadline)
      end
    end
  end
end

################ Setup ################

IO.puts("Setting up benchmark...")

Application.ensure_all_started(:bullmq_oban_bench)

# Redis setup
redis_config = Application.get_env(:bullmq_oban_bench, :redis)
redis_opts = [host: redis_config[:host], port: redis_config[:port]]
redis_conn = :quick_benchee_redis
{:ok, _} = RedisConnection.start_link(Keyword.merge(redis_opts, name: redis_conn))

# Oban setup
BenchmarkHelpers.ensure_oban_running()

################ Benchmarks ################

IO.puts("""
╔════════════════════════════════════════╗
║  Test 1: Single Job Insertion          ║
╚════════════════════════════════════════╝
""")

Benchee.run(
  %{
    "BullMQ" => fn _ ->
      {:ok, _} = Queue.add("benchee_single", "job", %{data: 1}, connection: redis_conn)
    end,
    "Oban" => fn _ ->
      %{data: 1} |> ObanWorker.new() |> Oban.insert!()
    end
  },
  inputs: %{"Run" => nil},
  time: 3,
  memory_time: 1,
  before_scenario: fn input ->
    BenchmarkHelpers.cleanup_bullmq(redis_conn, "benchee_single")
    BenchmarkHelpers.cleanup_oban()
    input
  end,
  after_scenario: fn _ ->
    BenchmarkHelpers.cleanup_bullmq(redis_conn, "benchee_single")
    BenchmarkHelpers.cleanup_oban()
  end
)

IO.puts("""
╔════════════════════════════════════════╗
║  Test 2: Bulk Job Insertion (1k/batch) ║
╚════════════════════════════════════════╝
""")

bulk_count = 1000
jobs_bullmq = for i <- 1..bulk_count, do: {"job", %{i: i}, []}
jobs_oban = for i <- 1..bulk_count, do: ObanWorker.new(%{i: i})

Benchee.run(
  %{
    "BullMQ" => fn _ ->
      {:ok, _} = Queue.add_bulk("benchee_bulk", jobs_bullmq, connection: redis_conn)
    end,
    "Oban" => fn _ ->
      Oban.insert_all(jobs_oban)
    end
  },
  inputs: %{"Run" => nil},
  time: 3,
  memory_time: 1,
  before_each: fn input ->
    BenchmarkHelpers.cleanup_bullmq(redis_conn, "benchee_bulk")
    BenchmarkHelpers.cleanup_oban()
    input
  end
)

IO.puts("""
╔════════════════════════════════════════╗
║  Test 3: Processing (500 jobs)         ║
╚════════════════════════════════════════╝
""")

proc_count = 500
concurrency = 50
duration_ms = 5

# Use removeOnComplete to keep Redis clean without nuking keys manually
proc_jobs_bullmq = for i <- 1..proc_count, do: {"job", %{i: i}, [removeOnComplete: true]}

proc_jobs_oban =
  for i <- 1..proc_count, do: BenchmarkObanWorker.new(%{i: i, duration_ms: duration_ms})

# Setup shared counter
processed_counter = :counters.new(1, [:atomics])
:persistent_term.put(:benchmark_counter_ref, processed_counter)

# Setup BullMQ worker (hot)
proc_queue_name = "benchee_proc_persistent"
BenchmarkHelpers.cleanup_bullmq(redis_conn, proc_queue_name)

worker_conn = :benchee_worker_persistent
{:ok, w_conn_pid} = RedisConnection.start_link(Keyword.merge(redis_opts, name: worker_conn))

{:ok, bullmq_worker} =
  Worker.start_link(
    queue: proc_queue_name,
    connection: worker_conn,
    concurrency: concurrency,
    processor: fn _job ->
      Process.sleep(duration_ms)
      :counters.add(processed_counter, 1, 1)
      {:ok, nil}
    end
  )

# Setup Oban queue (hot)
Oban.start_queue(queue: :benchmark, limit: concurrency)

Benchee.run(
  %{
    "BullMQ" => fn _ ->
      # Reset counter
      :counters.put(processed_counter, 1, 0)

      # Enqueue
      {:ok, _} = Queue.add_bulk(proc_queue_name, proc_jobs_bullmq, connection: redis_conn)

      # Wait
      BenchmarkHelpers.wait_for_counter(processed_counter, proc_count, 30_000)
    end,
    "Oban" => fn _ ->
      # Reset counter
      :counters.put(processed_counter, 1, 0)

      # Enqueue
      Oban.insert_all(proc_jobs_oban)

      # Wait
      BenchmarkHelpers.wait_for_counter(processed_counter, proc_count, 30_000)
    end
  },
  inputs: %{"Run" => nil},
  time: 10,
  warmup: 2,
  before_each: fn input ->
    # Cleanup DB only (BullMQ cleans itself via removeOnComplete)
    BenchmarkHelpers.cleanup_oban()
    input
  end
)

IO.puts("Cleaning up...")
Worker.close(bullmq_worker)
GenServer.stop(w_conn_pid)
BenchmarkHelpers.cleanup_bullmq(redis_conn, proc_queue_name)

Oban.stop_queue(queue: :benchmark)
:persistent_term.erase(:benchmark_counter_ref)

IO.puts("Benchmark done!")
