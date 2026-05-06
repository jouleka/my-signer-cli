# frozen_string_literal: true

require_relative 'integration_helper'

# Read-only smoke tests against a real MySigner backend. Use these as the
# pre-release sanity check: "does the CLI's HTTP/auth layer still talk to
# our prod backend correctly?". No state is modified.
RSpec.describe 'API integration: read-only smoke', :integration do
  let(:client) { integration_client }

  describe 'GET /api/v1/status' do
    it 'authenticates and returns user + organization + token blocks' do
      response = client.test_connection

      expect(response[:success]).to be true
      data = response[:data]
      expect(data['user']).to include('id', 'email')
      expect(data['organization']).to include('id', 'name')
      expect(data['token']).to include('name', 'scopes')
      expect(data['token']['scopes']).to be_an(Array).and(satisfy(&:any?))
    end
  end

  describe 'GET /api/v1/user/organizations' do
    it 'returns at least one organization the user belongs to' do
      response = client.get('/api/v1/user/organizations')

      orgs = response[:data]['organizations'] || response[:data].dig('data', 'organizations')
      expect(orgs).to be_an(Array).and(satisfy(&:any?))
      expect(orgs.first).to include('id', 'name')
    end
  end

  describe 'GET /api/v1/organizations/:id (current org)' do
    it 'returns plan + entitlements + sync state for the token org' do
      response = client.get("/api/v1/organizations/#{integration_org_id}")

      data = response[:data]
      expect(data).to include('id', 'name', 'role', 'access_state')
      expect(data['plan']).to include('tier', 'entitlements', 'usage')
      expect(data).to have_key('app_store_connect_configured')
      expect(data).to have_key('google_play_configured')
      expect(data['sync']).to include('status', 'has_credentials')
    end
  end
end
