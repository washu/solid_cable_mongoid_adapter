# frozen_string_literal: true

require "spec_helper"
require_relative "common"

RSpec.describe "SolidMongoid Subscription Adapter", type: :subscription_adapter do
  include CommonSubscriptionAdapterTest

  def cable_config
    {
      "adapter" => "solid_mongoid",
      "collection_name" => "test_adapter_messages",
      "expiration" => 300,
      "require_replica_set" => false
    }
  end

  before(:each) { setup_adapter }
  after(:each) { teardown_adapter }

  it "subscribes and broadcasts to a channel" do
    subscribe_as_queue("chat") do |queue|
      @adapter.broadcast("chat", "hello world")

      wait_for { !queue.empty? }
      expect(queue.pop).to eq("hello world")
    end
  end

  it "broadcasts to multiple subscribers on same channel" do
    subscribe_as_queue("chat") do |queue1|
      subscribe_as_queue("chat") do |queue2|
        @adapter.broadcast("chat", "message for all")

        wait_for { !queue1.empty? && !queue2.empty? }
        expect(queue1.pop).to eq("message for all")
        expect(queue2.pop).to eq("message for all")
      end
    end
  end

  it "filters broadcasts by channel" do
    subscribe_as_queue("channel1") do |queue1|
      subscribe_as_queue("channel2") do |queue2|
        @adapter.broadcast("channel1", "message1")
        @adapter.broadcast("channel2", "message2")

        wait_for { !queue1.empty? && !queue2.empty? }
        expect(queue1.pop).to eq("message1")
        expect(queue2.pop).to eq("message2")

        # Ensure no cross-channel pollution
        expect(queue1).to be_empty
        expect(queue2).to be_empty
      end
    end
  end

  it "handles long channel identifiers" do
    long_channel = "a" * 100
    subscribe_as_queue(long_channel) do |queue|
      @adapter.broadcast(long_channel, "long channel message")

      wait_for { !queue.empty? }
      expect(queue.pop).to eq("long channel message")
    end
  end

  it "handles unsubscribe correctly" do
    queue = Queue.new
    callback = ->(message) { queue << message }

    @adapter.subscribe("chat", callback, -> {})
    @adapter.broadcast("chat", "message1")

    wait_for { !queue.empty? }
    expect(queue.pop).to eq("message1")

    @adapter.unsubscribe("chat", callback)
    @adapter.broadcast("chat", "message2")

    sleep 0.2 # Give time for message to potentially arrive
    expect(queue).to be_empty
  end

  it "handles multiple subscriptions and unsubscriptions" do
    callbacks = 3.times.map { ->(msg) {} }
    queues = 3.times.map { Queue.new }

    callbacks.each_with_index do |_callback, i|
      wrapped_callback = ->(msg) { queues[i] << msg }
      @adapter.subscribe("multi_channel", wrapped_callback, -> {})
    end

    @adapter.broadcast("multi_channel", "test message")

    wait_for(timeout: 3) { queues.all? { |q| !q.empty? } }
    queues.each do |queue|
      expect(queue.pop).to eq("test message")
    end
  end

  it "broadcasts immediately available to new subscribers" do
    # First subscriber gets the message
    subscribe_as_queue("immediate") do |queue1|
      @adapter.broadcast("immediate", "first message")

      wait_for { !queue1.empty? }
      expect(queue1.pop).to eq("first message")

      # Second subscriber joins after first message
      subscribe_as_queue("immediate") do |queue2|
        @adapter.broadcast("immediate", "second message")

        wait_for { !queue1.empty? && !queue2.empty? }
        expect(queue1.pop).to eq("second message")
        expect(queue2.pop).to eq("second message")
      end
    end
  end

  it "handles rapid successive broadcasts" do
    subscribe_as_queue("rapid") do |queue|
      10.times { |i| @adapter.broadcast("rapid", "message#{i}") }

      messages = []
      wait_for(timeout: 3) { queue.size >= 10 }

      10.times { messages << queue.pop }
      expect(messages).to match_array((0...10).map { |i| "message#{i}" })
    end
  end
end
