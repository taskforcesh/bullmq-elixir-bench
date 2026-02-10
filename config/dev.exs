import Config

# Development-specific configuration
# Default values work for local development with Docker or native installs
# Suppress debug and info logs during benchmarks for cleaner output
config :logger, level: :warning