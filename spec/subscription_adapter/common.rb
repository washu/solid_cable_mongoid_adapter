# frozen_string_literal: true

# Common test patterns for subscription adapters, inspired by Rails' ActionCable tests
module CommonSubscriptionAdapterTest
  def setup_adapter
    @server = double(
      "server",
      logger: Logger.new(nil),
      config: double("config", cable: cable_config),
      event_loop: ActionCable::Connection::StreamEventLoop.new,
      mutex: Mutex.new
    )
    @adapter = ActionCable::SubscriptionAdapter::SolidMongoid.new(@server)
  end

  def teardown_adapter
    @adapter&.shutdown
    @server.event_loop.stop if @server.event_loop.respond_to?(:stop)
  end

  # Helper to subscribe and collect messages into a queue
  def subscribe_as_queue(channel, adapter = @adapter)
    queue = Queue.new
    callback = ->(message) { queue << message }

    adapter.subscribe(channel, callback, -> {})

    yield queue
  ensure
    adapter&.unsubscribe(channel, callback)
  end

  # Wait for a condition with timeout
  def wait_for(timeout: 2)
    start = Time.now
    loop do
      return if yield
      raise "Timeout waiting for condition" if Time.now - start > timeout

      sleep 0.01
    end
  end
end

RSpec.configure do |config|
  config.include CommonSubscriptionAdapterTest, type: :subscription_adapter
end
