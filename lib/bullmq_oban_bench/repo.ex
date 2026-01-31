defmodule BullmqObanBench.Repo do
  @moduledoc """
  Ecto Repo for Oban's PostgreSQL backend.
  """
  use Ecto.Repo,
    otp_app: :bullmq_oban_bench,
    adapter: Ecto.Adapters.Postgres
end
