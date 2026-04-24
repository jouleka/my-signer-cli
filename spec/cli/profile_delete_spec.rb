# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner profile delete', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }
  let(:profile_id) { 'prof_456' }

  # Helper to capture stdout
  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(Mysigner::Client).to receive(:new).and_return(client)
    allow(cli).to receive(:exit) # Stub exit
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(nil)
      allow(config).to receive(:api_token).and_return(nil)
      allow(config).to receive(:organization_id).and_return('123')
      allow(config).to receive(:current_organization_id).and_return('123')
      allow(config).to receive(:user_email).and_return(nil)
      # Stub to prevent errors if execution continues
      allow(client).to receive(:get).and_return({ data: {} })
      allow(client).to receive(:delete)
      allow(cli).to receive(:yes?).and_return(true)
    end

    it 'shows error message' do
      output = capture_stdout { cli.profile('delete', profile_id) }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.profile('delete', profile_id) }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('delete', profile_id)
    end
  end

  describe 'when no ID provided' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      # Stub to prevent errors if execution continues
      allow(client).to receive(:get).and_return({ data: {} })
      allow(client).to receive(:delete)
      allow(cli).to receive(:yes?).and_return(true)
    end

    it 'shows usage message' do
      output = capture_stdout { cli.profile('delete') }
      expect(output).to include('Usage: mysigner profile delete ID')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('delete')
    end
  end

  describe 'successful deletion with confirmation' do
    let(:profile_response) do
      {
        data: {
          'id' => profile_id,
          'name' => 'iOS App Store Profile',
          'profile_type' => 'APP_STORE',
          'bundle_id_identifier' => 'com.example.app'
        }
      }
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}").and_return(profile_response)
      allow(client).to receive(:delete)
      allow(cli).to receive(:yes?).and_return(true)
    end

    it 'shows deleting message' do
      output = capture_stdout { cli.profile('delete', profile_id) }
      expect(output).to include('Deleting profile')
    end

    it 'fetches profile details' do
      expect(client).to receive(:get).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}")
      cli.profile('delete', profile_id)
    end

    it 'shows profile details for confirmation' do
      output = capture_stdout { cli.profile('delete', profile_id) }
      expect(output).to include('You are about to delete:')
      expect(output).to include('Name: iOS App Store Profile')
      expect(output).to include('Type: APP_STORE')
      expect(output).to include('Bundle ID: com.example.app')
    end

    it 'asks for confirmation' do
      expect(cli).to receive(:yes?).with('Are you sure you want to delete this profile? (y/n)')
      cli.profile('delete', profile_id)
    end

    it 'deletes profile when confirmed' do
      expect(client).to receive(:delete).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}")
      cli.profile('delete', profile_id)
    end

    it 'shows success message' do
      output = capture_stdout { cli.profile('delete', profile_id) }
      expect(output).to include('Profile deleted successfully')
    end

    it 'does not exit with error' do
      expect(cli).not_to receive(:exit)
      cli.profile('delete', profile_id)
    end
  end

  describe 'deletion cancelled by user' do
    let(:profile_response) do
      {
        data: {
          'id' => profile_id,
          'name' => 'iOS App Store Profile',
          'profile_type' => 'APP_STORE',
          'bundle_id_identifier' => 'com.example.app'
        }
      }
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}").and_return(profile_response)
      allow(client).to receive(:delete)
      allow(cli).to receive(:yes?).and_return(false)
    end

    it 'does not delete profile' do
      expect(client).not_to receive(:delete)
      cli.profile('delete', profile_id)
    end

    it 'shows cancellation message' do
      output = capture_stdout { cli.profile('delete', profile_id) }
      expect(output).to include('Deletion cancelled')
    end

    it 'does not show success message' do
      output = capture_stdout { cli.profile('delete', profile_id) }
      expect(output).not_to include('Profile deleted successfully')
    end

    it 'does not exit with error' do
      expect(cli).not_to receive(:exit)
      cli.profile('delete', profile_id)
    end
  end

  describe 'when profile not found' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).and_raise(Mysigner::NotFoundError.new('Not found'))
      allow(cli).to receive(:yes?).and_return(true)
    end

    it 'shows profile not found error' do
      output = capture_stdout { cli.profile('delete', profile_id) }
      expect(output).to include('Profile not found')
      expect(output).to include(profile_id)
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('delete', profile_id)
    end
  end

  describe 'when API fails during deletion' do
    let(:profile_response) do
      {
        data: {
          'id' => profile_id,
          'name' => 'iOS App Store Profile',
          'profile_type' => 'APP_STORE',
          'bundle_id_identifier' => 'com.example.app'
        }
      }
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).and_return(profile_response)
      allow(client).to receive(:delete).and_raise(Mysigner::ClientError.new('Connection timeout'))
      allow(cli).to receive(:yes?).and_return(true)
    end

    it 'shows API error' do
      output = capture_stdout { cli.profile('delete', profile_id) }
      expect(output).to include('Failed to delete profile')
      expect(output).to include('Connection timeout')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('delete', profile_id)
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help profile]) }
      expect(help_output).to include('Manage provisioning profiles')
    end

    it 'shows subcommands' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help profile]) }
      expect(help_output).to include('download')
      expect(help_output).to include('delete')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['profile', 'delete', profile_id]) }
      expect(output).to include('Not logged in')
    end
  end
end
