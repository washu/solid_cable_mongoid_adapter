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

**Options (via environment variables):**
```bash
# Run the optional 100k-message high-volume test
BENCHMARK_HIGH_VOLUME=true ./benchmark/run_benchmark.sh

# Use more messages per connection-scale test (default: 500)
FANOUT_MESSAGES=1000 ./benchmark/run_benchmark.sh
```

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

### 7. Write Concern Comparison
Compares `w=1` (acknowledged) vs `w=0` (fire-and-forget) write performance:
- 5,000 messages each
- Shows throughput delta and latency reduction

### 8. Subscriber Load – Fan-out at Scale (100 / 1,000 / 10,000 subscribers)

This is the most important benchmark for understanding real-world scaling.

#### Two scenarios at each subscriber count

| Scenario | Description | Models |
|----------|-------------|--------|
| **A – Single channel** | All N subscribers on one channel. One broadcast → N callbacks. | Chat rooms, presence channels |
| **B – Unique channels** | Each subscriber on its own channel (1:1). One broadcast → 1 callback. | Private user channels (`user:123`) |

#### How fan-out is measured correctly

`adapter.broadcast(channel, msg)` **only inserts into MongoDB** — it does not call subscriber callbacks. Callback dispatch happens when the background Listener thread picks up the change stream event and calls `SubscriberMap#broadcast`. To measure pure Ruby-side fan-out cost without MongoDB network latency in the loop, the benchmark calls `adapter.listener.broadcast(channel, msg)` directly — exactly what the Listener does after receiving an event.

A separate **end-to-end delivery spot-check** sends 5 real messages via `adapter.broadcast` and waits up to 10s for the Listener thread to deliver them, confirming the full MongoDB → Change Stream → callback path works.

#### Why all three adapters have identical fan-out cost

MongoDB, Redis, and PostgreSQL/solid_cable all use the same `SubscriberMap` from ActionCable. Fan-out code is byte-for-byte identical. The difference is only in *broadcast insertion latency* (Benchmarks 1 & 2) and *delivery latency* (change stream vs pub/sub vs NOTIFY).

#### Delivery counter verification

Each callback increments a mutex-protected counter. The benchmark resets counters after a warm-up broadcast, so 100% delivery is expected. If < 100%: MongoDB is running standalone without a replica set and the end-to-end check will indicate this.

## Sample Output

```
=== SolidCableMongoidAdapter Performance Benchmark ===

--- Benchmark 1: Broadcast Latency (MongoDB insert round-trip) ---
  100 bytes → Avg: 1.47ms  Min: 0.63ms  Max: 7.33ms  P95: 2.81ms

--- Benchmark 2: Throughput (10,000 messages) ---
  Sent 10,000 messages in 18.53s
  Throughput:       539 msg/s
  Avg latency:      1.85ms/msg

--- Benchmark 8: Subscriber Load – Fan-out at Scale ---

  ╔══ 1,000 subscribers ══════════════════════════════════
  ║  [A] Single channel – 1,000 subscribers, 1 channel
  ║    Subscribe 1,000 callbacks: 2.3ms (0.0023ms each)
  ║    Broadcast 200 msgs → 200,000 expected deliveries
  ║    Actual delivered: 200,000/200,000 (100.0%)
  ║    Fan-out throughput: 1,240,000 deliveries/s
  ║    Avg per broadcast:  0.806ms (dispatching to 1,000 callbacks)
  ║    Unsubscribe 1,000 callbacks: 1.8ms
  ║
  ║  [B] Unique channels – 1,000 subscribers, 1,000 channels (1:1)
  ║    Subscribe 1,000 callbacks (unique channels): 3.1ms
  ║    Broadcast 200 msgs across 1,000 channels
  ║    Actual delivered: 200/200 (100.0%)
  ║    Dispatch throughput: 4,200,000 deliveries/s
  ║    Avg per broadcast:   0.238ms (dispatching to 1 callback, 1,000 channels registered)
  ║    Unsubscribe 1,000 callbacks: 2.1ms
  ╚════════════════════════════════════════════════════

  ── End-to-End Delivery Spot-Check ──────────────────────────────────
  ✅ Delivered 5/5 messages in 42ms (full MongoDB round-trip confirmed)

  Fan-out Comparison Table (deliveries/s, higher is better)
  ┌──────────┬──────────────────────────┬──────────────────────────┬──────────────────┐
  │ Subs     │  Single channel (A)      │  Unique channels (B)     │  Redis/PG (ref)  │
  │          │  deliveries/s  | ms/bcst │  deliveries/s  | ms/bcst │  (same code path)│
  ├──────────┼──────────────────────────┼──────────────────────────┼──────────────────┤
  │ 100      │      8,500,000 | 0.012ms │      6,200,000 | 0.016ms │       ~380,000   │
  │ 1,000    │      1,240,000 | 0.806ms │      4,200,000 | 0.238ms │       ~120,000   │
  │ 10,000   │        130,000 |  7.7ms  │      3,800,000 | 0.263ms │        ~15,000   │
  └──────────┴──────────────────────────┴──────────────────────────┴──────────────────┘

=== Summary ===
✓ All benchmarks completed
✓ Total broadcast() calls this run: 26,305
Fan-out results (pure Ruby SubscriberMap dispatch):
  100 subs │ single-ch: 8,500,000 del/s (100.0% delivered) │ unique-ch: 6,200,000 del/s (100.0% delivered)
```

**Why single-channel slows with more subscribers:** `SubscriberMap` holds a mutex while iterating all N callbacks — O(N) per broadcast. **Why unique-channel stays fast:** 1 callback per broadcast — O(1) per message regardless of total registered subscribers.

## Customization

Edit `benchmark.rb` to customize:
- Number of iterations
- Message sizes
- Channel counts
- `FANOUT_MESSAGES` env var for connection-scale test depth
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

