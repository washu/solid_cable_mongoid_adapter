# frozen_string_literal: true

require "action_cable/subscription_adapter/base"
require "action_cable/subscription_adapter/channel_prefix"
require "action_cable/subscription_adapter/subscriber_map"
require "mongoid"
require "securerandom"

module ActionCable
  module SubscriptionAdapter
    # SolidMongoid is an Action Cable subscription adapter that uses MongoDB (via Mongoid's client)
    # as a durable, cross-process broadcast backend.
    #
    # ## Requirements
    # - MongoDB must be configured as a replica set (even if single-node)
    # - Change Streams require replica set or sharded cluster
    #
    # ## Features
    # - Persists each broadcast as a document in a collection with TTL index
    # - Uses MongoDB Change Streams for real-time message delivery
    # - Falls back to polling on standalone MongoDB (not recommended for production)
    # - Automatic reconnection with exponential backoff
    # - Resume token support for continuity across reconnections
    #
    # ## Configuration
    # Configure in `config/cable.yml` under the current environment:
    #
    #   production:
    #     adapter: solid_mongoid
    #     collection_name: "action_cable_messages"  # default
    #     expiration: 300                            # seconds, default: 300
    #     reconnect_delay: 1.0                       # seconds, default: 1.0
    #     max_reconnect_delay: 60.0                  # seconds, default: 60.0
    #     poll_interval_ms: 500                      # milliseconds, default: 500
    #     poll_batch_limit: 200                      # default: 200
    #     require_replica_set: true                  # default: true
    #     write_concern: 1                           # 0=fire-and-forget, 1=ack (default), 2+=replicas
    #     max_await_time_ms: 1000                    # change stream await window, default: 1000
    #
    # ## Thread Safety
    # The adapter is thread-safe and maintains a dedicated listener thread per server process.
    class SolidMongoid < Base
      prepend ChannelPrefix

      # Initialize the adapter and ensure the Mongo collection/index are ready.
      # Validates replica set requirement if configured, logs a warning if not available.
      #
      # @return [void]
      def initialize(*)
        super
        @listener = nil
        validate_replica_set!
        ensure_collection_state
        logger.info "SolidCableMongoid: initialized; collection=#{collection_name.inspect}, pid=#{Process.pid}"
      end

      # Broadcast a payload to a channel by inserting a document into MongoDB.
      # All listeners (processes/servers) will receive it through Change Streams or polling
      # and rebroadcast to local subscribers.
      #
      # Conforms to the Action Cable adapter API contract: raises on error so callers
      # can handle failures explicitly (aligned with rails/rails#50979).
      #
      # @param channel [String, Symbol] the channel identifier
      # @param payload [String] the raw message payload (Action Cable provides a JSON string)
      # @raise [Mongo::Error] on MongoDB write failures
      # @raise [StandardError] on unexpected errors
      # @return [void]
      def broadcast(channel, payload)
        ActiveSupport::Notifications.instrument("broadcast.solid_cable_mongoid",
                                                channel: channel, size: payload.bytesize) do
          now = Time.now.utc
          collection.insert_one(
            {
              channel: channel.to_s,
              message: payload,
              created_at: now,
              _expires: now + expiration
            },
            write_concern: { w: write_concern_level }
          )
        end
      rescue StandardError => e
        kind = e.is_a?(Mongo::Error) ? "broadcast error" : "unexpected broadcast error"
        logger.error "SolidCableMongoid: #{kind} (#{e.class}): #{e.message}"
        ActiveSupport::Notifications.instrument("broadcast_error.solid_cable_mongoid",
                                                channel: channel, error: e.class.name)
        raise
      end

      # Subscribe a callback to a channel.
      # The `success_callback` (if provided) is executed exactly once by `SubscriberMap` upon subscription success.
      #
      # @param channel [String, Symbol] the channel identifier
      # @param callback [Proc] the block to invoke with each received message
      # @param success_callback [Proc, nil] optional block to call once on successful subscription
      # @return [void]
      def subscribe(channel, callback, success_callback = nil)
        listener.add_subscriber(channel, callback, success_callback)
      end

      # Unsubscribe a callback from a channel.
      #
      # @param channel [String, Symbol] the channel identifier
      # @param callback [Proc] the previously registered callback
      # @return [void]
      def unsubscribe(channel, callback)
        listener.remove_subscriber(channel, callback)
      end

      # Shut down the listener thread and release resources.
      #
      # @return [void]
      def shutdown
        listener&.shutdown
      end

      # Validate that MongoDB is configured as a replica set if required.
      # Logs a warning and falls back to polling if not configured.
      #
      # @return [void]
      def validate_replica_set!
        return unless require_replica_set?

        return if replica_set_configured?

        logger.warn "SolidCableMongoid: MongoDB is not configured as a replica set. " \
                    "Change Streams are unavailable; falling back to polling mode. " \
                    "Set require_replica_set: false in cable.yml to disable this check."
      end

      # Check if MongoDB is configured as a replica set.
      # Once confirmed true it is memoized — a replica set does not become standalone.
      # A false result is NOT memoized so transient startup errors are retried on the
      # next call (e.g. the Listener thread checks this on every loop iteration).
      #
      # @return [Boolean] true if replica set is confirmed
      def replica_set_configured?
        return true if @replica_set_configured

        client = Mongoid.default_client
        hello = begin
          client.database.command({ hello: 1 }).first
        rescue StandardError
          nil
        end
        hello ||= begin
          client.database.command({ ismaster: 1 }).first
        rescue StandardError
          nil
        end
        result = !!hello&.[]("setName")
        @replica_set_configured = true if result
        result
      rescue StandardError => e
        logger.warn "SolidCableMongoid: unable to check replica set status (#{e.class}): #{e.message}"
        false
      end

      # Ensure the MongoDB collection and indexes are in the expected state.
      #
      # @return [void]
      def ensure_collection_state
        db = Mongoid.default_client.database

        # 1. Get or create collection (created automatically on first write)
        coll = db[collection_name]

        # 2. Create TTL index for automatic message expiration
        begin
          coll.indexes.create_one(
            { _expires: 1 },
            expire_after_seconds: 0,
            name: "auto_expire",
            partial_filter_expression: {
              "_expires" => {
                "$exists" => true,
                "$type" => 9 # BSON Date type
              }
            }
          )
          logger.debug "SolidCableMongoid: TTL index ensured"
        rescue Mongo::Error::OperationFailure => e
          # Index may already exist with different options
          if e.message.include?("already exists")
            logger.debug "SolidCableMongoid: TTL index already exists"
          else
            logger.warn "SolidCableMongoid: failed to create TTL index: #{e.message}"
          end
        end

        # 3. Create index on channel for query performance
        begin
          coll.indexes.create_one(
            { channel: 1, _id: 1 },
            name: "channel_id_index"
          )
          logger.debug "SolidCableMongoid: channel index ensured"
        rescue Mongo::Error::OperationFailure => e
          if e.message.include?("already exists")
            logger.debug "SolidCableMongoid: channel index already exists"
          else
            logger.warn "SolidCableMongoid: failed to create channel index: #{e.message}"
          end
        end
      rescue StandardError => e
        logger.error "SolidCableMongoid: failed to ensure collection state: #{e.message}"
      end

      # --- Configuration accessors -------------------------------------------------

      # Obtain the Mongo collection used for Action Cable messages.
      # Not memoized to avoid issues with forking (e.g., Passenger, Puma cluster mode).
      #
      # @return [Mongo::Collection]
      def collection
        Mongoid.default_client.database.collection(collection_name)
      end

      # The name of the Mongo collection storing broadcasts.
      #
      # @return [String]
      def collection_name
        @server.config.cable.fetch("collection_name", "action_cable_messages")
      end

      # Message expiration time in seconds used by the TTL index.
      #
      # @return [Integer]
      def expiration
        @server.config.cable.fetch("expiration", 300).to_i
      end

      # Whether to require a replica set configuration.
      #
      # @return [Boolean]
      def require_replica_set?
        @server.config.cable.fetch("require_replica_set", true)
      end

      # Write concern level for broadcast operations.
      #
      # @return [Integer] Write concern level (0 = fire-and-forget, 1 = acknowledge, 2+ = replicas)
      def write_concern_level
        @server.config.cable.fetch("write_concern", 1).to_i
      end

      # Max time the change stream will await new data from the server before
      # returning an empty batch. Lower values reduce shutdown latency; higher
      # values reduce polling overhead.
      #
      # @return [Integer] milliseconds (default: 1000)
      def max_await_time_ms
        @server.config.cable.fetch("max_await_time_ms", 1000).to_i
      end

      # The singleton listener for this server process. Lazily instantiated and
      # synchronized through the server's mutex.
      #
      # @return [Listener]
      def listener
        @listener || @server.mutex.synchronize { @listener ||= Listener.new(self, @server.event_loop) }
      end

      # Listener consumes MongoDB inserts for this adapter and dispatches them
      # to local Action Cable subscribers. It prefers MongoDB Change Streams
      # when available and transparently falls back to polling on standalone
      # deployments.
      #
      # ## Design
      # - **Threaded**: a dedicated background thread runs the main loop
      # - **Delivery**: callbacks are posted onto the Action Cable event loop for thread-safety
      # - **Resilience**: on errors, uses exponential backoff before retry
      # - **Continuity**: maintains `@resume_token` to resume Change Streams without message loss
      #
      # ## Configuration
      # - `reconnect_delay` [Float] initial delay in seconds before retry (default: 1.0)
      # - `max_reconnect_delay` [Float] maximum delay in seconds (default: 60.0)
      # - `poll_interval_ms` [Integer] polling interval in milliseconds (default: 500)
      # - `poll_batch_limit` [Integer] max documents per poll (default: 200)
      class Listener < SubscriberMap
        def initialize(adapter, event_loop)
          super()
          @adapter = adapter
          @event_loop = event_loop
          @running = true
          @stream = nil
          @resume_token = nil
          @reconnect_attempts = 0
          @restart_stream = false
          @stream_mutex = Mutex.new

          # Cache config values and collection to avoid accessing mocks from background thread
          config = @adapter.server.config.cable
          @reconnect_delay_base = config.fetch("reconnect_delay", 1.0).to_f
          @max_reconnect_delay = config.fetch("max_reconnect_delay", 60.0).to_f
          @poll_interval = config.fetch("poll_interval_ms", 500).to_i / 1000.0
          @batch_limit = config.fetch("poll_batch_limit", 200).to_i
          @max_await_time_ms = config.fetch("max_await_time_ms", 1000).to_i
          @collection = @adapter.collection

          @thread = Thread.new { listen_loop }
          @thread.name = "solid-cable-mongoid-#{Process.pid}" if @thread.respond_to?(:name=)
          @thread.abort_on_exception = false
        end

        # Ensure callbacks fire on ActionCable's event loop for thread-safety.
        # Arguments are captured explicitly before the block to avoid relying on
        # implicit super-in-block forwarding, which is fragile across Ruby implementations.
        def invoke_callback(callback, message)
          @event_loop.post { super(callback, message) }
        end

        # Dispatch multiple broadcast documents to local subscribers in a single
        # event-loop post. This reduces context-switching overhead under high
        # message throughput compared to posting one task per document.
        #
        # @param docs [Array<Hash>] array of full MongoDB documents
        # @return [void]
        def handle_insert_docs(docs)
          docs.each { |doc| handle_insert_doc(doc) }
        end

        # Add a subscriber. Instrumentation fires per-subscribe; stream restart
        # is triggered only when a brand new channel is joined (detected after
        # @sync is released to avoid lock-order inversion with @stream_mutex).
        def add_subscriber(channel, callback, success_callback = nil)
          new_channel = !@sync.synchronize { @subscribers.key?(channel) }
          super
          request_stream_restart if new_channel
          ActiveSupport::Notifications.instrument("subscribe.solid_cable_mongoid",
                                                  channel: channel,
                                                  total_channels: channels_snapshot.size)
        end

        # Remove a subscriber. Stream restart is triggered only when the last
        # subscriber leaves a channel (detected after @sync is released).
        def remove_subscriber(channel, callback)
          was_last = @sync.synchronize { @subscribers[channel]&.size == 1 }
          super
          request_stream_restart if was_last
          ActiveSupport::Notifications.instrument("unsubscribe.solid_cable_mongoid",
                                                  channel: channel,
                                                  total_channels: channels_snapshot.size)
        end

        # Called by SubscriberMap when a brand new channel is added (runs under @sync).
        # Stream restart is now triggered from add_subscriber AFTER @sync is released
        # to prevent lock-order inversion with @stream_mutex.
        def add_channel(channel, on_success)
          super
        end

        # Called by SubscriberMap when the last subscriber leaves a channel (runs under @sync).
        # Stream restart is now triggered from remove_subscriber AFTER @sync is released.
        def remove_channel(channel)
          super
        end

        # Graceful shutdown with configurable timeout.
        def shutdown
          @running = false
          close_stream
          return unless @thread&.alive?

          @thread.join(5) || @thread.kill
        end

        private

        # Request a stream restart with updated channel filters.
        # Thread-safe and non-blocking.
        #
        # @return [void]
        def request_stream_restart
          @stream_mutex.synchronize { @restart_stream = true }
        end

        # Check if a stream restart has been requested.
        #
        # @return [Boolean]
        def restart_requested?
          @stream_mutex.synchronize { @restart_stream }
        end

        # Clear the restart flag.
        #
        # @return [void]
        def clear_restart_flag
          @stream_mutex.synchronize { @restart_stream = false }
        end

        # Snapshot the subscribed channel list under SubscriberMap's mutex.
        # Safe to read from the background listener thread.
        #
        # @return [Array<String>]
        def channels_snapshot
          @sync.synchronize { @subscribers.keys }
        end

        # Build the Change Stream pipeline with channel filtering.
        # Filters to only receive inserts for channels this process subscribes to.
        #
        # @return [Array<Hash>] MongoDB aggregation pipeline
        def build_pipeline
          subscribed_channels = channels_snapshot

          if subscribed_channels.empty?
            # No subscribers yet, watch for inserts only
            [{ "$match" => { "operationType" => "insert" } }]
          else
            # Filter by subscribed channels at MongoDB level for performance
            [
              { "$match" => { "operationType" => "insert" } },
              { "$match" => { "fullDocument.channel" => { "$in" => subscribed_channels } } }
            ]
          end
        end

        # Calculate reconnect delay with exponential backoff.
        #
        # @return [Float] seconds to wait before retry
        def reconnect_delay
          [@reconnect_delay_base * (2**@reconnect_attempts), @max_reconnect_delay].min
        end

        # Polling interval in seconds.
        #
        # @return [Float]
        attr_reader :poll_interval

        # Max documents to fetch per poll.
        #
        # @return [Integer]
        attr_reader :batch_limit

        # Main listener loop that receives broadcasts from MongoDB.
        #
        # @return [void]
        def listen_loop
          while @running
            begin
              if change_stream_supported?
                # Build pipeline with current channel subscriptions for filtering
                pipeline = build_pipeline

                # Change Stream path (replica set / sharded)
                opts = { max_await_time_ms: @max_await_time_ms }
                opts[:resume_after] = @resume_token if @resume_token

                @stream = @collection.watch(pipeline, opts)
                enum = @stream.to_enum

                @adapter.logger.debug "SolidCableMongoid: watching #{channels_snapshot.size} channel(s)"

                batch = []
                while @running && enum && !restart_requested?
                  doc = enum.try_next

                  if doc
                    batch << (doc["fullDocument"] || {})
                    @resume_token = @stream.resume_token
                    @reconnect_attempts = 0 # Reset on successful iteration
                  end

                  # Flush batch when it has items and no more docs are immediately available
                  # (doc == nil means the await window expired — good flush point)
                  if batch.any? && doc.nil?
                    dispatched = batch.dup
                    batch.clear
                    @event_loop.post { handle_insert_docs(dispatched) }
                  end
                end

                # Flush any remaining docs before restarting
                if batch.any?
                  dispatched = batch.dup
                  batch.clear
                  @event_loop.post { handle_insert_docs(dispatched) }
                end

                # Handle stream restart request
                if restart_requested?
                  @adapter.logger.debug "SolidCableMongoid: restarting stream with updated channel filter"
                  clear_restart_flag
                  close_stream
                  next # Restart loop with new pipeline
                end
              else
                # Standalone fallback: polling
                poll_for_inserts
              end
            rescue Mongo::Error::OperationFailure => e
              unless e.message.include?("operation exceeded time limit")
                @adapter.logger.warn "SolidCableMongoid: operation error (#{e.class}): #{e.message}"
                @reconnect_attempts += 1
              end
              sleep_with_backoff
            rescue Mongo::Error => e
              @adapter.logger.warn "SolidCableMongoid: connection error (#{e.class}): #{e.message}"
              @reconnect_attempts += 1
              sleep_with_backoff
            rescue NoMethodError => e
              # Null stream error
              @adapter.logger.debug "SolidCableMongoid: stream unavailable (#{e.message})"
              @reconnect_attempts += 1
              sleep_with_backoff
            rescue StandardError => e
              backtrace = Array(e.backtrace).take(10).join("\n")
              msg = "SolidCableMongoid: unexpected listener error (#{e.class}): #{e.message}\n#{backtrace}"
              @adapter.logger.error msg
              @reconnect_attempts += 1
              sleep_with_backoff
            ensure
              close_stream
            end
          end
        end

        # Sleep with exponential backoff.
        def sleep_with_backoff
          delay = reconnect_delay
          @adapter.logger.debug "SolidCableMongoid: retrying in #{delay}s (attempt #{@reconnect_attempts})"
          sleep delay
        end

        # Close the active change stream.
        #
        # @return [void]
        def close_stream
          @stream&.close
        rescue StandardError => e
          @adapter.logger.debug "SolidCableMongoid: stream close warning (#{e.class}): #{e.message}"
        ensure
          @stream = nil
        end

        # Check if Change Streams are supported.
        #
        # @return [Boolean]
        def change_stream_supported?
          @adapter.replica_set_configured?
        end

        # Poll for newly inserted broadcast documents when Change Streams are unavailable.
        #
        # @return [void]
        def poll_for_inserts
          coll = @collection

          # Start after current head to avoid replaying history
          @last_seen_id ||= begin
            last = coll.find({}, { projection: { _id: 1 } })
                       .sort({ _id: -1 })
                       .limit(1)
                       .first
            last&.[]("_id")
          end

          interval = poll_interval

          while @running && !change_stream_supported?
            filter = @last_seen_id ? { "_id" => { "$gt" => @last_seen_id } } : {}
            docs = coll.find(filter)
                       .sort({ _id: 1 })
                       .limit(batch_limit)
                       .to_a

            unless docs.empty?
              docs.each { |doc| @last_seen_id = doc["_id"] }
              dispatched = docs.dup
              @event_loop.post { handle_insert_docs(dispatched) }
            end

            @reconnect_attempts = 0 # Reset on successful poll

            # If full batch, loop immediately; otherwise sleep
            sleep(interval) if docs.length < batch_limit
          end
        end

        # Dispatch a broadcast document to local subscribers.
        #
        # Snapshot the subscriber list and subscriber count atomically under @sync
        # to avoid a TOCTOU race between the "any subscribers?" check and the
        # actual dispatch. The snapshot is then iterated outside the mutex so
        # callbacks do not run while the lock is held.
        #
        # Each callback is invoked independently — a failure in one callback does
        # NOT prevent the remaining subscribers from receiving the message.
        #
        # @param full [Hash] the full document
        # @return [void]
        def handle_insert_doc(full)
          channel = full["channel"].to_s
          message = full["message"]

          # Take an atomic snapshot: if nobody is subscribed, bail out immediately.
          # Use fetch to avoid auto-vivifying an empty array for the channel key
          # (SubscriberMap uses a Hash.new { |h,k| h[k] = [] } default).
          list = @sync.synchronize do
            cbs = @subscribers.fetch(channel, nil)
            (cbs.nil? || cbs.empty?) ? nil : cbs.dup
          end
          return unless list

          ActiveSupport::Notifications.instrument("message_received.solid_cable_mongoid",
                                                  channel: channel,
                                                  subscriber_count: list.size) do
            list.each do |cb|
              invoke_callback(cb, message)
            rescue StandardError => e
              @adapter.logger.error "SolidCableMongoid: callback error on channel #{channel.inspect} (#{e.class}): #{e.message}"
              ActiveSupport::Notifications.instrument("message_error.solid_cable_mongoid",
                                                      channel: channel, error: e.class.name)
            end
          end
        rescue StandardError => e
          @adapter.logger.error "SolidCableMongoid: failed to handle insert (#{e.class}): #{e.message}"
          ActiveSupport::Notifications.instrument("message_error.solid_cable_mongoid",
                                                  channel: channel, error: e.class.name)
        end
      end
    end
  end
end
