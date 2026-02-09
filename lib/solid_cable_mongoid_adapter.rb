# frozen_string_literal: true

require_relative "solid_cable_mongoid_adapter/version"

module SolidCableMongoidAdapter
  class Error < StandardError; end

  class ReplicaSetRequiredError < Error
    def initialize(msg = "MongoDB replica set is required for SolidCableMongoidAdapter")
      super
    end
  end
end

# Auto-require the Action Cable adapter
require_relative "action_cable/subscription_adapter/solid_mongoid"
