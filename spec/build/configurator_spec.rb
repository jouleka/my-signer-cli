# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/build/configurator'

RSpec.describe Mysigner::Build::Configurator do
  let(:parser) { instance_double(Mysigner::Build::Parser) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:org_id) { 5 }
  let(:configurator) { described_class.new(parser, client, org_id) }

  let(:bundle_id) { 'com.example.app' }
  let(:team_id) { 'ABCD123456' }
  let(:target_name) { 'MyApp' }
  let(:configuration) { 'Release' }

  let(:profile_response) do
    {
      data: [
        {
          'id' => 1,
          'name' => 'App Store Profile',
          'profile_type' => 'IOS_APP_STORE',
          'bundle_id' => bundle_id,
          'team_id' => team_id,
          'status' => 'ACTIVE',
          'expires_at' => (Time.now + (365 * 24 * 60 * 60)).to_s
        }
      ]
    }
  end

  before do
    mock_target = double('target', build_configurations: [mock_config])
    mock_build_settings = {
      'DEVELOPMENT_TEAM' => team_id
    }
    allow(mock_config).to receive(:name).and_return(configuration)
    allow(mock_config).to receive(:build_settings).and_return(mock_build_settings)
    allow(parser).to receive(:find_target).with(target_name).and_return(mock_target)
    allow(parser).to receive(:bundle_id).with(target_name, configuration).and_return(bundle_id)
    allow(parser).to receive(:team_id).with(target_name, configuration).and_return(team_id)
    allow(parser).to receive_message_chain(:project, :save)
  end

  let(:mock_config) { double('config') }

  describe '#configure!' do
    context 'with app-store build type' do
      it 'fetches and configures with IOS_APP_STORE profile' do
        # Stub the /match endpoint to return profile directly
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{org_id}/profiles/match",
          params: {
            bundle_id: bundle_id,
            type: 'appstore'
          }
        ).and_return({ profile: profile_response[:data][0] })

        result = configurator.configure!(target_name, configuration, build_type: :appstore)

        expect(result['name']).to eq('App Store Profile')
      end
    end

    context 'with ad-hoc build type' do
      it 'fetches and configures with IOS_APP_ADHOC profile' do
        adhoc_profile_data = profile_response[:data][0].dup
        adhoc_profile_data['profile_type'] = 'IOS_APP_ADHOC'
        adhoc_profile_data['name'] = 'Ad Hoc Profile'

        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{org_id}/profiles/match",
          params: {
            bundle_id: bundle_id,
            type: 'adhoc'
          }
        ).and_return({ profile: adhoc_profile_data })

        result = configurator.configure!(target_name, configuration, build_type: :adhoc)

        expect(result['name']).to eq('Ad Hoc Profile')
      end
    end

    context 'with development build type' do
      it 'fetches and configures with IOS_APP_DEVELOPMENT profile' do
        dev_profile_data = profile_response[:data][0].dup
        dev_profile_data['profile_type'] = 'IOS_APP_DEVELOPMENT'
        dev_profile_data['name'] = 'Development Profile'

        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{org_id}/profiles/match",
          params: {
            bundle_id: bundle_id,
            type: 'development'
          }
        ).and_return({ profile: dev_profile_data })

        result = configurator.configure!(target_name, configuration, build_type: :development)

        expect(result['name']).to eq('Development Profile')
      end
    end

    context 'when no matching profile found' do
      it 'raises helpful error' do
        # /match endpoint fails
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{org_id}/profiles/match",
          params: { bundle_id: bundle_id, type: 'appstore' }
        ).and_raise(Mysigner::NotFoundError.new('Not found'))

        # Fallback to /profiles also fails
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{org_id}/profiles",
          params: { bundle_id: bundle_id, type: 'APPSTORE', state: 'ACTIVE' }
        ).and_raise(Mysigner::NotFoundError.new('Not found'))

        expect do
          configurator.configure!(target_name, configuration, build_type: :appstore)
        end.to raise_error(Mysigner::NotFoundError, /Not found/)
      end
    end

    context 'when no profiles exist for bundle ID' do
      it 'raises helpful error' do
        # /match endpoint returns no profile
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{org_id}/profiles/match",
          params: { bundle_id: bundle_id, type: 'appstore' }
        ).and_raise(Mysigner::NotFoundError.new('Not found'))

        # Fallback to /profiles returns empty
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{org_id}/profiles",
          params: { bundle_id: bundle_id, type: 'APPSTORE', state: 'ACTIVE' }
        ).and_return({ profiles: [] })

        expect do
          configurator.configure!(target_name, configuration, build_type: :appstore)
        end.to raise_error(
          Mysigner::Build::Configurator::ProfileNotFoundError,
          /No active appstore profile found.*#{bundle_id}/
        )
      end
    end
  end
end
