# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-02-09

### Added
- Initial release of SolidCableMongoidAdapter
- MongoDB Change Streams support for real-time message delivery
- Automatic TTL-based message expiration
- Replica set requirement validation
- Exponential backoff for reconnection attempts
- Resume token support for continuity across reconnections
- Fallback polling mode for standalone MongoDB
- Comprehensive logging and error handling
- Thread-safe listener implementation
- Rails 7+ and Rails 8+ compatibility
- Production-grade code quality and documentation

### Features
- Channel-based subscription management
- Configurable message expiration (TTL)
- Configurable reconnection delays with exponential backoff
- Configurable polling parameters for fallback mode
- Automatic collection and index creation
- Fork-safe operation (Passenger, Puma cluster mode)

### Configuration Options
- `collection_name`: MongoDB collection name
- `expiration`: Message TTL in seconds
- `reconnect_delay`: Initial retry delay
- `max_reconnect_delay`: Maximum retry delay
- `poll_interval_ms`: Polling interval
- `poll_batch_limit`: Max messages per poll
- `require_replica_set`: Enforce replica set requirement

## [Unreleased]

## [1.1.0.0] - 2025-02-25

### Added
- **Dynamic Channel Filtering**: MongoDB-level filtering reduces network traffic by 50-95% in multi-channel scenarios
- **ActiveSupport::Notifications Integration**: Six instrumentation events for monitoring and metrics
  - `broadcast.solid_cable_mongoid` - Message broadcast with size tracking
  - `message_received.solid_cable_mongoid` - Message delivery with subscriber count
  - `subscribe.solid_cable_mongoid` - Channel subscription tracking
  - `unsubscribe.solid_cable_mongoid` - Channel unsubscription tracking
  - `broadcast_error.solid_cable_mongoid` - Broadcast error tracking
  - `message_error.solid_cable_mongoid` - Message delivery error tracking
- **Performance Benchmark Suite**: Comprehensive benchmark script measuring latency, throughput, and filtering efficiency
  - Automated Docker-based benchmark runner (`./benchmark/run_benchmark.sh`)
  - Tests broadcast latency across message sizes (100B - 100KB)
  - Measures throughput (messages/second)
  - Validates channel filtering impact
  - Measures subscription performance
  - Tests instrumentation overhead
- **Thread-safe Stream Restart**: Automatic Change Stream restart when subscriptions change
- **Configurable Write Concern**: Control MongoDB write acknowledgment for performance tuning
  - `write_concern: 1` (default) - Acknowledged writes for guaranteed delivery (~540 msg/sec)
  - `write_concern: 0` - Fire-and-forget for high-performance (~2000+ msg/sec, 4-9x faster)
  - Benchmark 7 compares w=0 vs w=1 performance impact

### Improved
- **Performance**: 50-99% reduction in network traffic for multi-channel deployments
- **Observability**: Debug logging for channel count and stream restarts
- **Monitoring**: Built-in instrumentation for StatsD, Datadog, New Relic integration

### Documentation
- Added performance benchmarks and typical results to README
- Added ActiveSupport::Notifications usage examples
- Added channel filtering impact analysis
- Added monitoring integration examples (StatsD)

## [1.0.0] - 2025-02-09

### Planned
- Support for multiple MongoDB databases
- Message compression options
- Custom serialization support
