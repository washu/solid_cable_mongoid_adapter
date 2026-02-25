#!/bin/bash
set -e

# Extract version from version.rb
VERSION=$(ruby -r ./lib/solid_cable_mongoid_adapter/version.rb -e "puts SolidCableMongoidAdapter::VERSION")

echo "Building gem version ${VERSION}..."
gem build solid_cable_mongoid_adapter.gemspec

echo "Pushing to RubyGems..."
gem push solid_cable_mongoid_adapter-${VERSION}.gem

echo "Done!"
