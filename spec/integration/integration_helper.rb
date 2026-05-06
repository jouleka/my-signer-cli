# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/client'

# Shared setup for integration specs. These tests talk to a REAL MySigner
# backend over HTTP — no WebMock — so they need (a) credentials and
# (b) WebMock disabled if it's been required by a sibling spec.
#
# Required ENV:
#   MYSIGNER_API_URL    e.g. http://localhost:3000 or https://app.mysigner.dev
#   MYSIGNER_API_TOKEN  a token with at least 'read' scope
#   MYSIGNER_USER_EMAIL the email associated with the token
#
# When any of these is missing, the entire example is skipped with a clear
# message — never silently passes.

module IntegrationHelper
  REQUIRED_ENV = %w[MYSIGNER_API_URL MYSIGNER_API_TOKEN MYSIGNER_USER_EMAIL].freeze

  def integration_env_or_skip
    missing = REQUIRED_ENV.reject { |k| ENV.fetch(k, nil) && !ENV[k].empty? }
    return if missing.empty?

    skip "Integration test skipped — missing ENV: #{missing.join(', ')}"
  end

  def integration_client
    Mysigner::Client.new(
      api_url: ENV.fetch('MYSIGNER_API_URL'),
      api_token: ENV.fetch('MYSIGNER_API_TOKEN'),
      user_email: ENV.fetch('MYSIGNER_USER_EMAIL')
    )
  end

  # Resolve the org id from the token's /status response so specs don't
  # hardcode it. Cached on the example group so we make one call per file.
  def integration_org_id
    @integration_org_id ||= begin
      res = integration_client.test_connection
      org = res[:data]['organization'] || res[:data].dig('data', 'organization')
      raise 'No organization in /api/v1/status response — bad token?' unless org && org['id']

      org['id']
    end
  end
end

RSpec.configure do |config|
  config.include IntegrationHelper, integration: true

  # Belt-and-suspenders: if WebMock is loaded by some other spec, allow real
  # connections for integration examples.
  config.before(:each, :integration) do
    WebMock.allow_net_connect! if defined?(WebMock)
    integration_env_or_skip
  end

  config.after(:each, :integration) do
    WebMock.disable_net_connect!(allow_localhost: false) if defined?(WebMock)
  end
end
