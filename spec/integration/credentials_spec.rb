# frozen_string_literal: true

require_relative 'integration_helper'

# Confirms the certs/profiles/devices endpoints return the shapes the
# signing/diagnostic flows need. These are the data sources for
# `mysigner certificates`, `mysigner profiles`, `mysigner devices`, and
# `mysigner doctor`.
RSpec.describe 'API integration: signing resources', :integration do
  let(:client) { integration_client }

  describe 'GET /api/v1/organizations/:id/certificates' do
    it 'returns certificates with the fields the CLI displays' do
      response = client.get("/api/v1/organizations/#{integration_org_id}/certificates")

      certs = response[:data]['certificates'] || response[:data]['data']
      expect(certs).to be_an(Array)

      if certs.empty?
        skip 'Org has no certificates — skipping field assertions'
      else
        cert = certs.first
        expect(cert).to include('id', 'remote_id', 'name', 'certificate_type', 'expires_at')
        # serial_number is what `mysigner certificate check` matches against
        # the local keychain — keep it in the contract.
        expect(cert).to have_key('serial_number')
      end
    end
  end

  describe 'GET /api/v1/organizations/:id/profiles' do
    it 'returns profiles with bundle_id, type, state, uuid' do
      response = client.get("/api/v1/organizations/#{integration_org_id}/profiles")

      profiles = response[:data]['profiles'] || response[:data]['data']
      expect(profiles).to be_an(Array)

      if profiles.empty?
        skip 'Org has no profiles — skipping field assertions'
      else
        p = profiles.first
        expect(p).to include('id', 'remote_id', 'name', 'profile_type',
                             'state', 'platform', 'bundle_id_identifier',
                             'expires_at', 'uuid')
      end
    end
  end

  describe 'GET /api/v1/organizations/:id/devices' do
    it 'returns devices with udid, platform, device_class, status' do
      response = client.get("/api/v1/organizations/#{integration_org_id}/devices")

      devices = response[:data]['devices'] || response[:data]['data']
      expect(devices).to be_an(Array)

      if devices.empty?
        skip 'Org has no devices — skipping field assertions'
      else
        d = devices.first
        expect(d).to include('id', 'remote_id', 'name', 'udid',
                             'platform', 'device_class', 'status')
      end
    end
  end

  describe 'GET /api/v1/organizations/:id/google_play_credentials' do
    it 'returns the credentials envelope (may be empty array)' do
      response = client.get("/api/v1/organizations/#{integration_org_id}/google_play_credentials")

      data = response[:data]
      creds = data['credentials'] || data['google_play_credentials'] || data['data']
      # 200 with an empty array is the typical no-creds-yet state.
      expect(creds).to be_an(Array).or(eq(nil))

      if creds&.any?
        cred = creds.first
        expect(cred).to include('id', 'name')
        # service_account_json should NEVER be in the response. The backend
        # encrypts it at rest and only returns metadata.
        expect(cred).not_to have_key('service_account_json')
      end
    end
  end
end
