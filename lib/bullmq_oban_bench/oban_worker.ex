defmodule BullmqObanBench.ObanWorker do
  @moduledoc """
  A worker for benchmarking Oban job processing.
  
  Supports different job types:
  - `sleep` - Simulated I/O-bound work (configurable sleep duration)
  - `cpu` - CPU-intensive work (mathematical calculations)
  - minimal - No work (for insertion-only benchmarks)
  """
  use Oban.Worker, queue: :benchmark

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "sleep", "duration_ms" => duration_ms}}) do
    # Simulate I/O-bound work
    Process.sleep(duration_ms)
    :ok
  end

  def perform(%Oban.Job{args: %{"type" => "cpu"}}) do
    # CPU-intensive work
    cpu_work(1000)
    :ok
  end

  def perform(%Oban.Job{args: %{"duration_ms" => duration_ms}}) do
    # Default sleep-based work
    Process.sleep(duration_ms)
    :ok
  end

  def perform(%Oban.Job{}) do
    # Minimal work (for insertion benchmarks)
    :ok
  end

  defp cpu_work(iterations) do
    Enum.reduce(1..iterations, 0, fn i, acc ->
      :math.sin(i) + :math.cos(i) + acc
    end)
  end
end
