defmodule BullmqObanBench.BenchmarkObanWorker do
  use Oban.Worker, queue: :benchmark

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"duration_ms" => duration_ms}}) do
    Process.sleep(duration_ms)

    # Increment counter if configured
    case :persistent_term.get(:benchmark_counter_ref, nil) do
      nil -> :ok
      ref -> :counters.add(ref, 1, 1)
    end

    :ok
  end
end
