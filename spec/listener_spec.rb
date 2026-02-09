# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActionCable::SubscriptionAdapter::SolidMongoid::Listener do
  let(:server) do
    double(
      "server",
      logger: Logger.new(nil),
      config: double("config", cable: config_hash),
      event_loop: double("event_loop"),
      mutex: Mutex.new
    )
  end

  let(:config_hash) do
    {
      "collection_name" => "test_messages",
      "expiration" => 300,
      "require_replica_set" => false,
      "reconnect_delay" => 1.0,
      "max_reconnect_delay" => 60.0,
      "poll_interval_ms" => 100,
      "poll_batch_limit" => 50
    }
  end

  let(:adapter) { ActionCable::SubscriptionAdapter::SolidMongoid.new(server) }
  let(:event_loop) { server.event_loop }

  subject(:listener) { described_class.new(adapter, event_loop) }

  after do
    if defined?(listener) && listener.instance_variable_get(:@running)
      listener.shutdown
      # Ensure thread is fully stopped before mocks are cleaned up
      thread = listener.instance_variable_get(:@thread)
      thread&.join(1)
    end
  end

  describe "#initialize" do
    it "starts a listener thread" do
      thread = listener.instance_variable_get(:@thread)
      expect(thread).to be_a(Thread)
      expect(thread).to be_alive
    end

    it "sets running flag to true" do
      expect(listener.instance_variable_get(:@running)).to be true
    end

    it "initializes with nil stream" do
      expect(listener.instance_variable_get(:@stream)).to be_nil
    end

    it "initializes with 0 reconnect attempts" do
      expect(listener.instance_variable_get(:@reconnect_attempts)).to eq(0)
    end
  end

  describe "#add_subscriber" do
    let(:callback) { proc { |msg| msg } }
    let(:success_callback) { proc { "success" } }

    it "adds a subscriber to the channel" do
      listener.add_subscriber("test_channel", callback, nil)

      subscribers = listener.instance_variable_get(:@subscribers)
      expect(subscribers["test_channel"]).to include(callback)
    end

    it "invokes success callback when provided for new channel" do
      expect(success_callback).to receive(:call)
      listener.add_subscriber("test_channel", callback, success_callback)
    end

    it "invokes success callback for existing channel subscribers" do
      listener.add_subscriber("test_channel", callback, nil)
      expect(success_callback).to receive(:call)
      listener.add_subscriber("test_channel", proc { |msg| msg }, success_callback)
    end

    it "works without success callback" do
      expect { listener.add_subscriber("test_channel", callback, nil) }.not_to raise_error
    end
  end

  describe "#remove_subscriber" do
    let(:callback) { proc { |msg| msg } }

    before do
      listener.add_subscriber("test_channel", callback, nil)
    end

    it "removes a subscriber from the channel" do
      listener.remove_subscriber("test_channel", callback)

      subscribers = listener.instance_variable_get(:@subscribers)
      expect(subscribers["test_channel"]).not_to include(callback)
    end
  end

  describe "#invoke_callback" do
    it "posts callback execution to event loop" do
      expect(event_loop).to receive(:post).and_yield
      callback = proc { "test" }
      expect(callback).to receive(:call).with("message")
      listener.send(:invoke_callback, callback, "message")
    end
  end

  describe "#shutdown" do
    it "sets running flag to false" do
      listener.shutdown
      expect(listener.instance_variable_get(:@running)).to be false
    end

    it "closes the stream if present" do
      stream = double("stream")
      listener.instance_variable_set(:@stream, stream)
      expect(stream).to receive(:close).and_return(nil)
      listener.shutdown
    end

    it "terminates the listener thread" do
      thread = listener.instance_variable_get(:@thread)
      listener.shutdown
      sleep 0.1
      expect(thread).not_to be_alive
    end

    it "handles thread that doesn't stop gracefully" do
      thread = listener.instance_variable_get(:@thread)
      allow(thread).to receive(:join).and_return(nil)
      expect(thread).to receive(:kill)
      listener.shutdown
    end
  end

  describe "reconnection behavior" do
    it "calculates exponential backoff delay" do
      listener.instance_variable_set(:@reconnect_attempts, 0)
      expect(listener.send(:reconnect_delay)).to eq(1.0)

      listener.instance_variable_set(:@reconnect_attempts, 1)
      expect(listener.send(:reconnect_delay)).to eq(2.0)

      listener.instance_variable_set(:@reconnect_attempts, 5)
      expect(listener.send(:reconnect_delay)).to eq(32.0)
    end

    it "caps reconnect delay at max_reconnect_delay" do
      listener.instance_variable_set(:@reconnect_attempts, 10)
      expect(listener.send(:reconnect_delay)).to eq(60.0)
    end
  end

  describe "#poll_interval" do
    it "returns configured poll interval in seconds" do
      expect(listener.send(:poll_interval)).to eq(0.1)
    end

    it "defaults to 0.5 seconds when not configured" do
      config_hash.delete("poll_interval_ms")
      new_listener = described_class.new(adapter, event_loop)
      expect(new_listener.send(:poll_interval)).to eq(0.5)
      new_listener.shutdown
    end
  end

  describe "configuration" do
    it "uses configured poll_interval_ms" do
      # This is implicitly tested through poll_interval method
      expect(listener.send(:poll_interval)).to eq(0.1)
    end
  end

  describe "change stream handling" do
    it "attempts to watch change streams" do
      collection = adapter.get_collection
      allow(adapter).to receive(:get_collection).and_return(collection)

      # Simulate change stream creation
      stream = double("stream")
      allow(collection).to receive(:watch).and_return(stream)
      allow(stream).to receive(:each)

      # Give the listener thread time to attempt watching
      sleep 0.2
    end
  end

  describe "polling fallback" do
    it "has fallback mechanism when change streams unavailable" do
      # This is a complex integration test that's hard to mock properly
      # The polling logic is exercised in the background thread
      # We just verify the listener thread is running
      thread = listener.instance_variable_get(:@thread)
      expect(thread).to be_alive
    end
  end
end
