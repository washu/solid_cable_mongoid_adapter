# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    add_filter "/vendor/"
  end
end

require "solid_cable_mongoid_adapter"
require "action_cable"
require "mongoid"

# Auto-start MongoDB container for local testing if not already running
def ensure_mongodb_running
  return if ENV["CI"] # Skip in CI environment

  mongodb_host = ENV.fetch("MONGODB_HOST", "localhost:27017")
  return if mongodb_running?(mongodb_host)

  puts "MongoDB not detected at #{mongodb_host}, starting Docker container..."
  start_mongodb_container
  wait_for_mongodb(mongodb_host)
end

def mongodb_running?(host)
  require "socket"
  hostname, port = host.split(":")
  Socket.tcp(hostname, port.to_i, connect_timeout: 1) { true }
rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError
  false
end

def start_mongodb_container
  system("docker run -d --name solid_cable_test_mongo -p 27017:27017 mongo:7 --replSet rs0", out: File::NULL, err: File::NULL)
  sleep 2 # Give container time to start
  # Initialize replica set with explicit localhost hostname to avoid container hostname issues
  init_config = '{_id: "rs0", members: [{_id: 0, host: "localhost:27017"}]}'
  system("docker exec solid_cable_test_mongo mongosh --eval 'rs.initiate(#{init_config})'", out: File::NULL, err: File::NULL)
  sleep 2 # Wait for replica set to initialize
end

def wait_for_mongodb(host, timeout: 60)
  start_time = Time.now
  until mongodb_running?(host)
    raise "MongoDB failed to start within #{timeout} seconds" if Time.now - start_time > timeout
    sleep 1
  end
  puts "MongoDB is ready"
end

ensure_mongodb_running

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Configure Mongoid for tests
  config.before(:suite) do
    Mongoid.configure do |mongoid_config|
      mongoid_config.clients.default = {
        hosts: [ENV.fetch("MONGODB_HOST", "localhost:27017")],
        database: "solid_cable_test"
      }
    end
  end

  config.after(:suite) do
    Mongoid.purge!

    # Clean up Docker container if we started it
    unless ENV["CI"] || ENV["KEEP_MONGO"]
      system("docker stop solid_cable_test_mongo", out: File::NULL, err: File::NULL)
      system("docker rm solid_cable_test_mongo", out: File::NULL, err: File::NULL)
    end
  end
end
