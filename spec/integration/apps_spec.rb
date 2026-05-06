# frozen_string_literal: true

require_relative 'integration_helper'

# Confirms that the apps endpoints return the shapes `mysigner apps`
# depends on, against a real backend with at least one app on each store.
# These will skip cleanly if the org has no apps on a platform.
RSpec.describe 'API integration: apps', :integration do
  let(:client) { integration_client }

  describe 'GET /api/v1/organizations/:id/apple_apps' do
    it 'returns apple apps with the fields the CLI displays' do
      response = client.get("/api/v1/organizations/#{integration_org_id}/apple_apps")

      apps = response[:data].dig('data', 'apps') || response[:data]['apple_apps']
      expect(apps).to be_an(Array)

      if apps.empty?
        skip 'Org has no Apple apps — skipping field assertions'
      else
        app = apps.first
        expect(app).to include('id', 'bundle_id', 'name')
        # `mysigner ship testflight` looks up by app_store_id when present.
        expect(app).to have_key('app_store_id')
      end
    end
  end

  describe 'GET /api/v1/organizations/:id/android_apps' do
    it 'returns android apps with the fields the CLI displays' do
      response = client.get("/api/v1/organizations/#{integration_org_id}/android_apps")

      data = response[:data]
      apps = data['android_apps'] || data.dig('data', 'apps') || data['data']
      expect(apps).to be_an(Array).or(eq(nil))

      if apps.nil? || apps.empty?
        skip 'Org has no Android apps — skipping field assertions'
      else
        app = apps.first
        # `mysigner ship internal` keys off package_name to find tracks.
        expect(app).to include('id', 'package_name', 'name')
      end
    end
  end
end
