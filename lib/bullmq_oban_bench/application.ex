defmodule BullmqObanBench.Application do
  @moduledoc """
  Application supervisor for the BullMQ vs Oban benchmark.
  Starts the Ecto Repo for Oban's PostgreSQL backend.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BullmqObanBench.Repo
    ]

    opts = [strategy: :one_for_one, name: BullmqObanBench.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
