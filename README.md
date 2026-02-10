# BullMQ Elixir vs Oban Benchmark

A comprehensive, fair benchmark comparing [BullMQ Elixir](https://github.com/taskforcesh/bullmq) (Redis-backed) and [Oban](https://github.com/oban-bg/oban) (PostgreSQL-backed) job queues.

## Overview

This benchmark compares two popular Elixir job queue libraries with proper methodology:

| Feature | BullMQ Elixir | Oban |
|---------|---------------|------|
| Backend | Redis (in-memory) | PostgreSQL/MySQL/SQLite |
| Persistence | Redis persistence (RDB/AOF) | ACID compliant |
| Transactions | No | Yes (database transactions) |
| Architecture | Event-driven, Lua scripts | Polling-based, SQL queries |

### Benchmark Methodology

- **PostgreSQL pool_size: 150** - Exceeds concurrency to avoid connection bottlenecks
- **BullMQ Redis pool_size: matches concurrency** - Fair comparison without connection starvation
- **Multiple runs with full statistics** - Mean, median, std-dev, min, max, P95, P99
- **Realistic throughput validation** - Numbers are validated against theoretical limits
- **Sustained workload option** - Test performance over minutes, not just seconds

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

# Sustained workload test (60 seconds)
mix bench.compare --sustained-duration 60

# Run specific test categories
mix bench.compare --only processing
mix bench.compare --only pure-overhead

# All options
mix bench.compare \
  --jobs 20000 \
  --process-jobs 10000 \
  --concurrency 100 \
  --job-duration 10 \
  --runs 5 \
  --sustained-duration 60
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--jobs` | 10000 | Number of jobs for insertion tests |
| `--process-jobs` | 50000 | Number of jobs for processing tests |
| `--concurrency` | 100 | Worker concurrency level |
| `--job-duration` | 10 | Simulated job duration in ms |
| `--runs` | 5 | Number of benchmark runs (full statistics collected) |
| `--sustained-duration` | disabled | Run sustained workload test for N seconds |
| `--only` | all | Run only specific tests (insert, processing, pure-overhead) |

## Tests Performed

### 1. Single Job Insertion
Measures the throughput of inserting jobs one at a time sequentially.
- BullMQ: `Queue.add/4`
- Oban: `Oban.insert!/1`

### 1b. Concurrent Single Job Insertion
Measures throughput with multiple concurrent inserters (concurrency=10).

### 2. Bulk Job Insertion
Measures the throughput of inserting jobs in batches of 1000.
- BullMQ: `Queue.add_bulk/3`
- Oban: `Oban.insert_all/1`

### 2b. Concurrent Bulk Job Insertion  
Measures bulk throughput with multiple concurrent inserters.

### 3. Job Processing (10ms simulated work)
Measures job processing throughput with simulated I/O work.
- Tests with both 10 and 100 workers
- **Theoretical max**: workers × (1000ms / job_duration) jobs/sec
- With 100 workers @ 10ms: theoretical max = 10,000 jobs/sec

### 4. CPU-Bound Work
Measures job processing throughput with CPU-bound work (1000 sin/cos calculations).

### 5. Pure Queue Overhead
Measures raw queue throughput with minimal work (just counter increment).
This shows the upper bound of what each queue can handle.

### 6. Sustained Workload (optional)
Tests performance under continuous load for a configurable duration.
Use `--sustained-duration N` to enable (N = seconds).

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
║                  (Statistics from 5 runs per test)                            ║
╚═══════════════════════════════════════════════════════════════════════════════╝

┌─────────────────────────────────┬───────────────────┬───────────────────┬────────────────┐
│ Test                            │ BullMQ (Redis)    │ Oban (PostgreSQL) │ Difference     │
├─────────────────────────────────┼───────────────────┼───────────────────┼────────────────┤
│ Single Job Insert (5000)        │ 4.4K jobs/sec     │ 2.1K jobs/sec     │ +116%          │
│ Concurrent Insert (5000, c=10)  │ 18.5K jobs/sec    │ 9.4K jobs/sec     │ +96%           │
│ Bulk Insert (5000)              │ 37.5K jobs/sec    │ 35.9K jobs/sec    │ +4.5%          │
│ Concurrent Bulk (5000, c=10)    │ 40.0K jobs/sec    │ 41.2K jobs/sec    │ -2.9%          │
│ 10ms work (5000, w=10)          │ 866 jobs/sec      │ 500 jobs/sec      │ +73%           │
│ 10ms work (5000, w=100)         │ 8.2K jobs/sec     │ 3.4K jobs/sec     │ +140%          │
│ CPU work (5000, w=100)          │ 24.5K jobs/sec    │ 4.0K jobs/sec     │ +512%          │
│ Pure overhead (5000, w=100)     │ 24.4K jobs/sec    │ 4.3K jobs/sec     │ +466%          │
└─────────────────────────────────┴───────────────────┴───────────────────┴────────────────┘

DETAILED STATISTICS for 10ms work (100 workers):
┌────────────┬───────────────────────┬───────────────────────┐
│ Metric     │ BullMQ                │ Oban                  │
├────────────┼───────────────────────┼───────────────────────┤
│ Mean       │ 8.2K                  │ 3.4K                  │
│ Median     │ 8.2K                  │ 3.4K                  │
│ Std Dev    │ 6.6                   │ 962.2                 │
│ Min        │ 8.2K                  │ 2.7K                  │
│ Max        │ 8.2K                  │ 4.1K                  │
│ P95        │ 8.2K                  │ 4.0K                  │
│ P99        │ 8.2K                  │ 4.1K                  │
└────────────┴───────────────────────┴───────────────────────┘

Notes:
• For 10ms work tests, theoretical max with 100 workers: 10,000 jobs/sec
• BullMQ achieves ~82% of theoretical max, Oban achieves ~34%
• Bulk insert is nearly identical - PostgreSQL multi-row INSERT is highly optimized
```

### Understanding Throughput Limits

For job processing tests with simulated work:
- **Theoretical maximum** = workers × (1000ms / job_duration_ms)
- With 100 workers @ 10ms work: max = 100 × 100 = **10,000 jobs/sec**

Results exceeding this would indicate a timing bug. Both libraries should approach but not exceed this limit.

## Understanding the Results

- **Positive difference**: BullMQ is faster
- **Negative difference**: Oban is faster

### Key Observations

1. **Single/Concurrent Insertion**: BullMQ is ~2x faster due to Redis in-memory operations vs PostgreSQL disk I/O.

2. **Bulk Operations**: Nearly identical performance! PostgreSQL's multi-row INSERT is highly optimized. For bulk inserts, Oban may even be slightly faster due to a single SQL statement vs multiple Redis commands.

3. **Processing with I/O Work**: BullMQ achieves ~82% of theoretical max while Oban achieves ~34%. The difference comes from BullMQ's poll-free architecture (blocking Redis commands) vs Oban's polling approach.

4. **Pure Overhead**: When jobs do minimal work, BullMQ can process 24K+ jobs/sec vs Oban's 4-5K. This represents the upper bound of each queue's throughput.

### Configuration Matters

These benchmarks use carefully tuned configurations:
- **PostgreSQL pool_size: 150** - Prevents connection contention with 100 workers
- **BullMQ pool_size: 100** - Matches concurrency to avoid Redis connection bottlenecks

With default pool sizes (e.g., pool_size: 10), both libraries would show artificially lower performance due to connection starvation.

## When to Choose What

| Consideration | BullMQ (Redis) | Oban (PostgreSQL) |
|---------------|----------------|-------------------|
| Speed | 2-5x faster for queue operations | Sufficient for most use cases |
| Bulk Insert | ~Same performance | ~Same performance |
| Durability | Depends on Redis config (RDB/AOF) | ACID compliant by default |
| Transactions | Separate from app DB | Same DB as your app |
| Complexity | Requires Redis infrastructure | Uses existing PostgreSQL |
| Backups | Separate backup strategy | Backed up with app data |
| Ecosystem | Multi-language support (Node, Python, Elixir, PHP) | Elixir-only |

## Sustained Workload Testing

For production-realistic benchmarks, use the sustained workload option:

```bash
# Run for 60 seconds of continuous load
mix bench.compare --sustained-duration 60

# Run for 5 minutes
mix bench.compare --sustained-duration 300
```

This continuously enqueues and processes jobs for the specified duration, providing a more realistic picture of performance under sustained load.

## Benchmark Methodology

### Addressing Common Concerns

1. **Connection pool sizing**: PostgreSQL pool_size is set to 150 (exceeds 100 workers) to avoid connection contention. BullMQ's Redis pool_size is set to match concurrency.

2. **Statistical rigor**: Each test runs multiple times with full statistics (mean, median, std-dev, min, max, P95, P99) - not cherry-picked best results.

3. **Theoretical validation**: Processing benchmarks are validated against theoretical limits. With 100 workers @ 10ms work, max = 10,000 jobs/sec. Results exceeding this would indicate bugs.

4. **Concurrent insertion**: Benchmark includes concurrent insertion tests (not just sequential) to simulate realistic multi-producer scenarios.

5. **Sustained workloads**: Optional `--sustained-duration` flag allows testing over minutes/hours instead of just seconds.

6. **Timing accuracy**: Timing starts BEFORE workers begin processing, not after warm-up, ensuring accurate measurement.

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

