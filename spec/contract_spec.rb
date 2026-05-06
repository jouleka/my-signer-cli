# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'mysigner/client'
require 'json'

# API Contract spec.
#
# What this catches: silent backend response-shape changes. The unit specs
# in spec/cli/* hand-craft small response bodies; if the backend rename a
# field (`bundle_id` -> `bundleId`) or drops one, those specs keep passing
# because they assert against their own fakes. This spec wires up
# WebMock against *real, captured* responses in spec/fixtures/api_responses
# and runs them through the same Client error-mapping path the CLI uses
# end-to-end. If a field disappears, the assertions here trip.
#
# Refreshing fixtures: see spec/README.md ("Refreshing API fixtures").
FIXTURES_DIR = File.expand_path('fixtures/api_responses', __dir__)

RSpec.describe 'API contract: real captured responses' do
  let(:api_url) { 'http://localhost:3000' }
  let(:api_token) { 'mst_contract_test_token' }
  let(:client) { Mysigner::Client.new(api_url: api_url, api_token: api_token) }

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES_DIR, name)))
  end

  def stub_get(path, fixture_file)
    stub_request(:get, "#{api_url}#{path}")
      .to_return(
        status: 200,
        body: File.read(File.join(FIXTURES_DIR, fixture_file)),
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  describe 'GET /api/v1/status' do
    before { stub_get('/api/v1/status', 'status.json') }

    it 'returns success with user, organization, and token blocks' do
      response = client.test_connection

      expect(response[:success]).to be true
      expect(response[:status]).to eq(200)
      data = response[:data]
      expect(data).to have_key('user')
      expect(data['user']).to include('id', 'email')
      expect(data).to have_key('organization')
      expect(data['organization']).to include('id', 'name')
      expect(data).to have_key('token')
      expect(data['token']).to include('name', 'scopes', 'last_used_at')
      expect(data['token']['scopes']).to be_an(Array)
    end
  end

  describe 'GET /api/v1/user/organizations' do
    before { stub_get('/api/v1/user/organizations', 'user_organizations.json') }

    it 'returns a list of organizations the user has access to' do
      response = client.get('/api/v1/user/organizations')

      expect(response[:success]).to be true
      orgs = response[:data]['organizations'] || response[:data]['data']&.dig('organizations')
      expect(orgs).to be_an(Array).and(satisfy(&:any?))
      expect(orgs.first).to include('id', 'name')
    end
  end

  describe 'GET /api/v1/organizations/:id' do
    before { stub_get('/api/v1/organizations/29', 'organizations_29.json') }

    it 'returns org metadata + plan + sync state' do
      response = client.get('/api/v1/organizations/29')

      data = response[:data]
      expect(data).to include('id', 'name', 'role', 'access_state')

      # Plan / entitlements: the CLI reads these to gate features.
      expect(data['plan']).to include('tier', 'entitlements', 'usage')
      expect(data['plan']['entitlements']).to include('limits', 'features')

      # ASC + Play status flags. The onboarding check on `mysigner onboard`
      # depends on these exact keys.
      expect(data).to have_key('app_store_connect_configured')
      expect(data).to have_key('google_play_configured')

      # Stats are surfaced in `mysigner status` — keep the keys stable.
      expect(data['stats']).to include(
        'certificates_count', 'devices_count', 'profiles_count', 'bundle_ids_count'
      )

      # Sync block — surfaced in status output too.
      expect(data['sync']).to include('status', 'last_synced_at', 'has_credentials')
    end
  end

  describe 'GET /api/v1/organizations/:id/apple_apps' do
    before { stub_get('/api/v1/organizations/29/apple_apps', 'organizations_29_apple_apps.json') }

    it 'returns apps array with the fields `mysigner apps` displays' do
      response = client.get('/api/v1/organizations/29/apple_apps')

      apps = response[:data]['data']['apps']
      expect(apps).to be_an(Array).and(satisfy(&:any?))
      app = apps.first
      expect(app).to include('id', 'app_store_id', 'bundle_id', 'name')
      expect(response[:data]).to have_key('pagination')
      expect(response[:data]['pagination']).to include('page', 'per_page', 'total')
    end
  end

  describe 'GET /api/v1/organizations/:id/certificates' do
    before { stub_get('/api/v1/organizations/29/certificates', 'organizations_29_certificates.json') }

    it 'returns certificates with the fields `mysigner certificates` displays' do
      response = client.get('/api/v1/organizations/29/certificates')

      certs = response[:data]['certificates']
      expect(certs).to be_an(Array).and(satisfy(&:any?))
      cert = certs.first
      expect(cert).to include('id', 'remote_id', 'name', 'certificate_type', 'expires_at')
      # `mysigner certificate check` matches by serial_number against the
      # local keychain — drop this and the matcher silently breaks.
      expect(cert).to have_key('serial_number')
    end
  end

  describe 'GET /api/v1/organizations/:id/profiles' do
    before { stub_get('/api/v1/organizations/29/profiles', 'organizations_29_profiles.json') }

    it 'returns profiles with bundle id, type, state, and uuid' do
      response = client.get('/api/v1/organizations/29/profiles')

      profiles = response[:data]['profiles']
      expect(profiles).to be_an(Array).and(satisfy(&:any?))
      p = profiles.first
      expect(p).to include('id', 'remote_id', 'name', 'profile_type', 'state', 'platform',
                           'bundle_id_identifier', 'expires_at', 'uuid')
    end
  end

  describe 'GET /api/v1/organizations/:id/devices' do
    before { stub_get('/api/v1/organizations/29/devices', 'organizations_29_devices.json') }

    it 'returns devices with udid, platform, device_class, and status' do
      response = client.get('/api/v1/organizations/29/devices')

      devices = response[:data]['devices']
      expect(devices).to be_an(Array).and(satisfy(&:any?))
      d = devices.first
      expect(d).to include('id', 'remote_id', 'name', 'udid', 'platform', 'device_class', 'status')
    end
  end

  describe 'GET /api/v1/organizations/:id/android_apps' do
    before { stub_get('/api/v1/organizations/29/android_apps', 'organizations_29_android_apps.json') }

    it 'returns the apps envelope expected by `mysigner apps --platform android`' do
      response = client.get('/api/v1/organizations/29/android_apps')

      # The fixture for this org has zero android apps right now. We're
      # asserting the *envelope* — the keys the CLI relies on to render
      # the empty-state message correctly.
      expect(response[:data]).to have_key('android_apps').or have_key('data')
    end
  end

  describe 'GET /api/v1/organizations/:id/google_play_credentials' do
    before do
      stub_get('/api/v1/organizations/29/google_play_credentials',
               'organizations_29_google_play_credentials.json')
    end

    it 'returns the credentials envelope (may be empty array)' do
      response = client.get('/api/v1/organizations/29/google_play_credentials')

      # Typical when no GPlay creds are set up — the response is still a
      # 200 with an array. `mysigner gp-credential list` handles empty.
      data = response[:data]
      creds = data['credentials'] || data['google_play_credentials'] || data['data']
      expect(creds).to be_an(Array).or(eq(nil))
    end
  end
end
