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
4. 📊 Run the complete benchmark suite (benchmarks 1–9)
5. 🧹 Clean up the Docker container

**Manual Run:**

If you already have MongoDB replica set running:
```bash
bundle exec ruby benchmark/benchmark.rb
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MONGODB_URI` | `mongodb://localhost:27017/solid_cable_benchmark` | MongoDB connection URI |
| `BENCHMARK_HIGH_VOLUME` | _(unset)_ | Set `true` to run 100k-message throughput test (~2-5 min) |
| `FANOUT_MESSAGES` | `500` | Messages per fan-out round in Benchmark 8 |

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
- Enable with: `BENCHMARK_HIGH_VOLUME=true ./benchmark/run_benchmark.sh`

### 4. Channel Filtering Impact
Demonstrates the efficiency of channel filtering:
- Broadcasts to 100 different channels (1,000 total messages)
- Shows collection size and per-message timing

### 5. Subscription Performance
Measures subscription operations:
- Subscribe latency
- Unsubscribe latency

### 6. Instrumentation Overhead
Tests ActiveSupport::Notifications performance:
- Sends 100 instrumented messages
- Measures per-event overhead

### 7. Write Concern Comparison (w=1 vs w=0)
Compares acknowledged vs fire-and-forget writes:
- 5,000 messages each
- Throughput, latency, and improvement percentage
- Helps you decide the right `write_concern` setting

### 8. Subscriber Fan-out at Scale
Benchmarks pure Ruby `SubscriberMap` dispatch at 100, 1,000, and 10,000 subscribers.

Two scenarios per subscriber count:

**[A] Single channel** — all N subs on one channel.  
One broadcast dispatches N callbacks. Models chat rooms / presence channels.

**[B] Unique channels** — 1 sub per channel.  
One broadcast dispatches exactly 1 callback regardless of how many total channels exist.  
Models private user channels (`user:123`). Stays O(1) at any scale.

> These numbers measure the in-process dispatch path only (no MongoDB round-trip). The Listener
> thread calls this same code after receiving a change-stream event.

### 9. End-to-End Delivery Spot-Check
Verifies the full path works end-to-end:

```
adapter.broadcast(ch, msg)
  → MongoDB insert
    → Change Stream event on Listener thread
      → SubscriberMap.broadcast(ch, msg)
        → callback invoked
```

Sends 5 messages and waits up to 10 seconds for delivery confirmation.
Reports actual round-trip time. Requires a replica set (Change Streams).

## Sample Output

```
=== SolidCableMongoidAdapter Performance Benchmark ===
MongoDB: mongodb://localhost:27017/solid_cable_benchmark
Ruby:    3.4.7
Date:    2026-06-01 16:29:02

--- Benchmark 1: Broadcast Latency ---
Message size: 100 bytes
  Avg: 1.2ms, Min: 0.49ms, Max: 6.91ms, P95: 1.57ms
Message size: 1,000 bytes
  Avg: 0.91ms, Min: 0.6ms, Max: 5.45ms, P95: 1.27ms
Message size: 10,000 bytes
  Avg: 0.93ms, Min: 0.6ms, Max: 4.29ms, P95: 1.53ms
Message size: 100,000 bytes
  Avg: 3.1ms, Min: 2.01ms, Max: 11.55ms, P95: 4.06ms

--- Benchmark 2: Throughput (Standard, 10k messages) ---
Sent 10,000 messages in 7.56s
Throughput: 1,323 msg/s
Average latency: 0.76ms per message

--- Benchmark 3: Throughput (High-Volume) ---
Skipped (set BENCHMARK_HIGH_VOLUME=true to run 100k message test)

--- Benchmark 4: Channel Filtering Impact ---
Broadcasting to 100 channels (1,000 total messages)...
Broadcast time: 0.68s
Average per message: 0.68ms
Messages in collection: 11,400

--- Benchmark 5: Subscription Performance ---
Subscribe time:   0.13ms
Unsubscribe time: 0.01ms

--- Benchmark 6: Instrumentation Overhead ---
Sent 100 instrumented messages in 0.087s
Captured 100 broadcast instrumentation events
Avg instrumented broadcast time: 0.83ms

--- Benchmark 7: Write Concern Comparison (w=1 vs w=0) ---
Testing with write concern w=1 (acknowledged)...
  Sent 5,000 messages in 3.94s
  Throughput: 1,270 msg/s
  Avg latency: 0.79ms/msg

Testing with write concern w=0 (fire-and-forget)...
  Sent 5,000 messages in 0.97s
  Throughput: 5,137 msg/s
  Avg latency: 0.19ms/msg

  Performance Comparison:
  -- w=0 is 4.0x faster than w=1 (304.6% improvement)
  -- Latency reduced by 75.3%

--- Benchmark 8: Subscriber Fan-out at Scale ---
(500 msgs x [A] single channel + [B] unique channels @ 100/1k/10k subs)

  +-- 100 subscribers ----------------------------------------
  |  [A] Single channel - 100 subs, 1 channel
  |    Subscribe 100 callbacks: 0.1ms (0.001ms each)
  |    Broadcast 500 msgs -> 50,000 expected deliveries
  |    Actual delivered: 50,000/50,000 (100.0%)
  |    Fan-out throughput: 3,501,401 deliveries/s
  |    Avg per broadcast:  0.029ms (100 callbacks dispatched)
  ...

--- Fan-out Comparison Table ---
  +-----------+-----------------------------+-----------------------------+------------------+
  | Subs      |  [A] Single channel         |  [B] Unique channels        |  Redis/PG (ref)  |
  |           |  deliveries/s  | ms/bcast   |  broadcasts/s  | ms/bcast   |  deliveries/s    |
  +-----------+----------------+------------+----------------+------------+------------------+
  | 100       |      3,501,401 |    0.029ms |      1,344,086 |    0.001ms |         ~380,000 |
  | 1,000     |      3,702,223 |     0.27ms |      1,344,086 |    0.001ms |         ~120,000 |
  | 10,000    |      3,609,121 |    2.771ms |      1,424,502 |    0.001ms |          ~15,000 |
  +-----------+----------------+------------+----------------+------------+------------------+

--- Benchmark 9: End-to-End Delivery Spot-Check ---
OK Delivered 5/5 messages in 114ms (full MongoDB round-trip confirmed)

=== Summary ===
  All benchmarks completed
  Total adapter.broadcast() calls: 21,505
  Instrumentation events captured (benchmarks 1-6 only): 100

Fan-out results (pure Ruby SubscriberMap dispatch, no MongoDB round-trip):
     100 subs | single-ch:  3,501,401 del/s (100.0% delivered) | unique-ch:  1,344,086 del/s (100.0% delivered)
   1,000 subs | single-ch:  3,702,223 del/s (100.0% delivered) | unique-ch:  1,344,086 del/s (100.0% delivered)
  10,000 subs | single-ch:  3,609,121 del/s (100.0% delivered) | unique-ch:  1,424,502 del/s (100.0% delivered)
```

## Customization

Edit `benchmark.rb` to customize:
- Number of iterations
- Message sizes
- Channel counts
- Fan-out subscriber counts
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

**Benchmark 9 reports 0/5 delivered:**
→ Run via `./benchmark/run_benchmark.sh` — a replica set is required for Change Streams.
   Standalone MongoDB falls back to polling and may not deliver within the 10-second window.

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
- Decide between `write_concern: 0` and `write_concern: 1`
- Generate performance documentation
