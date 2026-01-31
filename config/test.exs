import Config

# Test-specific configuration
config :bullmq_oban_bench, BullmqObanBench.Repo,
  database: "bullmq_oban_bench_test",
  pool: Ecto.Adapters.SQL.Sandbox
