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
end
