# BullMQ Elixir vs Oban Benchmark

A comprehensive benchmark comparing [BullMQ Elixir](https://github.com/taskforcesh/bullmq) (Redis-backed) and [Oban](https://github.com/oban-bg/oban) (PostgreSQL-backed) job queues.

## Overview

This benchmark compares two popular Elixir job queue libraries:

| Feature | BullMQ Elixir | Oban |
|---------|---------------|------|
| Backend | Redis (in-memory) | PostgreSQL/MySQL/SQLite |
| Persistence | Redis persistence (RDB/AOF) | ACID compliant |
| Transactions | No | Yes (database transactions) |
| Architecture | Event-driven, Lua scripts | Polling-based, SQL queries |

## Prerequisites

- **Elixir** >= 1.15
- **Redis** running on localhost:6379
- **PostgreSQL** running on localhost:5432

## Quick Start

```bash
# Clone the repository
git clone https://github.com/taskforcesh/bullmq-elixir-bench.git
cd bullmq-elixir-bench/bullmq_oban_bench

# Install dependencies and set up database
mix setup

# Run the quick benchmark (sanity check)
mix bench.quick

# Run the full comparison benchmark
mix bench.compare
```

## Running Benchmarks

### Quick Sanity Check

```bash
mix bench.quick
```

Runs a fast benchmark with minimal job counts to verify setup is working.

### Full Comparison

```bash
mix bench.compare
```

Runs comprehensive tests including:
- Single job insertion
- Bulk job insertion
- Job processing (simulated I/O)
- CPU-intensive processing

### Bulk Insert Analysis

```bash
mix bench.bulk
```

Tests bulk insertion at various job counts to analyze scaling.

### Custom Options

```bash
# Larger job counts
mix bench.compare --jobs 50000 --process-jobs 10000

# Different concurrency
mix bench.compare --concurrency 200

# More runs for statistical significance
mix bench.compare --runs 5

# All options
mix bench.compare \
  --jobs 20000 \
  --process-jobs 10000 \
  --concurrency 100 \
  --job-duration 10 \
  --runs 3
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--jobs` | 10000 | Number of jobs for insertion tests |
| `--process-jobs` | 5000 | Number of jobs for processing tests |
| `--concurrency` | 100 | Worker concurrency level |
| `--job-duration` | 10 | Simulated job duration in ms |
| `--runs` | 3 | Number of benchmark runs (best result used) |

## Tests Performed

### 1. Single Job Insertion
Measures the throughput of inserting jobs one at a time.
- BullMQ: `Queue.add/4`
- Oban: `Oban.insert!/1`

### 2. Bulk Job Insertion
Measures the throughput of inserting jobs in batches of 1000.
- BullMQ: `Queue.add_bulk/3`
- Oban: `Oban.insert_all/1`

### 3. Job Processing (Simulated I/O)
Measures job processing throughput with simulated I/O work (sleep).
Both libraries process jobs with configurable concurrency.

### 4. CPU-Intensive Processing
Measures job processing throughput with CPU-bound work.
Uses mathematical calculations to stress the CPU.

## Environment Configuration

Configure via environment variables:

```bash
# PostgreSQL
export POSTGRES_DB=bullmq_oban_bench_dev
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres
export POSTGRES_HOST=localhost
export POSTGRES_PORT=5432

# Redis
export REDIS_HOST=localhost
export REDIS_PORT=6379
```

## Sample Output

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                         BENCHMARK SUMMARY                                     ║
║                     (Best of 3 runs per test)                                 ║
╚═══════════════════════════════════════════════════════════════════════════════╝

┌─────────────────────────────────┬───────────────────┬───────────────────┬────────────────┐
│ Test                            │ BullMQ (Redis)    │ Oban (PostgreSQL) │ Difference     │
├─────────────────────────────────┼───────────────────┼───────────────────┼────────────────┤
│ Single Job Insert (10000)       │ 6.5K jobs/sec     │ 3.9K jobs/sec     │ +66.7%         │
│ Bulk Insert (10000)             │ 44.1K jobs/sec    │ 31.5K jobs/sec    │ +40.0%         │
│ Processing (5000, 10ms)         │ 21.8K jobs/sec    │ 9.2K jobs/sec     │ +137.0%        │
│ CPU Processing (5000)           │ 4.2K jobs/sec     │ 4.1K jobs/sec     │ +2.4%          │
└─────────────────────────────────┴───────────────────┴───────────────────┴────────────────┘
```

## Understanding the Results

- **Positive difference**: BullMQ is faster
- **Negative difference**: Oban is faster

### Expected Patterns

1. **Insertion Performance**: Redis-backed BullMQ typically has higher insertion throughput due to in-memory operations and Lua scripting.

2. **Bulk Operations**: Both libraries benefit from bulk operations, but the relative improvement may differ.

3. **Processing Performance**: With I/O-bound work, differences can be significant as BullMQ's event-driven architecture may have less overhead.

4. **CPU Processing**: Similar performance expected as the bottleneck is CPU, not the queue backend.

## When to Choose What

| Consideration | BullMQ (Redis) | Oban (PostgreSQL) |
|---------------|----------------|-------------------|
| Speed | Generally faster for queue operations | Slightly slower due to disk I/O |
| Durability | Depends on Redis config (RDB/AOF) | ACID compliant by default |
| Transactions | Separate from app DB | Same DB as your app |
| Complexity | Requires Redis infrastructure | Uses existing PostgreSQL |
| Backups | Separate backup strategy | Backed up with app data |
| Ecosystem | Multi-language support (Node, Python, Elixir, PHP) | Elixir-only |

## Docker Setup (Optional)

If you don't have Redis and PostgreSQL installed locally:

```bash
# Start Redis
docker run -d --name redis -p 6379:6379 redis:alpine

# Start PostgreSQL
docker run -d --name postgres \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  postgres:15-alpine
```

## Project Structure

```
bullmq_oban_bench/
├── bench/
│   ├── comparison_bench.exs   # Full comparison benchmark
│   ├── quick_bench.exs        # Quick sanity check
│   └── bulk_bench.exs         # Bulk insert analysis
├── config/
│   ├── config.exs             # Main configuration
│   ├── dev.exs                # Development config
│   ├── test.exs               # Test config
│   └── prod.exs               # Production config
├── lib/
│   └── bullmq_oban_bench/
│       ├── application.ex     # Application supervisor
│       ├── repo.ex            # Ecto Repo for Oban
│       └── oban_worker.ex     # Oban benchmark worker
├── priv/
│   └── repo/
│       └── migrations/        # Database migrations
├── mix.exs                    # Project definition
└── README.md                  # This file
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Related Links

- [BullMQ Documentation](https://docs.bullmq.io/)
- [BullMQ Elixir Package](https://hex.pm/packages/bullmq)
- [Oban Documentation](https://hexdocs.pm/oban)
- [BullMQ vs Oban Benchmark Article](https://bullmq.io/articles/benchmarks/bullmq-elixir-vs-oban/)

## License

MIT License - See [LICENSE](LICENSE) for details.

