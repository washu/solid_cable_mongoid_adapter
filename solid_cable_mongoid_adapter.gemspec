# frozen_string_literal: true

require_relative "lib/solid_cable_mongoid_adapter/version"

Gem::Specification.new do |spec|
  spec.name = "solid_cable_mongoid_adapter"
  spec.version = SolidCableMongoidAdapter::VERSION
  spec.authors = ["Sal Scotto"]
  spec.email = ["sscotto@gmail.com"]

  spec.summary = "MongoDB adapter for Action Cable using Mongoid"
  spec.description = "A production-ready Action Cable subscription adapter that uses MongoDB (via Mongoid) " \
                     "as a durable, cross-process broadcast backend with Change Streams support"
  spec.homepage = "https://github.com/washu/solid_cable_mongoid_adapter"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z 2>/dev/null`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .circleci appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "actioncable", ">= 7.0", "< 9.0"
  spec.add_dependency "mongo", ">= 2.18", "< 3.0"
  spec.add_dependency "mongoid", ">= 7.0", "< 10.0"
end
