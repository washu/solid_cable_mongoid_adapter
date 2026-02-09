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
      # @param channel [String, Symbol] the channel identifier
      # @param payload [String] the raw message payload (Action Cable provides a JSON string)
      # @return [Boolean] true if successful, false on error
      def broadcast(channel, payload)
        get_collection.insert_one(
          {
            channel: channel.to_s,
            message: payload,
            created_at: Time.now.utc,
            _expires: Time.now.utc + expiration
          }
        )
        true
      rescue Mongo::Error => e
        logger.error "SolidCableMongoid: broadcast error (#{e.class}): #{e.message}"
        false
      rescue => e
        logger.error "SolidCableMongoid: unexpected broadcast error (#{e.class}): #{e.message}"
        false
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

        unless replica_set_configured?
          logger.warn "SolidCableMongoid: MongoDB is not configured as a replica set. " \
                      "Change Streams are unavailable; falling back to polling mode. " \
                      "Set require_replica_set: false in cable.yml to disable this check."
        end
      end

      # Check if MongoDB is configured as a replica set.
      #
      # @return [Boolean] true if replica set is configured
      def replica_set_configured?
        client = Mongoid.default_client
        hello = client.database.command({ hello: 1 }).first rescue nil
        hello ||= client.database.command({ ismaster: 1 }).first rescue nil
        !!hello&.[]("setName")
      rescue => e
        logger.warn "SolidCableMongoid: unable to check replica set status (#{e.class}): #{e.message}"
        false
      end

      # Ensure the MongoDB collection and indexes are in the expected state.
      #
      # @return [void]
      def ensure_collection_state
        db = Mongoid.default_client.database

        # 1. Ensure collection exists
        unless db.collection_names.include?(collection_name)
          db.create_collection(collection_name)
          logger.info "SolidCableMongoid: created collection #{collection_name.inspect}"
        end

        coll = db.collection(collection_name)

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
      rescue => e
        logger.error "SolidCableMongoid: failed to ensure collection state: #{e.message}"
      end

      # --- Configuration accessors -------------------------------------------------

      # Obtain the Mongo collection used for Action Cable messages.
      # Not memoized to avoid issues with forking (e.g., Passenger, Puma cluster mode).
      #
      # @return [Mongo::Collection]
      def get_collection
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

      # The logger from the Action Cable server.
      #
      # @return [Logger]
      def logger
        @server.logger
      end

      # The Action Cable server instance.
      #
      # @return [ActionCable::Server::Base]
      def server
        @server
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

          @thread = Thread.new { listen_loop }
          @thread.name = "solid-cable-mongoid-#{Process.pid}" if @thread.respond_to?(:name=)
          @thread.abort_on_exception = false
        end

        # Ensure callbacks fire on ActionCable's event loop for thread-safety.
        def invoke_callback(*)
          @event_loop.post { super }
        end

        # Graceful shutdown with configurable timeout.
        def shutdown
          @running = false
          close_stream
          if @thread&.alive?
            @thread.join(5) || @thread.kill
          end
        end

        private

        # Calculate reconnect delay with exponential backoff.
        #
        # @return [Float] seconds to wait before retry
        def reconnect_delay
          base = (@adapter.server.config.cable.fetch("reconnect_delay", 1.0)).to_f
          max = (@adapter.server.config.cable.fetch("max_reconnect_delay", 60.0)).to_f
          [base * (2**@reconnect_attempts), max].min
        end

        # Polling interval in seconds.
        #
        # @return [Float]
        def poll_interval
          (@adapter.server.config.cable.fetch("poll_interval_ms", 500)).to_i / 1000.0
        end

        # Max documents to fetch per poll.
        #
        # @return [Integer]
        def batch_limit
          (@adapter.server.config.cable.fetch("poll_batch_limit", 200)).to_i
        end

        # Main listener loop that receives broadcasts from MongoDB.
        #
        # @return [void]
        def listen_loop
          pipeline = [{ '$match' => { 'operationType' => 'insert' } }]

          while @running
            begin
              if change_stream_supported?
                # Change Stream path (replica set / sharded)
                opts = { max_await_time_ms: 1000 }
                opts[:resume_after] = @resume_token if @resume_token

                @stream = @adapter.get_collection.watch(pipeline, opts)
                enum = @stream.to_enum

                while @running && enum
                  doc = enum.try_next
                  next unless doc # nil when no event yet

                  handle_insert_doc(doc["fullDocument"] || {})
                  @resume_token = @stream.resume_token
                  @reconnect_attempts = 0 # Reset on successful iteration
                end
              else
                # Standalone fallback: polling
                poll_for_inserts
              end
            rescue Mongo::Error::OperationFailure => e
              unless e.message.include?('operation exceeded time limit')
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
            rescue => e
              @adapter.logger.error "SolidCableMongoid: unexpected listener error (#{e.class}): #{e.message}\n#{Array(e.backtrace).take(10).join("\n")}"
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
        rescue => e
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
          coll = @adapter.get_collection

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
            filter = @last_seen_id ? { '_id' => { '$gt' => @last_seen_id } } : {}
            docs = coll.find(filter)
                       .sort({ _id: 1 })
                       .limit(batch_limit)
                       .to_a

            docs.each do |doc|
              handle_insert_doc(doc)
              @last_seen_id = doc["_id"]
            end

            @reconnect_attempts = 0 # Reset on successful poll

            # If full batch, loop immediately; otherwise sleep
            sleep(interval) if docs.length < batch_limit
          end
        end

        # Dispatch a broadcast document to local subscribers.
        #
        # @param full [Hash] the full document
        # @return [void]
        def handle_insert_doc(full)
          channel = full["channel"].to_s
          message = full["message"]
          return unless @subscribers.key?(channel)

          broadcast(channel, message)
        rescue => e
          @adapter.logger.error "SolidCableMongoid: failed to handle insert (#{e.class}): #{e.message}"
        end
      end
    end
  end
end
