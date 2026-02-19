#!/bin/bash
# frozen_string_literal: false

# Run benchmark with Docker MongoDB
# Usage: ./benchmark/run_benchmark.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== SolidCableMongoidAdapter Benchmark Runner ==="
echo

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Error: Docker is not running"
    echo "Please start Docker and try again"
    exit 1
fi

# Check if MongoDB container already exists
if docker ps -a --format '{{.Names}}' | grep -q '^mongodb_benchmark$'; then
    echo "📦 Stopping existing MongoDB benchmark container..."
    docker stop mongodb_benchmark > /dev/null 2>&1 || true
    docker rm mongodb_benchmark > /dev/null 2>&1 || true
fi

# Start MongoDB with replica set
echo "🚀 Starting MongoDB replica set..."
docker run -d \
    --name mongodb_benchmark \
    -p 27017:27017 \
    mongo:7 \
    --replSet rs0 \
    > /dev/null

# Wait for MongoDB to be ready
echo "⏳ Waiting for MongoDB to start..."
sleep 5

# Initialize replica set
echo "🔧 Initializing replica set..."
docker exec mongodb_benchmark mongosh --eval \
    'rs.initiate({_id: "rs0", members: [{_id: 0, host: "localhost:27017"}]})' \
    > /dev/null 2>&1

sleep 2

# Check replica set status
echo "✅ Verifying replica set..."
if docker exec mongodb_benchmark mongosh --eval 'rs.status()' > /dev/null 2>&1; then
    echo "✅ MongoDB replica set is ready"
else
    echo "❌ Failed to initialize replica set"
    docker logs mongodb_benchmark
    exit 1
fi

echo

# Run the benchmark
echo "📊 Running benchmark..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

cd "$PROJECT_DIR"
MONGODB_URI="mongodb://localhost:27017/solid_cable_benchmark" \
    bundle exec ruby benchmark/benchmark.rb

BENCHMARK_EXIT_CODE=$?

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Cleanup
echo "🧹 Cleaning up..."
docker stop mongodb_benchmark > /dev/null 2>&1
docker rm mongodb_benchmark > /dev/null 2>&1

if [ $BENCHMARK_EXIT_CODE -eq 0 ]; then
    echo "✅ Benchmark completed successfully!"
else
    echo "❌ Benchmark failed with exit code $BENCHMARK_EXIT_CODE"
    exit $BENCHMARK_EXIT_CODE
fi
