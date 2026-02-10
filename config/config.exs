import Config

config :bullmq_oban_bench, ecto_repos: [BullmqObanBench.Repo]

# PostgreSQL configuration for Oban
config :bullmq_oban_bench, BullmqObanBench.Repo,
  database: System.get_env("POSTGRES_DB", "bullmq_oban_bench_dev"),
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool_size: 150,  # Should exceed max concurrency to avoid connection contention
  log: false

# Redis configuration for BullMQ
config :bullmq_oban_bench, :redis,
  host: System.get_env("REDIS_HOST", "localhost"),
  port: String.to_integer(System.get_env("REDIS_PORT", "6379"))

# Oban configuration - start with queues disabled (benchmark controls them)
config :bullmq_oban_bench, Oban,
  repo: BullmqObanBench.Repo,
  queues: false,
  plugins: false,
  log: false

# Import environment specific config
import_config "#{config_env()}.exs"
