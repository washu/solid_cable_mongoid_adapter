# frozen_string_literal: true

RSpec.describe SolidCableMongoidAdapter do
  it "has a version number" do
    expect(SolidCableMongoidAdapter::VERSION).not_to be nil
  end

  describe "::ReplicaSetRequiredError" do
    it "is a subclass of Error" do
      expect(SolidCableMongoidAdapter::ReplicaSetRequiredError).to be < SolidCableMongoidAdapter::Error
    end

    it "has a default message" do
      error = SolidCableMongoidAdapter::ReplicaSetRequiredError.new
      expect(error.message).to include("replica set is required")
    end
  end
end
