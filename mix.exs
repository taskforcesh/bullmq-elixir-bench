defmodule BullmqObanBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :bullmq_oban_bench,
      version: "1.0.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Docs
      name: "BullMQ vs Oban Benchmark",
      source_url: "https://github.com/taskforcesh/bullmq-elixir-bench",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BullmqObanBench.Application, []}
    ]
  end

  defp deps do
    [
      # BullMQ for Redis-based job queue (local dev version)
      {:bullmq, path: "../bullmq/elixir"},

      # Oban for PostgreSQL-based job queue
      {:oban, "~> 2.18"},

      # PostgreSQL adapter for Ecto (required by Oban)
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},

      # Redis client (pulled by BullMQ but explicit for clarity)
      {:redix, "~> 1.3"},

      # Documentation
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate"],
      reset: ["ecto.drop", "ecto.create", "ecto.migrate"],
      "bench.compare": ["run bench/comparison_bench.exs"],
      "bench.bulk": ["run bench/bulk_bench.exs"],
      "bench.quick": ["run bench/quick_bench.exs"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
