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

### Planned
- Performance metrics and monitoring hooks
- Support for multiple MongoDB databases
- Message compression options
- Custom serialization support
