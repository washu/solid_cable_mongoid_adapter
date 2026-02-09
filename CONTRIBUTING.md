# Contributing to SolidCableMongoidAdapter

First off, thank you for considering contributing to SolidCableMongoidAdapter!

## Code of Conduct

This project and everyone participating in it is governed by our Code of Conduct. By participating, you are expected to uphold this code.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues as you might find out that you don't need to create one. When you are creating a bug report, please include as many details as possible:

* Use a clear and descriptive title
* Describe the exact steps which reproduce the problem
* Provide specific examples to demonstrate the steps
* Describe the behavior you observed after following the steps
* Explain which behavior you expected to see instead and why
* Include logs and error messages

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, please include:

* Use a clear and descriptive title
* Provide a step-by-step description of the suggested enhancement
* Provide specific examples to demonstrate the steps
* Describe the current behavior and explain which behavior you expected to see instead
* Explain why this enhancement would be useful

### Pull Requests

* Fill in the required template
* Do not include issue numbers in the PR title
* Follow the Ruby styleguide (RuboCop)
* Include thoughtfully-worded, well-structured RSpec tests
* Document new code
* End all files with a newline

## Development Setup

1. Fork and clone the repository
2. Install dependencies: `bundle install`
3. Set up MongoDB replica set (see README)
4. Run tests: `bundle exec rspec`
5. Run linter: `bundle exec rubocop`

## Testing

```bash
# Run all tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/adapter_spec.rb

# Run with coverage
COVERAGE=true bundle exec rspec
```

## Style Guide

We use RuboCop for code style enforcement. Run `bundle exec rubocop` before committing.

## Commit Messages

* Use the present tense ("Add feature" not "Added feature")
* Use the imperative mood ("Move cursor to..." not "Moves cursor to...")
* Limit the first line to 72 characters or less
* Reference issues and pull requests liberally after the first line

## Release Process

1. Update version in `lib/solid_cable_mongoid_adapter/version.rb`
2. Update CHANGELOG.md
3. Commit changes
4. Create git tag: `git tag v1.0.0`
5. Push: `git push origin main --tags`
6. Build gem: `gem build solid_cable_mongoid_adapter.gemspec`
7. Publish: `gem push solid_cable_mongoid_adapter-1.0.0.gem`

## Questions?

Feel free to open an issue with your question or contact the maintainers directly.
