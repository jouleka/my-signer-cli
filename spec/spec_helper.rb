# frozen_string_literal: true

require 'bundler/setup'
require 'mysigner'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Tests tagged :integration hit a real MySigner backend and consume real
  # API/network resources — they are excluded from the default run. Opt in
  # with `bundle exec rspec --tag integration`. See spec/integration/README
  # in spec/README.md for the required ENV vars.
  config.filter_run_excluding integration: true unless ENV['INTEGRATION'] == '1'

  # 0.3.1 — hermetic local-only baseline. Without this, a developer who has
  # `local_only: true` persistently set in their own ~/.mysigner/config.yml
  # would see every SERVER-command spec take the local-only-gate branch
  # (exit 2) instead of the "not logged in" branch (exit 1) those specs
  # encode. Per-test overrides via `and_call_original` are used by the
  # specs that intentionally exercise the file source.
  config.before do
    allow(Mysigner::Config).to receive(:local_only_from_file?).and_return(false) if defined?(Mysigner::Config)

    # The CI/dev box is Linux, but the iOS-flow and doctor specs assume macOS
    # (they mock xcodebuild/security). Default macos? to true so those specs are
    # OS-independent; specs that intentionally exercise the non-macOS guard
    # override with `allow(cli).to receive(:macos?).and_return(false)`.
    allow_any_instance_of(Mysigner::CLI).to receive(:macos?).and_return(true) if defined?(Mysigner::CLI)
  end
end
