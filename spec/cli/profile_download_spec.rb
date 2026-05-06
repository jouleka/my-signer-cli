# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner profile download', type: :cli do
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
      allow(Faraday).to receive(:new).and_return(double('connection',
                                                        get: double('response', success?: false, status: 404,
                                                                                headers: {}, body: '')))
      cli.options = {}
    end

    it 'shows error message' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('download', profile_id)
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
      allow(Faraday).to receive(:new).and_return(double('connection',
                                                        get: double('response', success?: false, status: 404,
                                                                                headers: {}, body: '')))
      cli.options = {}
    end

    it 'shows usage message' do
      output = capture_stdout { cli.profile('download') }
      expect(output).to include('Usage: mysigner profile download ID')
    end

    it 'shows output option' do
      output = capture_stdout { cli.profile('download') }
      expect(output).to include('--output')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('download')
    end
  end

  describe 'successful download with default filename' do
    let(:profile_response) do
      {
        data: {
          'id' => profile_id,
          'name' => 'iOS App Store Profile',
          'profile_type' => 'APP_STORE',
          'bundle_id_identifier' => 'com.example.app',
          'state' => 'ACTIVE'
        }
      }
    end
    let(:profile_content) { 'binary profile content' }
    let(:faraday_response) { double('response', success?: true, body: profile_content, headers: {}) }
    let(:faraday_conn) { double('connection') }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}").and_return(profile_response)

      # Mock Faraday connection
      request_options = double('options')
      allow(request_options).to receive(:timeout=)
      allow(request_options).to receive(:open_timeout=)
      request = double('request', options: request_options)

      allow(Faraday).to receive(:new).and_return(faraday_conn)
      allow(faraday_conn).to receive(:get).and_yield(request).and_return(faraday_response)

      # Mock File write
      allow(File).to receive(:binwrite)

      cli.options = {}
    end

    it 'shows downloading message' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('Downloading profile')
    end

    it 'fetches profile details' do
      expect(client).to receive(:get).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}")
      cli.profile('download', profile_id)
    end

    it 'downloads profile content' do
      expect(faraday_conn).to receive(:get).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}/download")
      cli.profile('download', profile_id)
    end

    it 'saves to default filename' do
      expected_path = File.join(File.expand_path('~/Downloads'), 'iOS_App_Store_Profile.mobileprovision')
      expect(File).to receive(:binwrite).with(expected_path, profile_content)
      cli.profile('download', profile_id)
    end

    it 'shows success message' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('Profile downloaded successfully')
    end

    it 'shows profile details' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('Details:')
      expect(output).to include('Name:')
      expect(output).to include('iOS App Store Profile')
      expect(output).to include('Type:')
      expect(output).to include('APP_STORE')
      expect(output).to include('Bundle ID:')
      expect(output).to include('com.example.app')
      expect(output).to include('Status:')
      expect(output).to include('ACTIVE')
    end

    it 'shows file path' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('File:')
      expect(output).to include('iOS_App_Store_Profile.mobileprovision')
    end

    it 'shows file size' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('File size:')
      expect(output).to include('bytes')
    end
  end

  describe 'successful download with custom output path' do
    let(:profile_response) do
      {
        data: {
          'id' => profile_id,
          'name' => 'iOS App Store Profile',
          'profile_type' => 'APP_STORE',
          'bundle_id_identifier' => 'com.example.app',
          'state' => 'ACTIVE'
        }
      }
    end
    let(:profile_content) { 'binary profile content' }
    let(:faraday_response) { double('response', success?: true, body: profile_content, headers: {}) }
    let(:faraday_conn) { double('connection') }
    let(:custom_path) { '/custom/path/myprofile.mobileprovision' }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}").and_return(profile_response)

      request_options = double('options')
      allow(request_options).to receive(:timeout=)
      allow(request_options).to receive(:open_timeout=)
      request = double('request', options: request_options)

      allow(Faraday).to receive(:new).and_return(faraday_conn)
      allow(faraday_conn).to receive(:get).and_yield(request).and_return(faraday_response)
      allow(File).to receive(:binwrite)

      cli.options = { output: custom_path }
    end

    it 'saves to custom path' do
      expect(File).to receive(:binwrite).with(custom_path, profile_content)
      cli.profile('download', profile_id)
    end

    it 'shows custom path in output' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include(custom_path)
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
      cli.options = {}
    end

    it 'shows error message' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('Profile not found')
      expect(output).to include(profile_id)
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('download', profile_id)
    end
  end

  describe 'when download fails' do
    let(:profile_response) do
      {
        data: {
          'id' => profile_id,
          'name' => 'iOS App Store Profile',
          'profile_type' => 'APP_STORE',
          'bundle_id_identifier' => 'com.example.app',
          'state' => 'ACTIVE'
        }
      }
    end
    let(:faraday_response) { double('response', success?: false, status: 500, headers: {}, body: 'Server error') }
    let(:faraday_conn) { double('connection') }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}").and_return(profile_response)

      request_options = double('options')
      allow(request_options).to receive(:timeout=)
      allow(request_options).to receive(:open_timeout=)
      request = double('request', options: request_options)

      allow(Faraday).to receive(:new).and_return(faraday_conn)
      allow(faraday_conn).to receive(:get).and_yield(request).and_return(faraday_response)

      cli.options = {}
    end

    it 'shows download error' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('Download failed')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('download', profile_id)
    end
  end

  describe 'when file write fails' do
    let(:profile_response) do
      {
        data: {
          'id' => profile_id,
          'name' => 'iOS App Store Profile',
          'profile_type' => 'APP_STORE',
          'bundle_id_identifier' => 'com.example.app',
          'state' => 'ACTIVE'
        }
      }
    end
    let(:profile_content) { 'binary profile content' }
    let(:faraday_response) { double('response', success?: true, body: profile_content, headers: {}) }
    let(:faraday_conn) { double('connection') }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/profiles/#{profile_id}").and_return(profile_response)

      request_options = double('options')
      allow(request_options).to receive(:timeout=)
      allow(request_options).to receive(:open_timeout=)
      request = double('request', options: request_options)

      allow(Faraday).to receive(:new).and_return(faraday_conn)
      allow(faraday_conn).to receive(:get).and_yield(request).and_return(faraday_response)
      allow(File).to receive(:binwrite).and_raise(StandardError.new('Permission denied'))

      cli.options = {}
    end

    it 'shows file save error' do
      output = capture_stdout { cli.profile('download', profile_id) }
      expect(output).to include('Failed to save file')
      expect(output).to include('Permission denied')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('download', profile_id)
    end
  end

  describe 'when unknown action provided' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
    end

    it 'shows unknown action error' do
      output = capture_stdout { cli.profile('upload', profile_id) }
      expect(output).to include('Unknown action: upload')
    end

    it 'shows available actions' do
      output = capture_stdout { cli.profile('upload', profile_id) }
      expect(output).to include('Available actions: download, delete')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profile('upload', profile_id)
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

    it 'shows output option' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help profile]) }
      expect(help_output).to include('--output')
    end
  end

  describe 'integration tests', :integration do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['profile', 'download', profile_id]) }
      expect(output).to include('Not logged in')
    end
  end
end
