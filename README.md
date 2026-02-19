# SolidCableMongoidAdapter

[![CI](https://github.com/washu/solid_cable_mongoid_adapter/actions/workflows/ci.yml/badge.svg)](https://github.com/washu/solid_cable_mongoid_adapter/actions/workflows/ci.yml)

A production-ready Action Cable subscription adapter that uses MongoDB (via Mongoid) as a durable, cross-process broadcast backend with MongoDB Change Streams support.

## Features

- **Durable Message Storage**: Persists broadcasts in MongoDB with automatic expiration via TTL indexes
- **Real-time Delivery**: Uses MongoDB Change Streams for instant message delivery across processes
- **High Availability**: Automatic reconnection with exponential backoff
- **Resume Token Support**: Continuity across reconnections without message loss
- **Fallback Polling**: Gracefully degrades to polling on standalone MongoDB (not recommended for production)
- **Thread-Safe**: Dedicated listener thread per server process
- **Rails 7+ & 8+ Compatible**: Works with modern Rails applications

## Requirements

- **Ruby**: 2.7 or higher
- **Rails**: 7.0 or higher (supports Rails 8+)
- **MongoDB**: 4.0 or higher
- **Mongoid**: 7.0 or higher
- **MongoDB Replica Set**: Required for Change Streams (even single-node replica sets work)

### Important: MongoDB Replica Set Requirement

This adapter **requires MongoDB to be configured as a replica set** to use Change Streams for real-time message delivery. A single-node replica set is sufficient for development and smaller deployments.

#### Converting Standalone MongoDB to Single-Node Replica Set

```bash
# 1. Stop MongoDB
sudo systemctl stop mongod

# 2. Edit /etc/mongod.conf and add:
replication:
  replSetName: "rs0"

# 3. Start MongoDB
sudo systemctl start mongod

# 4. Connect with mongosh and initialize
mongosh
rs.initiate()
```

For Docker/Docker Compose:

```yaml
version: '3.8'
services:
  mongodb:
    image: mongo:7
    command: --replSet rs0
    ports:
      - "27017:27017"
    healthcheck:
      test: mongosh --eval "rs.status()" || mongosh --eval "rs.initiate()"
      interval: 10s
      timeout: 5s
      retries: 5
```

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'solid_cable_mongoid_adapter'
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```bash
$ gem install solid_cable_mongoid_adapter
```

## Usage

### Configuration

Edit `config/cable.yml`:

```yaml
production:
  adapter: solid_mongoid
  collection_name: "action_cable_messages"   # default
  expiration: 300                             # TTL in seconds, default: 300
  reconnect_delay: 1.0                        # initial retry delay, default: 1.0
  max_reconnect_delay: 60.0                   # max retry delay, default: 60.0
  poll_interval_ms: 500                       # polling fallback interval, default: 500
  poll_batch_limit: 200                       # max messages per poll, default: 200
  require_replica_set: true                   # enforce replica set, default: true

development:
  adapter: solid_mongoid
  collection_name: "action_cable_messages_dev"
  require_replica_set: false                  # can disable for dev if needed

test:
  adapter: test
```

### Mongoid Configuration

Ensure your `config/mongoid.yml` is properly configured:

```yaml
production:
  clients:
    default:
      uri: <%= ENV['MONGODB_URI'] %>
      options:
        max_pool_size: 50
        min_pool_size: 5
        wait_queue_timeout: 5
        connect_timeout: 10
        socket_timeout: 10
        server_selection_timeout: 10
        # Replica set configuration
        replica_set: rs0
        read:
          mode: :primary_preferred
        write:
          w: 1
```

### Environment Variables

```bash
# MongoDB connection
export MONGODB_URI="mongodb://localhost:27017/myapp_production"

# Optional: Override polling settings
export POLL_INTERVAL_MS=500
export POLL_BATCH_LIMIT=200
```

## Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `adapter` | String | - | Must be `solid_mongoid` |
| `collection_name` | String | `action_cable_messages` | MongoDB collection name |
| `expiration` | Integer | `300` | Message TTL in seconds |
| `reconnect_delay` | Float | `1.0` | Initial reconnect delay in seconds |
| `max_reconnect_delay` | Float | `60.0` | Maximum reconnect delay (exponential backoff cap) |
| `poll_interval_ms` | Integer | `500` | Polling interval when Change Streams unavailable |
| `poll_batch_limit` | Integer | `200` | Max messages fetched per poll iteration |
| `require_replica_set` | Boolean | `true` | Enforce replica set requirement |
| `write_concern` | Integer | `1` | MongoDB write concern (0=fire-and-forget, 1=acknowledged, 2+=replicas) |

### Write Concern Configuration

The `write_concern` option controls MongoDB's write acknowledgment behavior:

**write_concern: 1 (Default - Recommended)**
- MongoDB acknowledges writes
- Guarantees message persistence
- Throughput: ~540 msg/sec
- **Use for**: Production, critical messages, reliable delivery

**write_concern: 0 (High-Performance)**
- Fire-and-forget, no acknowledgment
- 4-9x faster throughput (~2000-5000 msg/sec)
- **Trade-off**: Silent failures, potential message loss
- **Use for**: High-volume ephemeral data (chat, presence, typing indicators)

**Example Configuration:**

```yaml
# Conservative (default) - guaranteed delivery
production:
  adapter: solid_mongoid
  write_concern: 1  # Wait for acknowledgment

# High-performance - ephemeral messages
production_high_volume:
  adapter: solid_mongoid
  write_concern: 0  # Fire-and-forget
  # ⚠️ Warning: Message loss possible during failures
```

**Benchmark Comparison:**

| Write Concern | Throughput | Latency | Use Case |
|---------------|------------|---------|----------|
| w=1 (default) | ~540 msg/sec | ~1.8ms | Critical messages, guaranteed delivery |
| w=0 (fast) | ~2000+ msg/sec | ~0.3ms | Chat, presence, ephemeral updates |

See [Benchmark 7](#benchmarks) for detailed performance comparison.

## Performance

### Benchmarks

Run the included benchmark suite to measure performance on your system:

**With Docker (Recommended):**
```bash
# Automatically starts MongoDB replica set, runs benchmarks, and cleans up
./benchmark/run_benchmark.sh
```

**Manual (requires MongoDB replica set on localhost:27017):**
```bash
bundle exec ruby benchmark/benchmark.rb
```

**Typical Results** (M1 Mac, MongoDB 7.0, local replica set):

| Metric | Value |
|--------|-------|
| Broadcast latency (100B) | ~1-2ms avg, <3ms p95 |
| Broadcast latency (1KB) | ~2ms avg, <4ms p95 |
| Broadcast latency (10KB) | ~2-3ms avg, <4ms p95 |
| Broadcast latency (100KB) | ~4-5ms avg, <6ms p95 |
| Throughput (10k messages) | 500-600 messages/sec |
| Throughput (100k messages) | 400-500 messages/sec (optional test) |
| Subscribe/Unsubscribe | <1ms |
| Instrumentation overhead | ~2ms per event |

**High-Volume Test:**
```bash
# Run with 100k messages (takes 2-5 minutes)
BENCHMARK_HIGH_VOLUME=true ./benchmark/run_benchmark.sh
```

**Channel Filtering Impact:**

| Scenario | Without Filtering | With Filtering | Improvement |
|----------|------------------|----------------|-------------|
| 100 channels, subscribe to 10 | 100% traffic | 10% traffic | 90% reduction |
| 1000 channels, subscribe to 50 | 100% traffic | 5% traffic | 95% reduction |

### Monitoring with ActiveSupport::Notifications

The adapter emits instrumentation events that you can subscribe to:

```ruby
# config/initializers/cable_monitoring.rb
ActiveSupport::Notifications.subscribe("broadcast.solid_cable_mongoid") do |name, start, finish, id, payload|
  duration = (finish - start) * 1000
  Rails.logger.info "Broadcast to #{payload[:channel]}: #{duration.round(2)}ms (#{payload[:size]} bytes)"

  # Send to your metrics system
  StatsD.histogram("cable.broadcast.duration", duration, tags: ["channel:#{payload[:channel]}"])
end

ActiveSupport::Notifications.subscribe("message_received.solid_cable_mongoid") do |name, start, finish, id, payload|
  duration = (finish - start) * 1000
  Rails.logger.info "Message received on #{payload[:channel]}: #{duration.round(2)}ms, " \
                    "#{payload[:subscriber_count]} subscribers"
end

ActiveSupport::Notifications.subscribe("subscribe.solid_cable_mongoid") do |_name, _start, _finish, _id, payload|
  Rails.logger.info "Subscribed to #{payload[:channel]} (#{payload[:total_channels]} total channels)"
  StatsD.increment("cable.subscriptions", tags: ["channel:#{payload[:channel]}"])
end

ActiveSupport::Notifications.subscribe("broadcast_error.solid_cable_mongoid") do |_name, _start, _finish, _id, payload|
  Rails.logger.error "Broadcast error on #{payload[:channel]}: #{payload[:error]}"
  StatsD.increment("cable.errors", tags: ["type:broadcast", "error:#{payload[:error]}"])
end
```

**Available Events:**

- `broadcast.solid_cable_mongoid` - Message broadcast (payload: `channel`, `size`)
- `message_received.solid_cable_mongoid` - Message delivered to subscribers (payload: `channel`, `subscriber_count`)
- `subscribe.solid_cable_mongoid` - Channel subscription (payload: `channel`, `total_channels`)
- `unsubscribe.solid_cable_mongoid` - Channel unsubscription (payload: `channel`, `total_channels`)
- `broadcast_error.solid_cable_mongoid` - Broadcast failure (payload: `channel`, `error`)
- `message_error.solid_cable_mongoid` - Message delivery failure (payload: `channel`, `error`)

## Production Deployment

### Best Practices

1. **Use a Replica Set**: Always use a replica set, even if it's a single node, to enable Change Streams
2. **Connection Pooling**: Configure appropriate pool sizes in `mongoid.yml`
3. **Monitoring**: Monitor the `action_cable_messages` collection size and TTL index
4. **Read Preference**: Use `:primary_preferred` for read operations
5. **Write Concern**: Use `w: 1` for acceptable durability with good performance

### MongoDB Atlas

```yaml
production:
  clients:
    default:
      uri: <%= ENV['MONGODB_ATLAS_URI'] %>
      options:
        max_pool_size: 100
        retry_writes: true
        retry_reads: true
```

### Kubernetes/Docker

```yaml
# docker-compose.yml
version: '3.8'
services:
  app:
    environment:
      MONGODB_URI: mongodb://mongodb:27017/myapp_production
    depends_on:
      mongodb:
        condition: service_healthy

  mongodb:
    image: mongo:7
    command: --replSet rs0
    healthcheck:
      test: mongosh --eval "rs.status()" || mongosh --eval "rs.initiate()"
      interval: 10s
      timeout: 5s
      retries: 5
```

## How It Works

### Architecture

1. **Broadcast Phase**: When a message is broadcast to a channel:
   - Document inserted into MongoDB collection
   - TTL index schedules automatic cleanup
   - All server processes are notified via Change Streams

2. **Listening Phase**: Each server process:
   - Maintains a Change Stream watching for inserts
   - Receives new documents in real-time
   - Dispatches to local Action Cable subscribers
   - Maintains resume token for continuity

3. **Fallback Mode**: If Change Streams unavailable:
   - Falls back to polling every `poll_interval_ms`
   - Maintains `@last_seen_id` to avoid replays
   - Periodically checks if Change Streams become available

### Thread Safety

- One listener thread per Action Cable server process
- Callbacks posted to Action Cable event loop
- No shared state between processes
- Safe for Puma cluster mode, Passenger, and other forking servers

### Resilience

- Automatic reconnection with exponential backoff
- Resume tokens prevent message loss across reconnects
- Graceful degradation to polling if needed
- Comprehensive error logging

## Troubleshooting

### "MongoDB replica set is required" Error

**Problem**: Getting `SolidCableMongoidAdapter::ReplicaSetRequiredError`

**Solution**: Convert your MongoDB to a replica set (see Requirements section) or set `require_replica_set: false` in cable.yml (not recommended for production)

### Messages Not Being Delivered

**Checklist**:
1. Verify MongoDB replica set is configured: `rs.status()` in mongosh
2. Check Action Cable is mounted: `config/routes.rb` should have `mount ActionCable.server => '/cable'`
3. Verify collection exists: `db.action_cable_messages.find().limit(1)`
4. Check logs for connection errors
5. Ensure WebSocket connection is established in browser

### High Memory Usage

**Solutions**:
1. Reduce `expiration` time in cable.yml
2. Increase `poll_batch_limit` if using polling
3. Monitor collection size: `db.action_cable_messages.stats()`
4. Verify TTL index is working: `db.action_cable_messages.getIndexes()`

### Connection Pool Exhaustion

**Solutions**:
1. Increase `max_pool_size` in mongoid.yml
2. Reduce number of Action Cable connections per process
3. Use connection pooling monitoring

## Development

After checking out the repo, run:

```bash
bundle install
bundle exec rake spec
bundle exec rubocop
```

To install this gem onto your local machine:

```bash
bundle exec rake install
```

## Testing

```bash
# Run all tests
bundle exec rspec

# Run with coverage
COVERAGE=true bundle exec rspec

# Run specific test
bundle exec rspec spec/adapter_spec.rb
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/washu/solid_cable_mongoid_adapter.

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Credits

Created and maintained by [Sal Scotto]

Based on the solid_cable pattern and adapted for MongoDB with production-grade features.
