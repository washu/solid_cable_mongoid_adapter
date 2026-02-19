# Performance Benchmarks

This directory contains performance benchmarks for SolidCableMongoidAdapter.

## Quick Start

**Run with Docker (Recommended):**
```bash
./benchmark/run_benchmark.sh
```

This script will:
1. ✅ Check if Docker is running
2. 🚀 Start a MongoDB 7.0 replica set in Docker
3. ⏳ Wait for MongoDB to initialize
4. 📊 Run the complete benchmark suite
5. 🧹 Clean up the Docker container

**Manual Run:**

If you already have MongoDB replica set running:
```bash
bundle exec ruby benchmark/benchmark.rb
```

## What Gets Measured

### 1. Broadcast Latency
Tests message insertion time across different message sizes:
- 100 bytes (small messages)
- 1 KB (typical messages)
- 10 KB (large messages)
- 100 KB (very large messages)

Reports: Average, Min, Max, and P95 latencies

### 2. Throughput (Standard)
Measures how many messages per second can be broadcast:
- Sends 10,000 messages
- Calculates messages/second
- Reports average latency per message

### 3. Throughput (High-Volume)
Optional test for sustained high-volume performance:
- Sends 100,000 messages (100 byte payloads)
- Takes 2-5 minutes to complete
- Shows progress indicators every 10%
- Enable with: `BENCHMARK_HIGH_VOLUME=true ./run_benchmark.sh`

### 4. Channel Filtering Impact
Demonstrates the efficiency of channel filtering:
- Broadcasts to 100 different channels
- Shows collection size and timing

### 5. Subscription Performance
Measures subscription operations:
- Subscribe latency
- Unsubscribe latency

### 6. Instrumentation Overhead
Tests ActiveSupport::Notifications performance:
- Sends 100 instrumented messages
- Measures overhead per event

## Sample Output

```
=== SolidCableMongoidAdapter Performance Benchmark ===

--- Benchmark 1: Broadcast Latency ---
Message size: 100 bytes
  Avg: 1.47ms, Min: 0.63ms, Max: 7.33ms, P95: 2.81ms
Message size: 1000 bytes
  Avg: 1.73ms, Min: 0.76ms, Max: 5.82ms, P95: 4.0ms

--- Benchmark 2: Throughput (Standard) ---
Sent 10000 messages in 18.53s
Throughput: 539.57 messages/second
Average latency: 1.85ms per message

--- Benchmark 3: Throughput (High-Volume) ---
Skipped (set BENCHMARK_HIGH_VOLUME=true to run 100k message test)
Note: This test takes 2-5 minutes to complete

--- Benchmark 4: Channel Filtering Impact ---
Broadcasting to 100 channels (1000 total messages)...
Broadcast time: 2.63s
Average per message: 2.63ms

--- Benchmark 5: Subscription Performance ---
Subscribe time: 0.12ms
Unsubscribe time: 0.01ms

--- Benchmark 6: Instrumentation Overhead ---
Sent 100 instrumented messages in 0.22s
Captured 100 instrumentation events
Average instrumented broadcast time: 2.12ms

=== Summary ===
✓ All benchmarks completed
✓ Total messages broadcast: 11500
```

## Customization

Edit `benchmark.rb` to customize:
- Number of iterations
- Message sizes
- Channel counts
- Test scenarios

## Requirements

- Docker (for `run_benchmark.sh`)
- OR MongoDB 4.0+ with replica set (for manual run)
- Ruby 2.7+
- Bundler with dependencies installed

## Troubleshooting

**Docker not running:**
```
❌ Error: Docker is not running
```
→ Start Docker Desktop and try again

**Port 27017 in use:**
```
Error starting userland proxy: listen tcp4 0.0.0.0:27017: bind: address already in use
```
→ Stop your local MongoDB or change the port in `run_benchmark.sh`

**Connection refused:**
```
Mongo::Error::NoServerAvailable
```
→ Ensure MongoDB replica set is initialized (wait longer or check logs)

## Performance Tips

For best results:
- Close other applications
- Run on the same hardware you'll use in production
- Run multiple times and average results
- Test with production-like message sizes
- Test with your actual channel count

## Integration

Use these benchmarks to:
- Establish performance baselines
- Test hardware configurations
- Compare MongoDB versions
- Validate optimizations
- Generate performance documentation
