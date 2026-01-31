import Config

# Production configuration - use environment variables
config :bullmq_oban_bench, BullmqObanBench.Repo,
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "20"))
