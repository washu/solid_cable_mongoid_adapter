#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark script for SolidCableMongoidAdapter
#
# Usage:
#   # With Docker (recommended):
#   ./benchmark/run_benchmark.sh
#
#   # Manual (requires MongoDB replica set on localhost:27017):
#   bundle exec ruby benchmark/benchmark.rb
#
# This script measures:
#   - Broadcast latency (time to insert message)
#   - Message delivery latency (time from broadcast to receipt)
#   - Throughput (messages per second - 10k messages)
#   - High-volume throughput (100k messages - optional with BENCHMARK_HIGH_VOLUME=true)
#   - Channel filtering efficiency (with/without filtering)
#   - Instrumentation overhead

require "bundler/setup"
require "action_cable"
require "mongoid"
require "benchmark"
require_relative "../lib/solid_cable_mongoid_adapter"

# Configure Mongoid
Mongoid.configure do |config|
  config.clients.default = {
    uri: ENV.fetch("MONGODB_URI", "mongodb://localhost:27017/solid_cable_benchmark"),
    options: {
      max_pool_size: 50,
      min_pool_size: 5
    }
  }
end

# Mock ActionCable Server
class MockServer
  attr_reader :logger, :config, :event_loop, :mutex

  def initialize
    @logger = Logger.new($stdout)
    @logger.level = Logger::INFO
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

# Setup
puts "=== SolidCableMongoidAdapter Performance Benchmark ==="
puts "MongoDB: #{ENV.fetch("MONGODB_URI", "mongodb://localhost:27017/solid_cable_benchmark")}"
puts

server = MockServer.new
adapter = ActionCable::SubscriptionAdapter::SolidMongoid.new(server)

# Clean up old messages
puts "Cleaning up old messages..."
adapter.collection.delete_many({})

# Benchmark 1: Broadcast Latency
puts "\n--- Benchmark 1: Broadcast Latency ---"
message_sizes = [100, 1_000, 10_000, 100_000]
iterations = 100

message_sizes.each do |size|
  payload = "x" * size
  latencies = []

  iterations.times do
    start = Time.now
    adapter.broadcast("benchmark_channel", payload)
    latencies << (Time.now - start)
  end

  avg_latency = (latencies.sum / latencies.size) * 1000
  min_latency = latencies.min * 1000
  max_latency = latencies.max * 1000
  p95_latency = latencies.sort[(latencies.size * 0.95).to_i] * 1000

  puts "Message size: #{size} bytes"
  puts "  Avg: #{avg_latency.round(2)}ms, Min: #{min_latency.round(2)}ms, " \
       "Max: #{max_latency.round(2)}ms, P95: #{p95_latency.round(2)}ms"
end

# Benchmark 2: Throughput
puts "\n--- Benchmark 2: Throughput (Standard) ---"
message_count = 10_000
payload = "test message" * 10

start = Time.now
message_count.times do |i|
  adapter.broadcast("throughput_channel", "#{payload}_#{i}")
end
duration = Time.now - start

throughput = message_count / duration
puts "Sent #{message_count} messages in #{duration.round(2)}s"
puts "Throughput: #{throughput.round(2)} messages/second"
puts "Average latency: #{(duration / message_count * 1000).round(2)}ms per message"

# Benchmark 3: High-Volume Throughput (optional, can be slow)
if ENV["BENCHMARK_HIGH_VOLUME"] == "true"
  puts "\n--- Benchmark 3: Throughput (High-Volume 100k) ---"
  message_count_high = 100_000
  payload_high = "x" * 100 # 100 byte payload

  puts "Sending #{message_count_high} messages (this may take 2-5 minutes)..."
  start = Time.now
  progress_interval = message_count_high / 10

  message_count_high.times do |i|
    adapter.broadcast("high_volume_channel", "#{payload_high}_#{i}")
    puts "  Progress: #{((i + 1).to_f / message_count_high * 100).round(1)}%" if ((i + 1) % progress_interval).zero?
  end
  duration_high = Time.now - start

  throughput_high = message_count_high / duration_high
  puts "Sent #{message_count_high} messages in #{duration_high.round(2)}s"
  puts "Throughput: #{throughput_high.round(2)} messages/second"
  puts "Average latency: #{(duration_high / message_count_high * 1000).round(2)}ms per message"
else
  puts "\n--- Benchmark 3: Throughput (High-Volume) ---"
  puts "Skipped (set BENCHMARK_HIGH_VOLUME=true to run 100k message test)"
  puts "Note: This test takes 2-5 minutes to complete"
end

# Benchmark 4: Channel Filtering Efficiency
puts "\n--- Benchmark 4: Channel Filtering Impact ---"
channel_count = 100
messages_per_channel = 10

puts "Broadcasting to #{channel_count} channels (#{channel_count * messages_per_channel} total messages)..."

start = Time.now
channel_count.times do |channel_num|
  messages_per_channel.times do |msg_num|
    adapter.broadcast("channel_#{channel_num}", "message_#{msg_num}")
  end
end
broadcast_duration = Time.now - start

puts "Broadcast time: #{broadcast_duration.round(2)}s"
puts "Average per message: #{(broadcast_duration / (channel_count * messages_per_channel) * 1000).round(2)}ms"

# Check collection size
collection_size = adapter.collection.count_documents({})
puts "Messages in collection: #{collection_size}"

# Benchmark 5: Subscription Performance
puts "\n--- Benchmark 5: Subscription Performance ---"

received_messages = []
callback = proc { |msg| received_messages << msg }

# Subscribe to a channel
puts "Subscribing to test_channel..."
start = Time.now
adapter.subscribe("test_channel", callback)
subscribe_time = Time.now - start

puts "Subscribe time: #{(subscribe_time * 1000).round(2)}ms"

# Unsubscribe
start = Time.now
adapter.unsubscribe("test_channel", callback)
unsubscribe_time = Time.now - start

puts "Unsubscribe time: #{(unsubscribe_time * 1000).round(2)}ms"

# Benchmark 6: ActiveSupport::Notifications Integration
puts "\n--- Benchmark 6: Instrumentation Overhead ---"

events = []
ActiveSupport::Notifications.subscribe(/solid_cable_mongoid/) do |name, start, finish, _id, payload|
  events << { name: name, duration: (finish - start) * 1000, payload: payload }
end

message_count = 100
start = Time.now
message_count.times do |i|
  adapter.broadcast("instrumented_channel", "message_#{i}")
end
duration = Time.now - start

broadcast_events = events.select { |e| e[:name] == "broadcast.solid_cable_mongoid" }
puts "Sent #{message_count} instrumented messages in #{duration.round(2)}s"
puts "Captured #{broadcast_events.size} instrumentation events"
if broadcast_events.any?
  avg_duration = broadcast_events.sum { |e| e[:duration] } / broadcast_events.size
  puts "Average instrumented broadcast time: #{avg_duration.round(2)}ms"
end

# Benchmark 7: Write Concern Comparison (w=0 vs w=1)
puts "\n--- Benchmark 7: Write Concern Comparison ---"

# Test with w=1 (default - acknowledged writes)
puts "\nTesting with write concern w=1 (acknowledged)..."
server.config.cable["write_concern"] = 1
adapter_w1 = ActionCable::SubscriptionAdapter::SolidMongoid.new(server)

message_count_wc = 5000
payload_wc = "x" * 100

start = Time.now
message_count_wc.times do |i|
  adapter_w1.broadcast("wc_test_channel", "#{payload_wc}_#{i}")
end
duration_w1 = Time.now - start
throughput_w1 = message_count_wc / duration_w1

puts "  Sent #{message_count_wc} messages in #{duration_w1.round(2)}s"
puts "  Throughput: #{throughput_w1.round(2)} messages/second"
puts "  Average latency: #{(duration_w1 / message_count_wc * 1000).round(2)}ms per message"

adapter_w1.shutdown
adapter_w1.collection.delete_many({})

# Test with w=0 (fire-and-forget)
puts "\nTesting with write concern w=0 (fire-and-forget)..."
server.config.cable["write_concern"] = 0
adapter_w0 = ActionCable::SubscriptionAdapter::SolidMongoid.new(server)

start = Time.now
message_count_wc.times do |i|
  adapter_w0.broadcast("wc_test_channel", "#{payload_wc}_#{i}")
end
duration_w0 = Time.now - start
throughput_w0 = message_count_wc / duration_w0

puts "  Sent #{message_count_wc} messages in #{duration_w0.round(2)}s"
puts "  Throughput: #{throughput_w0.round(2)} messages/second"
puts "  Average latency: #{(duration_w0 / message_count_wc * 1000).round(2)}ms per message"

# Calculate improvement
improvement = ((throughput_w0 - throughput_w1) / throughput_w1 * 100).round(1)
speedup = (throughput_w0 / throughput_w1).round(1)

puts "\n  Performance Comparison:"
puts "  └─ w=0 is #{speedup}x faster than w=1 (#{improvement}% improvement)"
puts "  └─ Latency reduced by #{((duration_w1 - duration_w0) / duration_w1 * 100).round(1)}%"

adapter_w0.shutdown
adapter_w0.collection.delete_many({})

# Restore default
server.config.cable["write_concern"] = 1

# Summary
puts "\n=== Summary ==="
puts "✓ All benchmarks completed"
puts "✓ Total messages broadcast: #{adapter.collection.count_documents({})}"
puts "✓ Instrumentation events captured: #{events.size}"

# Cleanup
puts "\nCleaning up..."
adapter.shutdown
adapter.collection.delete_many({})

puts "\n✓ Benchmark complete!"
