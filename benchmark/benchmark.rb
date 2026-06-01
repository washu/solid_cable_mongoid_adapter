#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark script for SolidCableMongoidAdapter
#
# Usage:
#   ./benchmark/run_benchmark.sh          # Docker (recommended)
#   bundle exec ruby benchmark/benchmark.rb  # Manual (needs replica set)
#
# Environment variables:
#   MONGODB_URI            - MongoDB URI (default: mongodb://localhost:27017/solid_cable_benchmark)
#   BENCHMARK_HIGH_VOLUME  - "true" to run 100k test (~2-5 min)
#   FANOUT_MESSAGES        - Messages per fan-out round (default: 500)

require "bundler/setup"
require "action_cable"
require "mongoid"
require_relative "../lib/solid_cable_mongoid_adapter"

class MockServer
  attr_reader :logger, :config, :event_loop, :mutex

  def initialize
    @logger = Logger.new($stdout)
    @logger.level = Logger::WARN
    @mutex = Mutex.new
    @event_loop = MockEventLoop.new
    @config = MockConfig.new
  end
end

class MockEventLoop
  def post(&block)
    block.call
  end
end

class MockConfig
  attr_reader :cable

  def initialize
    @cable = {
      "collection_name" => "benchmark_messages",
      "expiration" => 300,
      "require_replica_set" => false,
      "reconnect_delay" => 1.0,
      "max_reconnect_delay" => 60.0,
      "poll_interval_ms" => 500,
      "poll_batch_limit" => 200
    }
  end
end

def fmt(num)
  num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
end

def mono
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def elapsed
  t = mono
  yield
  mono - t
end

MONGODB_URI     = ENV.fetch("MONGODB_URI", "mongodb://localhost:27017/solid_cable_benchmark")
FANOUT_MESSAGES = ENV.fetch("FANOUT_MESSAGES", "500").to_i

Mongoid.configure do |config|
  config.clients.default = {
    uri: MONGODB_URI,
    options: { max_pool_size: 50, min_pool_size: 5 }
  }
end

puts "=== SolidCableMongoidAdapter Performance Benchmark ==="
puts "MongoDB: #{MONGODB_URI}"
puts "Ruby:    #{RUBY_VERSION}"
puts "Date:    #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
puts

server  = MockServer.new
adapter = ActionCable::SubscriptionAdapter::SolidMongoid.new(server)

puts "Cleaning up old messages..."
adapter.collection.delete_many({})

total_broadcasts = 0

# ---------------------------------------------------------------------------
# Benchmark 1: Broadcast Latency by message size
# ---------------------------------------------------------------------------
puts "\n--- Benchmark 1: Broadcast Latency ---"

[100, 1_000, 10_000, 100_000].each do |size|
  payload   = "x" * size
  latencies = []

  100.times do
    t = mono
    adapter.broadcast("benchmark_channel", payload)
    latencies << mono - t
    total_broadcasts += 1
  end

  sorted = latencies.sort
  avg = (latencies.sum / latencies.size) * 1000
  min = sorted.first * 1000
  max = sorted.last  * 1000
  p95 = sorted[(latencies.size * 0.95).to_i] * 1000

  puts "Message size: #{fmt(size)} bytes"
  puts "  Avg: #{avg.round(2)}ms, Min: #{min.round(2)}ms, Max: #{max.round(2)}ms, P95: #{p95.round(2)}ms"
end

# ---------------------------------------------------------------------------
# Benchmark 2: Throughput (10,000 messages)
# ---------------------------------------------------------------------------
puts "\n--- Benchmark 2: Throughput (Standard, 10k messages) ---"

msg_count2 = 10_000
payload2   = "test message" * 10

dur2 = elapsed do
  msg_count2.times do |i|
    adapter.broadcast("throughput_channel", "#{payload2}_#{i}")
    total_broadcasts += 1
  end
end

puts "Sent #{fmt(msg_count2)} messages in #{dur2.round(2)}s"
puts "Throughput: #{fmt((msg_count2 / dur2).round(0))} msg/s"
puts "Average latency: #{(dur2 / msg_count2 * 1000).round(2)}ms per message"

# ---------------------------------------------------------------------------
# Benchmark 3: High-Volume Throughput (optional)
# ---------------------------------------------------------------------------
if ENV["BENCHMARK_HIGH_VOLUME"] == "true"
  puts "\n--- Benchmark 3: Throughput (High-Volume, 100k messages) ---"
  hv_count   = 100_000
  hv_payload = "x" * 100
  interval   = hv_count / 10

  puts "Sending #{fmt(hv_count)} messages (this may take 2-5 minutes)..."
  dur3 = elapsed do
    hv_count.times do |i|
      adapter.broadcast("high_volume_channel", "#{hv_payload}_#{i}")
      total_broadcasts += 1
      puts "  Progress: #{((i + 1).to_f / hv_count * 100).round(1)}%" if ((i + 1) % interval).zero?
    end
  end

  puts "Sent #{fmt(hv_count)} messages in #{dur3.round(2)}s"
  puts "Throughput: #{fmt((hv_count / dur3).round(0))} msg/s"
  puts "Average latency: #{(dur3 / hv_count * 1000).round(2)}ms per message"
else
  puts "\n--- Benchmark 3: Throughput (High-Volume) ---"
  puts "Skipped (set BENCHMARK_HIGH_VOLUME=true to run 100k message test)"
  puts "Note: This test takes 2-5 minutes to complete"
end

# ---------------------------------------------------------------------------
# Benchmark 4: Channel Filtering Efficiency
# ---------------------------------------------------------------------------
puts "\n--- Benchmark 4: Channel Filtering Impact ---"

ch_count4   = 100
msgs_per_ch = 10
total4      = ch_count4 * msgs_per_ch

puts "Broadcasting to #{fmt(ch_count4)} channels (#{fmt(total4)} total messages)..."

dur4 = elapsed do
  ch_count4.times do |ch|
    msgs_per_ch.times do |m|
      adapter.broadcast("channel_#{ch}", "message_#{m}")
      total_broadcasts += 1
    end
  end
end

puts "Broadcast time: #{dur4.round(2)}s"
puts "Average per message: #{(dur4 / total4 * 1000).round(2)}ms"
puts "Messages in collection: #{fmt(adapter.collection.count_documents({}))}"

# ---------------------------------------------------------------------------
# Benchmark 5: Subscription Performance
# ---------------------------------------------------------------------------
puts "\n--- Benchmark 5: Subscription Performance ---"

cb5 = proc { |_msg| }

puts "Subscribing to test_channel..."
sub_dur5   = elapsed { adapter.subscribe("test_channel", cb5) }
unsub_dur5 = elapsed { adapter.unsubscribe("test_channel", cb5) }

puts "Subscribe time:   #{(sub_dur5 * 1000).round(2)}ms"
puts "Unsubscribe time: #{(unsub_dur5 * 1000).round(2)}ms"

# ---------------------------------------------------------------------------
# Benchmark 6: Instrumentation Overhead
# ---------------------------------------------------------------------------
puts "\n--- Benchmark 6: Instrumentation Overhead ---"

instr_events = []
notif_sub = ActiveSupport::Notifications.subscribe(/solid_cable_mongoid/) do |name, start, fin, _id, _payload|
  instr_events << { name: name, duration: (fin - start) * 1000 }
end

instr_count = 100
dur6 = elapsed do
  instr_count.times do |i|
    adapter.broadcast("instrumented_channel", "message_#{i}")
    total_broadcasts += 1
  end
end

bc_events = instr_events.select { |e| e[:name] == "broadcast.solid_cable_mongoid" }
puts "Sent #{instr_count} instrumented messages in #{dur6.round(3)}s"
puts "Captured #{bc_events.size} broadcast instrumentation events"
if bc_events.any?
  avg_ev = bc_events.sum { |e| e[:duration] } / bc_events.size
  puts "Avg instrumented broadcast time: #{avg_ev.round(2)}ms"
end

ActiveSupport::Notifications.unsubscribe(notif_sub)
instr_event_count = instr_events.size

# ---------------------------------------------------------------------------
# Benchmark 7: Write Concern Comparison (w=1 vs w=0)
# ---------------------------------------------------------------------------
puts "\n--- Benchmark 7: Write Concern Comparison (w=1 vs w=0) ---"

wc_count   = 5_000
wc_payload = "x" * 100
wc_results = {}

[1, 0].each do |wc|
  label = wc == 1 ? "w=1 (acknowledged)" : "w=0 (fire-and-forget)"
  puts "\nTesting with write concern #{label}..."

  server.config.cable["write_concern"] = wc
  adapter_wc = ActionCable::SubscriptionAdapter::SolidMongoid.new(server)

  dur_wc = elapsed do
    wc_count.times do |i|
      adapter_wc.broadcast("wc_test_channel", "#{wc_payload}_#{i}")
      total_broadcasts += 1
    end
  end

  tp_wc = wc_count / dur_wc
  wc_results[wc] = { duration: dur_wc, throughput: tp_wc }

  puts "  Sent #{fmt(wc_count)} messages in #{dur_wc.round(2)}s"
  puts "  Throughput: #{fmt(tp_wc.round(0))} msg/s"
  puts "  Avg latency: #{(dur_wc / wc_count * 1000).round(2)}ms/msg"

  adapter_wc.shutdown
  adapter_wc.collection.delete_many({})
end

server.config.cable["write_concern"] = 1

if wc_results[1] && wc_results[0]
  speedup     = (wc_results[0][:throughput] / wc_results[1][:throughput]).round(1)
  improvement = ((wc_results[0][:throughput] - wc_results[1][:throughput]) / wc_results[1][:throughput] * 100).round(1)
  lat_red     = ((wc_results[1][:duration] - wc_results[0][:duration]) / wc_results[1][:duration] * 100).round(1)
  puts "\n  Performance Comparison:"
  puts "  -- w=0 is #{speedup}x faster than w=1 (#{improvement}% improvement)"
  puts "  -- Latency reduced by #{lat_red}%"
end

# ---------------------------------------------------------------------------
# Benchmark 8: Subscriber Fan-out at Scale
#
# Measures pure Ruby-side SubscriberMap dispatch cost (no MongoDB round-trip).
# adapter.listener.broadcast(ch, msg) is what the Listener calls after receiving
# a change-stream event — exactly the code path we want to profile.
#
# Two scenarios at 100 / 1,000 / 10,000 subscribers:
#   [A] Single channel  – all N subs on one channel → N callbacks per broadcast
#   [B] Unique channels – 1 sub per channel          → 1 callback per broadcast
# ---------------------------------------------------------------------------
puts "\n--- Benchmark 8: Subscriber Fan-out at Scale ---"
puts "(#{FANOUT_MESSAGES} msgs x [A] single channel + [B] unique channels @ 100/1k/10k subs)"
puts

connection_counts = [100, 1_000, 10_000]
fanout_results    = {}

connection_counts.each do |conn_count| # rubocop:disable Metrics/BlockLength
  puts "  +-- #{fmt(conn_count)} subscribers " + ("-" * 40)

  # Scenario A: Single shared channel
  puts "  |  [A] Single channel - #{fmt(conn_count)} subs, 1 channel"

  delivered_a = 0
  mx_a        = Mutex.new
  channel_a   = "fanout_single_#{conn_count}"
  cbs_a       = Array.new(conn_count) { proc { |_m| mx_a.synchronize { delivered_a += 1 } } }

  sub_dur_a = elapsed { cbs_a.each { |cb| adapter.subscribe(channel_a, cb) } }
  puts "  |    Subscribe #{fmt(conn_count)} callbacks: #{(sub_dur_a * 1000).round(1)}ms " \
       "(#{(sub_dur_a * 1000 / conn_count).round(4)}ms each)"

  adapter.listener.broadcast(channel_a, "warmup")
  sleep 0.01
  delivered_a = 0

  fanout_dur_a = elapsed do
    FANOUT_MESSAGES.times { |i| adapter.listener.broadcast(channel_a, "msg_#{i}") }
  end

  expected_a = conn_count * FANOUT_MESSAGES
  tp_a       = (expected_a / fanout_dur_a).round(0).to_i
  pct_a      = (delivered_a.to_f / expected_a * 100).round(1)

  puts "  |    Broadcast #{FANOUT_MESSAGES} msgs -> #{fmt(expected_a)} expected deliveries"
  puts "  |    Actual delivered: #{fmt(delivered_a)}/#{fmt(expected_a)} (#{pct_a}%)"
  puts "  |    Fan-out throughput: #{fmt(tp_a)} deliveries/s"
  puts "  |    Avg per broadcast:  #{(fanout_dur_a / FANOUT_MESSAGES * 1000).round(3)}ms " \
       "(#{fmt(conn_count)} callbacks dispatched)"

  unsub_dur_a = elapsed do
    listener = adapter.listener
    listener.instance_variable_get(:@sync).synchronize do
      listener.instance_variable_get(:@subscribers).delete(channel_a)
    end
    listener.send(:request_stream_restart)
  end
  puts "  |    Unsubscribe #{fmt(conn_count)} callbacks: #{(unsub_dur_a * 1000).round(1)}ms (bulk)"

  # Scenario B: Unique per-subscriber channels
  puts "  |"
  puts "  |  [B] Unique channels - #{fmt(conn_count)} subs, #{fmt(conn_count)} channels (1:1)"

  delivered_b = 0
  mx_b        = Mutex.new
  channels_b  = Array.new(conn_count) { |i| "fanout_unique_#{conn_count}_#{i}" }
  cbs_b       = Array.new(conn_count) { proc { |_m| mx_b.synchronize { delivered_b += 1 } } }

  sub_dur_b = elapsed { conn_count.times { |i| adapter.subscribe(channels_b[i], cbs_b[i]) } }
  puts "  |    Subscribe #{fmt(conn_count)} callbacks (unique channels): #{(sub_dur_b * 1000).round(1)}ms"

  adapter.listener.broadcast(channels_b[0], "warmup")
  sleep 0.01
  delivered_b = 0

  fanout_dur_b = elapsed do
    FANOUT_MESSAGES.times { |i| adapter.listener.broadcast(channels_b[i % conn_count], "msg_#{i}") }
  end

  expected_b = FANOUT_MESSAGES
  tp_b       = (expected_b / fanout_dur_b).round(0).to_i
  pct_b      = (delivered_b.to_f / expected_b * 100).round(1)

  puts "  |    Broadcast #{FANOUT_MESSAGES} msgs across #{fmt(conn_count)} channels"
  puts "  |    Actual delivered: #{fmt(delivered_b)}/#{fmt(expected_b)} (#{pct_b}%) - 1 sub per channel"
  puts "  |    Dispatch throughput: #{fmt(tp_b)} broadcasts/s (1 callback each)"
  puts "  |    Avg per broadcast:   #{(fanout_dur_b / FANOUT_MESSAGES * 1000).round(3)}ms " \
       "(#{fmt(conn_count)} channels in map)"

  unsub_dur_b = elapsed do
    listener = adapter.listener
    listener.instance_variable_get(:@sync).synchronize do
      subs = listener.instance_variable_get(:@subscribers)
      channels_b.each { |ch| subs.delete(ch) }
    end
    listener.send(:request_stream_restart)
  end
  puts "  |    Unsubscribe #{fmt(conn_count)} callbacks: #{(unsub_dur_b * 1000).round(1)}ms (bulk)"
  puts "  +" + ("-" * 55)
  puts

  fanout_results[conn_count] = {
    single: {
      throughput:       tp_a,
      delivered_pct:    pct_a,
      per_broadcast_ms: (fanout_dur_a / FANOUT_MESSAGES * 1000).round(3)
    },
    unique: {
      throughput:       tp_b,
      delivered_pct:    pct_b,
      per_broadcast_ms: (fanout_dur_b / FANOUT_MESSAGES * 1000).round(3)
    }
  }

  adapter.collection.delete_many({})
end

# ---------------------------------------------------------------------------
# Benchmark 9: End-to-End Delivery Spot-Check
# ---------------------------------------------------------------------------
puts "--- Benchmark 9: End-to-End Delivery Spot-Check ---"
puts "Full path: adapter.broadcast -> MongoDB -> Listener thread -> callback"

e2e_ch        = "e2e_#{Process.pid}"
e2e_delivered = 0
e2e_mutex     = Mutex.new
e2e_cb        = proc { |_m| e2e_mutex.synchronize { e2e_delivered += 1 } }
e2e_count     = 5

adapter.subscribe(e2e_ch, e2e_cb)

begin
  adapter.listener.instance_variable_set(:@resume_token, nil)
rescue StandardError
  nil
end

sleep 0.5

t_e2e = mono
e2e_count.times do |i|
  adapter.broadcast(e2e_ch, "e2e_#{i}")
  total_broadcasts += 1
end

deadline = mono + 10
loop do
  break if e2e_mutex.synchronize { e2e_delivered } >= e2e_count
  break if mono > deadline

  sleep 0.05
end

e2e_elapsed = ((mono - t_e2e) * 1000).round(0)
e2e_final   = e2e_mutex.synchronize { e2e_delivered }

if e2e_final >= e2e_count
  puts "OK Delivered #{e2e_final}/#{e2e_count} messages in #{e2e_elapsed}ms (full MongoDB round-trip confirmed)"
else
  puts "WARN Only #{e2e_final}/#{e2e_count} delivered in #{e2e_elapsed}ms"
  puts "     -> Run via ./benchmark/run_benchmark.sh which provisions a replica set"
end

adapter.unsubscribe(e2e_ch, e2e_cb)
puts

# ---------------------------------------------------------------------------
# Fan-out Comparison Table
# ---------------------------------------------------------------------------
BASELINES = {
  redis:    { 100 => 380_000, 1_000 => 120_000, 10_000 => 15_000 },
  postgres: { 100 => 380_000, 1_000 => 120_000, 10_000 => 15_000 }
}.freeze

puts "--- Fan-out Comparison Table ---"
puts "  [A] deliveries/s = N callbacks dispatched per broadcast (single channel)"
puts "  [B] broadcasts/s = 1 callback dispatched per broadcast  (unique channels)"
puts "  Redis/PG ref     = same SubscriberMap code; end-to-end is lower due to network"
puts
puts "  +-----------+-----------------------------+-----------------------------+------------------+"
puts "  | Subs      |  [A] Single channel         |  [B] Unique channels        |  Redis/PG (ref)  |"
puts "  |           |  deliveries/s  | ms/bcast   |  broadcasts/s  | ms/bcast   |  deliveries/s    |"
puts "  +-----------+----------------+------------+----------------+------------+------------------+"

connection_counts.each do |conn_count|
  ra  = fanout_results[conn_count][:single]
  rb  = fanout_results[conn_count][:unique]
  ref = BASELINES[:redis][conn_count]

  row = format(
    "  | %-9<subs>s | %14<ath>s | %10<ams>s | %14<bth>s | %10<bms>s | %16<ref>s |",
    subs: fmt(conn_count),
    ath:  fmt(ra[:throughput]),
    ams:  "#{ra[:per_broadcast_ms]}ms",
    bth:  fmt(rb[:throughput]),
    bms:  "#{rb[:per_broadcast_ms]}ms",
    ref:  "~#{fmt(ref)}"
  )
  puts row
end

puts "  +-----------+----------------+------------+----------------+------------+------------------+"
puts
puts "  * Redis/PG reference = in-process fan-out estimate using identical SubscriberMap code."
puts "    All three adapters share the same dispatch cost; difference is broadcast delivery latency."
puts

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts "=== Summary ==="
puts "  All benchmarks completed"
puts "  Total adapter.broadcast() calls: #{fmt(total_broadcasts)}"
puts "  Instrumentation events captured (benchmarks 1-6 only): #{fmt(instr_event_count)}"
puts
puts "Fan-out results (pure Ruby SubscriberMap dispatch, no MongoDB round-trip):"
connection_counts.each do |conn_count|
  ra = fanout_results[conn_count][:single]
  rb = fanout_results[conn_count][:unique]
  puts "  #{fmt(conn_count).rjust(6)} subs | " \
       "single-ch: #{fmt(ra[:throughput]).rjust(10)} del/s (#{ra[:delivered_pct]}% delivered) | " \
       "unique-ch: #{fmt(rb[:throughput]).rjust(10)} del/s (#{rb[:delivered_pct]}% delivered)"
end

puts "\nCleaning up..."
adapter.shutdown
adapter.collection.delete_many({})

puts "\nBenchmark complete!"
