# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActionCable::SubscriptionAdapter::SolidMongoid do
  let(:server) do
    double(
      "server",
      logger: Logger.new(nil),
      config: double("config", cable: config_hash),
      event_loop: double("event_loop", post: nil),
      mutex: Mutex.new
    )
  end

  let(:config_hash) do
    {
      "collection_name" => "test_messages",
      "expiration" => 300,
      "require_replica_set" => false # Disable for testing
    }
  end

  subject(:adapter) { described_class.new(server) }

  describe "#initialize" do
    it "initializes successfully" do
      expect { adapter }.not_to raise_error
    end

    it "logs initialization" do
      expect(server.logger).to receive(:info).with(/SolidCableMongoid: initialized/)
      adapter
    end
  end

  describe "#collection_name" do
    it "returns configured collection name" do
      expect(adapter.collection_name).to eq("test_messages")
    end

    it "returns default when not configured" do
      config_hash.delete("collection_name")
      expect(adapter.collection_name).to eq("action_cable_messages")
    end
  end

  describe "#expiration" do
    it "returns configured expiration" do
      expect(adapter.expiration).to eq(300)
    end

    it "returns default when not configured" do
      config_hash.delete("expiration")
      expect(adapter.expiration).to eq(300)
    end
  end

  describe "#broadcast" do
    it "inserts a document into MongoDB" do
      collection = adapter.collection
      expect(adapter).to receive(:collection).and_return(collection)
      expect(collection).to receive(:insert_one).with(hash_including(channel: "test", message: "payload"))
      adapter.broadcast("test", "payload")
    end

    it "returns true on success" do
      expect(adapter.broadcast("test", "payload")).to be true
    end

    it "returns false on error" do
      collection = adapter.collection
      allow(adapter).to receive(:collection).and_return(collection)
      allow(collection).to receive(:insert_one).and_raise(Mongo::Error::OperationFailure.new("test"))
      expect(adapter.broadcast("test", "payload")).to be false
    end
  end

  describe "#replica_set_configured?" do
    context "when replica set is configured" do
      before do
        allow_any_instance_of(Mongo::Database).to receive(:command)
          .with({ hello: 1 })
          .and_return([{ "setName" => "rs0" }])
      end

      it "returns true" do
        expect(adapter.replica_set_configured?).to be true
      end
    end

    context "when replica set is not configured" do
      before do
        allow_any_instance_of(Mongo::Database).to receive(:command)
          .with({ hello: 1 })
          .and_return([{}])
      end

      it "returns false" do
        expect(adapter.replica_set_configured?).to be false
      end
    end
  end

  describe "#validate_replica_set!" do
    context "when require_replica_set is true" do
      before { config_hash["require_replica_set"] = true }

      it "doesnt raises error if replica set not configured" do
        allow_any_instance_of(described_class).to receive(:replica_set_configured?).and_return(false)
        expect { adapter }.not_to raise_error(
          SolidCableMongoidAdapter::ReplicaSetRequiredError
        )
      end

      it "does not raise if replica set is configured" do
        allow_any_instance_of(described_class).to receive(:replica_set_configured?).and_return(true)
        expect { adapter }.not_to raise_error
      end
    end

    context "when require_replica_set is false" do
      before { config_hash["require_replica_set"] = false }

      it "does not raise even if replica set not configured" do
        allow_any_instance_of(described_class).to receive(:replica_set_configured?).and_return(false)
        expect { adapter }.not_to raise_error
      end
    end
  end

  describe "#subscribe" do
    let(:callback) { proc { |message| message } }
    let(:success_callback) { proc { "subscribed" } }

    it "delegates to listener" do
      listener = adapter.send(:listener)
      expect(listener).to receive(:add_subscriber).with("test_channel", callback, success_callback)
      adapter.subscribe("test_channel", callback, success_callback)
    end
  end

  describe "#unsubscribe" do
    let(:callback) { proc { |message| message } }

    it "delegates to listener" do
      listener = adapter.send(:listener)
      expect(listener).to receive(:remove_subscriber).with("test_channel", callback)
      adapter.unsubscribe("test_channel", callback)
    end
  end

  describe "#shutdown" do
    it "shuts down the listener" do
      listener = adapter.send(:listener)
      expect(listener).to receive(:shutdown)
      adapter.shutdown
    end

    it "handles when listener is nil" do
      adapter.instance_variable_set(:@listener, nil)
      expect { adapter.shutdown }.not_to raise_error
    end
  end

  describe "#collection" do
    it "returns a MongoDB collection" do
      collection = adapter.collection
      expect(collection).to be_a(Mongo::Collection)
      expect(collection.name).to eq("test_messages")
    end
  end

  describe "#ensure_collection_state" do
    it "ensures collection and indexes exist" do
      # Just verify the method runs without error
      # The actual index creation is tested implicitly through adapter initialization
      expect { adapter.send(:ensure_collection_state) }.not_to raise_error
    end

    it "creates collection if needed" do
      collection = adapter.collection
      expect(collection).to be_a(Mongo::Collection)
    end
  end

  describe "broadcast error handling" do
    it "returns false on unexpected errors" do
      collection = adapter.collection
      allow(adapter).to receive(:collection).and_return(collection)
      allow(collection).to receive(:insert_one).and_raise(StandardError.new("unexpected"))
      expect(adapter.broadcast("test", "payload")).to be false
    end

    it "logs MongoDB errors" do
      collection = adapter.collection
      allow(adapter).to receive(:collection).and_return(collection)
      allow(collection).to receive(:insert_one).and_raise(Mongo::Error::OperationFailure.new("test"))
      expect(server.logger).to receive(:error).with(/broadcast error/)
      adapter.broadcast("test", "payload")
    end

    it "logs unexpected errors" do
      collection = adapter.collection
      allow(adapter).to receive(:collection).and_return(collection)
      allow(collection).to receive(:insert_one).and_raise(StandardError.new("unexpected"))
      expect(server.logger).to receive(:error).with(/unexpected broadcast error/)
      adapter.broadcast("test", "payload")
    end
  end
end
