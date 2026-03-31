# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'fileutils'
require 'base64'

RSpec.describe Mysigner::CLI do
  let(:test_config_dir) { File.expand_path('~/.mysigner_test_cli') }
  let(:test_config_file) { File.join(test_config_dir, 'config.yml') }

  before do
    # Stub the constants to use test directory
    stub_const('Mysigner::Config::CONFIG_DIR', test_config_dir)
    stub_const('Mysigner::Config::CONFIG_FILE', test_config_file)

    # Clean up test directory
    FileUtils.rm_rf(test_config_dir)
  end

  after do
    # Clean up after tests
    FileUtils.rm_rf(test_config_dir)
  end

  describe '#version' do
    it 'displays the version' do
      output = capture_output { Mysigner::CLI.start(['version']) }
      expect(output).to include("My Signer CLI v#{Mysigner::VERSION}")
    end
  end

  describe '#config' do
    context 'when not logged in' do
      it 'shows error message' do
        expect do
          capture_output { Mysigner::CLI.start(['config']) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token_12345')
        config.save
      end

      it 'displays configuration' do
        output = capture_output { Mysigner::CLI.start(['config']) }

        expect(output).to include('Configuration')
        expect(output).to include('http://localhost:3000')
        expect(output).to include('test...2345') # Masked token
        expect(output).to include('1') # Org ID
      end
    end
  end

  describe '#logout' do
    context 'when not logged in' do
      it 'shows message that no credentials found' do
        output = capture_output { Mysigner::CLI.start(['logout']) }
        expect(output).to include('No stored credentials found')
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save
      end

      it 'confirms before logout' do
        # Simulate 'no' response
        allow_any_instance_of(Mysigner::CLI).to receive(:yes?).and_return(false)

        output = capture_output { Mysigner::CLI.start(['logout']) }
        expect(output).to include('Logout cancelled')
        expect(File.exist?(test_config_file)).to be true
      end

      it 'clears config when confirmed' do
        # Simulate 'yes' response
        allow_any_instance_of(Mysigner::CLI).to receive(:yes?).and_return(true)

        output = capture_output { Mysigner::CLI.start(['logout']) }
        expect(output).to include('Successfully logged out')
        expect(File.exist?(test_config_file)).to be false
      end
    end
  end

  describe '#status' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(['status']) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save

        # Stub API calls
        stub_request(:get, 'http://localhost:3000/api/v1/status')
          .to_return(
            status: 200,
            body: { status: 'ok' }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1')
          .to_return(
            status: 200,
            body: { name: 'Test Org', role: 'owner', member_count: 5 }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'shows connection status and organization details' do
        output = capture_output { Mysigner::CLI.start(['status']) }

        expect(output).to include('My Signer Status')
        expect(output).to include('Configuration:')
        expect(output).to include('http://localhost:3000')
        expect(output).to include('Connected')
        expect(output).to include('Test Org')
        expect(output).to include('owner')
      end
    end

    context 'when connection fails' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save

        stub_request(:get, 'http://localhost:3000/api/v1/status')
          .to_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'shows connection error' do
        expect do
          capture_output { Mysigner::CLI.start(['status']) }
        end.to raise_error(SystemExit)
      end
    end
  end

  describe '#orgs' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(['orgs']) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save

        stub_request(:get, 'http://localhost:3000/api/v1/user/organizations')
          .to_return(
            status: 200,
            body: {
              organizations: [
                { id: 1, name: 'Test Org 1', role: 'owner', member_count: 5 },
                { id: 2, name: 'Test Org 2', role: 'admin', member_count: 3 }
              ]
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'lists all organizations' do
        output = capture_output { Mysigner::CLI.start(['orgs']) }

        expect(output).to include('Organizations')
        expect(output).to include('Test Org')
        expect(output).to include('(current)') # Current org
        expect(output).to include('Test Org 2')
        expect(output).to include('Total: 2 organization(s)')
      end
    end
  end

  describe 'pricing guidance helpers' do
    let(:cli) { Mysigner::CLI.new }

    it 'matches plan upgrade required errors' do
      error_info = cli.send(:find_suggestions_for_error, 'plan_upgrade_required Upgrade required', platform: :ios)

      expect(error_info[:title]).to eq('Plan Upgrade Required')
    end

    it 'shows backend suggestions when rendering enriched errors' do
      error = Mysigner::ForbiddenError.new(
        'Forbidden: Upgrade required',
        error_code: 'plan_upgrade_required',
        suggestion: 'Upgrade to Pro from the pricing page'
      )

      output = capture_output do
        cli.send(:display_error_with_suggestions, error, platform: :ios, context: { title: 'API Error' })
      end

      expect(output).to include('Suggestion: Upgrade to Pro from the pricing page')
      expect(output).to include('Plan Upgrade Required')
    end
  end

  describe '#devices' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(['devices']) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save

        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/devices')
          .with(query: { page: '1', per_page: '50' })
          .to_return(
            status: 200,
            body: {
              devices: [
                {
                  id: 1,
                  name: 'Test iPhone',
                  udid: '00008030-001A1B2C3D4E567F',
                  platform: 'IOS',
                  device_class: 'IPHONE',
                  status: 'ENABLED'
                },
                {
                  id: 2,
                  name: 'Test iPad',
                  udid: '00008110-001B2C3D4E567F80',
                  platform: 'IOS',
                  device_class: 'IPAD',
                  status: 'DISABLED'
                }
              ],
              pagination: {
                page: 1,
                per_page: 50,
                total: 2,
                total_pages: 1
              }
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'lists all devices' do
        output = capture_output { Mysigner::CLI.start(['devices']) }

        expect(output).to include('Devices')
        expect(output).to include('Test iPhone')
        expect(output).to include('Test iPad')
        expect(output).to include('00008030-001A1B2C3D4E567F')
        expect(output).to include('ENABLED')
        expect(output).to include('DISABLED')
      end

      it 'supports platform filter' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/devices')
          .with(query: { page: '1', per_page: '50', platform: 'IOS' })
          .to_return(
            status: 200,
            body: { devices: [], pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        output = capture_output { Mysigner::CLI.start(['devices', '--platform', 'ios']) }
        expect(output).to include('No devices found')
      end

      it 'supports search filter' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/devices')
          .with(query: { page: '1', per_page: '50', q: 'iPhone' })
          .to_return(
            status: 200,
            body: { devices: [], pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        output = capture_output { Mysigner::CLI.start(['devices', '--search', 'iPhone']) }
        expect(output).to include('Devices')
      end

      it 'supports pagination' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/devices')
          .with(query: { page: '2', per_page: '10' })
          .to_return(
            status: 200,
            body: { devices: [], pagination: { page: 2, per_page: 10, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        capture_output { Mysigner::CLI.start(['devices', '--page', '2', '--per-page', '10']) }

        expect(WebMock).to have_requested(:get, 'http://localhost:3000/api/v1/organizations/1/devices')
          .with(query: { page: '2', per_page: '10' })
      end
    end
  end

  describe '#device add' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(%w[device add iPhone 12345]) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save
      end

      it 'registers a new device' do
        stub_request(:post, 'http://localhost:3000/api/v1/organizations/1/devices')
          .with(
            body: {
              name: 'Test iPhone',
              udid: '00008030-001A1B2C3D4E567F',
              platform: 'IOS'
            }.to_json
          )
          .to_return(
            status: 201,
            body: {
              message: 'Device registered successfully',
              device: {
                id: 1,
                name: 'Test iPhone',
                udid: '00008030-001A1B2C3D4E567F',
                platform: 'IOS',
                status: 'ENABLED'
              }
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        output = capture_output { Mysigner::CLI.start(['device', 'add', 'Test iPhone', '00008030-001A1B2C3D4E567F']) }

        expect(output).to include('Device registered successfully')
        expect(output).to include('Test iPhone')
        expect(output).to include('00008030-001A1B2C3D4E567F')
      end

      it 'supports platform option' do
        stub_request(:post, 'http://localhost:3000/api/v1/organizations/1/devices')
          .with(
            body: {
              name: 'Test Mac',
              udid: '12345',
              platform: 'MAC_OS'
            }.to_json
          )
          .to_return(
            status: 201,
            body: {
              device: {
                id: 1,
                name: 'Test Mac',
                udid: '12345',
                platform: 'MAC_OS',
                status: 'ENABLED'
              }
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        capture_output { Mysigner::CLI.start(['device', 'add', 'Test Mac', '12345', '--platform', 'mac_os']) }

        expect(WebMock).to have_requested(:post, 'http://localhost:3000/api/v1/organizations/1/devices')
          .with(body: hash_including('platform' => 'MAC_OS'))
      end

      it 'handles validation errors' do
        stub_request(:post, 'http://localhost:3000/api/v1/organizations/1/devices')
          .to_return(
            status: 422,
            body: {
              error: 'validation_failed',
              message: 'Validation failed',
              details: {
                udid: ['is invalid'],
                name: ["can't be blank"]
              }
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        expect do
          capture_output { Mysigner::CLI.start(['device', 'add', '', 'bad_udid']) }
        end.to raise_error(SystemExit)
      end

      it 'shows error when missing arguments' do
        expect do
          output = capture_output { Mysigner::CLI.start(%w[device add OnlyName]) }
          expect(output).to include('Usage: mysigner device add NAME UDID')
        end.to raise_error(SystemExit)
      end

      it 'shows error for unknown action' do
        expect do
          output = capture_output { Mysigner::CLI.start(%w[device unknown]) }
          expect(output).to include('Unknown action: unknown')
        end.to raise_error(SystemExit)
      end
    end
  end

  describe '#device update' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(['device', 'update', '1', 'New Name']) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save
      end

      it 'updates a device name' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/devices/1')
          .to_return(
            status: 200,
            body: {
              id: 1,
              name: 'Old iPhone Name',
              udid: '00008030-001A1B2C3D4E567F',
              platform: 'IOS',
              status: 'ENABLED'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:patch, 'http://localhost:3000/api/v1/organizations/1/devices/1')
          .with(body: { name: 'New iPhone Name' }.to_json)
          .to_return(
            status: 200,
            body: {
              message: 'Device updated successfully',
              device: {
                id: 1,
                name: 'New iPhone Name',
                udid: '00008030-001A1B2C3D4E567F',
                platform: 'IOS',
                status: 'ENABLED'
              }
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        output = capture_output { Mysigner::CLI.start(['device', 'update', '1', 'New iPhone Name']) }

        expect(output).to include('Device updated successfully')
        expect(output).to include('New iPhone Name')
        expect(output).to include('Old iPhone Name')
      end

      it 'handles not found error' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/devices/999')
          .to_return(
            status: 404,
            body: {
              error: 'not_found',
              message: 'Device not found'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        expect do
          capture_output { Mysigner::CLI.start(['device', 'update', '999', 'New Name']) }
        end.to raise_error(SystemExit)
      end

      it 'shows error when missing arguments' do
        expect do
          output = capture_output { Mysigner::CLI.start(%w[device update 1]) }
          expect(output).to include('Usage: mysigner device update ID NEW_NAME')
        end.to raise_error(SystemExit)
      end
    end
  end

  describe '#profiles' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(['profiles']) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save

        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles')
          .with(query: { page: '1', per_page: '50' })
          .to_return(
            status: 200,
            body: {
              profiles: [
                {
                  id: 1,
                  name: 'iOS Team Provisioning Profile: com.example.app',
                  bundle_id_identifier: 'com.example.app',
                  profile_type: 'DEVELOPMENT',
                  state: 'ACTIVE',
                  expires_at: '2025-12-31T23:59:59Z'
                },
                {
                  id: 2,
                  name: 'AppStore com.example.app',
                  bundle_id_identifier: 'com.example.app',
                  profile_type: 'APP_STORE',
                  state: 'EXPIRED',
                  expires_at: '2024-01-01T00:00:00Z'
                }
              ],
              pagination: {
                page: 1,
                per_page: 50,
                total: 2,
                total_pages: 1
              }
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'lists all profiles' do
        output = capture_output { Mysigner::CLI.start(['profiles']) }

        expect(output).to include('Provisioning Profiles')
        expect(output).to include('iOS Team Provisioning Profile')
        expect(output).to include('AppStore com.example.app')
        expect(output).to include('DEVELOPMENT')
        expect(output).to include('APP_STORE')
        expect(output).to include('ACTIVE')
        expect(output).to include('EXPIRED')
      end

      it 'supports type filter' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles')
          .with(query: { page: '1', per_page: '50', type: 'DEVELOPMENT' })
          .to_return(
            status: 200,
            body: { profiles: [], pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        output = capture_output { Mysigner::CLI.start(['profiles', '--type', 'development']) }
        expect(output).to include('No profiles found')
      end

      it 'supports status filter' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles')
          .with(query: { page: '1', per_page: '50', state: 'ACTIVE' })
          .to_return(
            status: 200,
            body: { profiles: [], pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        capture_output { Mysigner::CLI.start(['profiles', '--status', 'active']) }

        expect(WebMock).to have_requested(:get, 'http://localhost:3000/api/v1/organizations/1/profiles')
          .with(query: { page: '1', per_page: '50', state: 'ACTIVE' })
      end

      it 'supports search filter' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles')
          .with(query: { page: '1', per_page: '50', q: 'example' })
          .to_return(
            status: 200,
            body: { profiles: [], pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        capture_output { Mysigner::CLI.start(['profiles', '--search', 'example']) }

        expect(WebMock).to have_requested(:get, 'http://localhost:3000/api/v1/organizations/1/profiles')
          .with(query: { page: '1', per_page: '50', q: 'example' })
      end

      it 'supports pagination' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles')
          .with(query: { page: '2', per_page: '20' })
          .to_return(
            status: 200,
            body: { profiles: [], pagination: { page: 2, per_page: 20, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        capture_output { Mysigner::CLI.start(['profiles', '--page', '2', '--per-page', '20']) }

        expect(WebMock).to have_requested(:get, 'http://localhost:3000/api/v1/organizations/1/profiles')
          .with(query: { page: '2', per_page: '20' })
      end
    end
  end

  describe '#profile download' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(%w[profile download 1]) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save
      end

      after do
        # Clean up downloaded test files
        FileUtils.rm_f('Test_Profile.mobileprovision')
        FileUtils.rm_f('custom_output.mobileprovision')
      end

      it 'downloads a profile' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles/1')
          .to_return(
            status: 200,
            body: {
              id: 1,
              name: 'Test Profile',
              bundle_id_identifier: 'com.example.app',
              profile_type: 'DEVELOPMENT',
              state: 'ACTIVE'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        # Binary profile content
        test_content = 'test profile content'

        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles/1/download')
          .to_return(
            status: 200,
            body: test_content,
            headers: { 'Content-Type' => 'application/octet-stream' }
          )

        output = capture_output { Mysigner::CLI.start(%w[profile download 1]) }

        expect(output).to include('Profile downloaded successfully')
        expect(output).to include('Test Profile')
        expect(output).to include('Test_Profile.mobileprovision')
        expect(File.exist?('Test_Profile.mobileprovision')).to be true
        expect(File.read('Test_Profile.mobileprovision')).to eq(test_content)
      end

      it 'supports custom output path' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles/1')
          .to_return(
            status: 200,
            body: {
              id: 1,
              name: 'Test Profile',
              bundle_id_identifier: 'com.example.app',
              profile_type: 'DEVELOPMENT',
              state: 'ACTIVE'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        test_content = 'test profile content'

        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles/1/download')
          .to_return(
            status: 200,
            body: test_content,
            headers: { 'Content-Type' => 'application/octet-stream' }
          )

        output = capture_output { Mysigner::CLI.start(['profile', 'download', '1', '--output', 'custom_output.mobileprovision']) }

        expect(output).to include('custom_output.mobileprovision')
        expect(File.exist?('custom_output.mobileprovision')).to be true
        expect(File.read('custom_output.mobileprovision')).to eq(test_content)
      end

      it 'handles not found error' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles/999')
          .to_return(
            status: 404,
            body: {
              error: 'not_found',
              message: 'Profile not found'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        expect do
          output = capture_output { Mysigner::CLI.start(%w[profile download 999]) }
          expect(output).to include('Profile not found')
        end.to raise_error(SystemExit)
      end

      it 'shows error when missing ID' do
        expect do
          output = capture_output { Mysigner::CLI.start(%w[profile download]) }
          expect(output).to include('Usage: mysigner profile download ID')
        end.to raise_error(SystemExit)
      end

      it 'shows error for unknown action' do
        expect do
          output = capture_output { Mysigner::CLI.start(%w[profile unknown]) }
          expect(output).to include('Unknown action: unknown')
        end.to raise_error(SystemExit)
      end
    end
  end

  describe '#profile delete' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(%w[profile delete 1]) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save
      end

      it 'deletes a profile after confirmation' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles/1')
          .to_return(
            status: 200,
            body: {
              id: 1,
              name: 'Test Profile',
              bundle_id_identifier: 'com.example.app',
              profile_type: 'DEVELOPMENT',
              state: 'ACTIVE'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:delete, 'http://localhost:3000/api/v1/organizations/1/profiles/1')
          .to_return(
            status: 200,
            body: { message: 'Profile deleted successfully' }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        allow_any_instance_of(Mysigner::CLI).to receive(:yes?).and_return(true)

        output = capture_output { Mysigner::CLI.start(%w[profile delete 1]) }

        expect(output).to include('Profile deleted successfully')
        expect(output).to include('Test Profile')
      end

      it 'cancels deletion when user says no' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles/1')
          .to_return(
            status: 200,
            body: {
              id: 1,
              name: 'Test Profile',
              bundle_id_identifier: 'com.example.app',
              profile_type: 'DEVELOPMENT',
              state: 'ACTIVE'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        allow_any_instance_of(Mysigner::CLI).to receive(:yes?).and_return(false)

        output = capture_output { Mysigner::CLI.start(%w[profile delete 1]) }

        expect(output).to include('Deletion cancelled')
      end

      it 'handles not found error' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/profiles/999')
          .to_return(
            status: 404,
            body: {
              error: 'not_found',
              message: 'Profile not found'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        expect do
          capture_output { Mysigner::CLI.start(%w[profile delete 999]) }
        end.to raise_error(SystemExit)
      end

      it 'shows error when missing ID' do
        expect do
          output = capture_output { Mysigner::CLI.start(%w[profile delete]) }
          expect(output).to include('Usage: mysigner profile delete ID')
        end.to raise_error(SystemExit)
      end
    end
  end

  describe '#certificates' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(['certificates']) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save

        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates')
          .with(query: { page: '1', per_page: '50' })
          .to_return(
            status: 200,
            body: {
              certificates: [
                {
                  id: 1,
                  name: 'iOS Development Certificate',
                  certificate_type: 'IOS_DEVELOPMENT',
                  serial_number: '1234567890',
                  status: 'ACTIVE',
                  expires_at: '2025-12-31T23:59:59Z'
                },
                {
                  id: 2,
                  name: 'iOS Distribution Certificate',
                  certificate_type: 'IOS_DISTRIBUTION',
                  serial_number: '0987654321',
                  status: 'EXPIRED',
                  expires_at: '2024-01-01T00:00:00Z'
                }
              ],
              pagination: {
                page: 1,
                per_page: 50,
                total: 2,
                total_pages: 1
              }
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'lists all certificates' do
        output = capture_output { Mysigner::CLI.start(['certificates']) }

        expect(output).to include('Signing Certificates')
        expect(output).to include('iOS Development Certificate')
        expect(output).to include('iOS Distribution Certificate')
        expect(output).to include('ACTIVE')
        expect(output).to include('EXPIRED')
      end

      it 'supports type filter' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates')
          .with(query: { page: '1', per_page: '50', certificate_type: 'DEVELOPMENT' })
          .to_return(
            status: 200,
            body: { certificates: [], pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        output = capture_output { Mysigner::CLI.start(['certificates', '--type', 'development']) }
        expect(output).to include('No certificates found')
      end

      it 'supports status filter' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates')
          .with(query: { page: '1', per_page: '50', status: 'ACTIVE' })
          .to_return(
            status: 200,
            body: { certificates: [], pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        capture_output { Mysigner::CLI.start(['certificates', '--status', 'active']) }

        expect(WebMock).to have_requested(:get, 'http://localhost:3000/api/v1/organizations/1/certificates')
          .with(query: { page: '1', per_page: '50', status: 'ACTIVE' })
      end

      it 'supports search filter' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates')
          .with(query: { page: '1', per_page: '50', q: 'Distribution' })
          .to_return(
            status: 200,
            body: { certificates: [], pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        capture_output { Mysigner::CLI.start(['certificates', '--search', 'Distribution']) }

        expect(WebMock).to have_requested(:get, 'http://localhost:3000/api/v1/organizations/1/certificates')
          .with(query: { page: '1', per_page: '50', q: 'Distribution' })
      end

      it 'supports pagination' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates')
          .with(query: { page: '2', per_page: '20' })
          .to_return(
            status: 200,
            body: { certificates: [], pagination: { page: 2, per_page: 20, total: 0, total_pages: 0 } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        capture_output { Mysigner::CLI.start(['certificates', '--page', '2', '--per-page', '20']) }

        expect(WebMock).to have_requested(:get, 'http://localhost:3000/api/v1/organizations/1/certificates')
          .with(query: { page: '2', per_page: '20' })
      end
    end
  end

  describe '#certificate download' do
    context 'when not logged in' do
      it 'shows error and exits' do
        expect do
          capture_output { Mysigner::CLI.start(%w[certificate download 1]) }
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      before do
        config = Mysigner::Config.new
        config.api_url = 'http://localhost:3000'
        config.user_email = 'test@example.com'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Test Org', 'test_token')
        config.save
      end

      after do
        # Clean up downloaded test files
        FileUtils.rm_f('Test_Certificate.cer')
        FileUtils.rm_f('custom_output.cer')
      end

      it 'downloads a certificate' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates/1')
          .to_return(
            status: 200,
            body: {
              id: 1,
              name: 'Test Certificate',
              certificate_type: 'IOS_DEVELOPMENT',
              serial_number: '1234567890',
              status: 'ACTIVE'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        # Binary certificate content
        test_content = 'test certificate content'

        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates/1/download')
          .to_return(
            status: 200,
            body: test_content,
            headers: { 'Content-Type' => 'application/x-x509-ca-cert' }
          )

        output = capture_output { Mysigner::CLI.start(%w[certificate download 1]) }

        expect(output).to include('Certificate downloaded successfully')
        expect(output).to include('Test Certificate')
        expect(output).to include('Test_Certificate.cer')
        expect(File.exist?('Test_Certificate.cer')).to be true
        expect(File.read('Test_Certificate.cer')).to eq(test_content)
      end

      it 'supports custom output path' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates/1')
          .to_return(
            status: 200,
            body: {
              id: 1,
              name: 'Test Certificate',
              certificate_type: 'IOS_DEVELOPMENT',
              serial_number: '1234567890',
              status: 'ACTIVE'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        test_content = 'test certificate content'

        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates/1/download')
          .to_return(
            status: 200,
            body: test_content,
            headers: { 'Content-Type' => 'application/x-x509-ca-cert' }
          )

        output = capture_output { Mysigner::CLI.start(['certificate', 'download', '1', '--output', 'custom_output.cer']) }

        expect(output).to include('custom_output.cer')
        expect(File.exist?('custom_output.cer')).to be true
        expect(File.read('custom_output.cer')).to eq(test_content)
      end

      it 'handles not found error' do
        stub_request(:get, 'http://localhost:3000/api/v1/organizations/1/certificates/999')
          .to_return(
            status: 404,
            body: {
              error: 'not_found',
              message: 'Certificate not found'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        expect do
          output = capture_output { Mysigner::CLI.start(%w[certificate download 999]) }
          expect(output).to include('Certificate not found')
        end.to raise_error(SystemExit)
      end

      it 'shows error when missing ID' do
        expect do
          output = capture_output { Mysigner::CLI.start(%w[certificate download]) }
          expect(output).to include('Usage: mysigner certificate download ID')
        end.to raise_error(SystemExit)
      end

      it 'shows error for unknown action' do
        expect do
          output = capture_output { Mysigner::CLI.start(%w[certificate unknown]) }
          expect(output).to include('Unknown action: unknown')
        end.to raise_error(SystemExit)
      end
    end
  end

  describe '#build' do
    let(:temp_project_dir) { Dir.mktmpdir }
    let(:project_path) { File.join(temp_project_dir, 'App.xcodeproj') }
    let(:mock_detector) { class_double(Mysigner::Build::Detector) }
    let(:mock_parser) { instance_double(Mysigner::Build::Parser) }
    let(:mock_configurator) { instance_double(Mysigner::Build::Configurator) }
    let(:mock_executor) { instance_double(Mysigner::Build::Executor) }

    before do
      # Set up config
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.user_email = 'test@example.com'
      config.current_organization_id = 5
      config.save_token_for_org(5, 'Test Org', 'test_token_12345')
      config.save

      # Create fake project structure
      FileUtils.mkdir_p(project_path)

      # Stub build modules
      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
                                                                        type: :project,
                                                                        path: project_path
                                                                      })
      allow(Mysigner::Build::Parser).to receive(:new).and_return(mock_parser)
      allow(Mysigner::Build::Configurator).to receive(:new).and_return(mock_configurator)
      allow(Mysigner::Build::Executor).to receive(:new).and_return(mock_executor)

      # Default parser stubs
      mock_target = double('target', name: 'App')
      allow(mock_parser).to receive(:targets).and_return(['App'])
      allow(mock_parser).to receive(:main_target).and_return(mock_target)
      allow(mock_parser).to receive(:bundle_id).and_return('com.example.app')
      allow(mock_parser).to receive(:team_id).and_return('ABCD123456')
      allow(mock_parser).to receive(:code_sign_style).and_return('Automatic')
      allow(mock_parser).to receive(:signing_configured?).and_return(false)

      # New advanced features stubs
      allow(mock_parser).to receive(:product_type).and_return(:app)
      allow(mock_parser).to receive(:target_platform).and_return(:ios)
      allow(mock_parser).to receive(:has_extensions?).and_return(false)
      allow(mock_parser).to receive(:has_multiple_apps?).and_return(false)
      allow(mock_parser).to receive(:app_targets).and_return([mock_target])

      # Default executor stub
      allow(mock_executor).to receive(:build!).and_return('build/App-20251003-182320.xcarchive')
    end

    after do
      FileUtils.rm_rf(temp_project_dir)
    end

    context 'when not logged in' do
      before do
        FileUtils.rm_rf(test_config_dir)
      end

      it 'shows error message' do
        expect do
          Dir.chdir(temp_project_dir) do
            capture_output { Mysigner::CLI.start(['build']) }
          end
        end.to raise_error(SystemExit)
      end
    end

    context 'when logged in' do
      context 'with automatic signing' do
        it 'builds successfully with -allowProvisioningUpdates' do
          expect(mock_executor).to receive(:build!).with(
            'App',
            'Release',
            hash_including(signing_style: 'Automatic')
          )

          Dir.chdir(temp_project_dir) do
            output = capture_output { Mysigner::CLI.start(['build']) }
            expect(output).to include('Using Automatic signing')
            expect(output).to include('✓ Build succeeded!')
          end
        end
      end

      context 'with manual signing already configured' do
        before do
          allow(mock_parser).to receive(:code_sign_style).and_return('Manual')
          allow(mock_parser).to receive(:signing_configured?).and_return(true)
        end

        it 'uses existing manual configuration' do
          expect(mock_configurator).not_to receive(:configure!)
          expect(mock_executor).to receive(:build!).with(
            'App',
            'Release',
            hash_including(signing_style: 'Manual')
          )

          Dir.chdir(temp_project_dir) do
            output = capture_output { Mysigner::CLI.start(['build']) }
            expect(output).to include('Manual signing already configured')
            expect(output).to include('✓ Build succeeded!')
          end
        end
      end

      context 'with manual signing not configured' do
        before do
          allow(mock_parser).to receive(:code_sign_style).and_return('Manual')
          allow(mock_parser).to receive(:signing_configured?).and_return(false)

          stub_request(:get, 'http://localhost:3000/api/v1/organizations/5/profiles')
            .with(query: hash_including(bundle_id: 'com.example.app', type: 'IOS_APP_STORE'))
            .to_return(
              status: 200,
              body: {
                data: [{
                  id: 1,
                  name: 'App Store Profile',
                  profile_type: 'IOS_APP_STORE',
                  bundle_id: 'com.example.app'
                }]
              }.to_json,
              headers: { 'Content-Type' => 'application/json' }
            )
        end

        it 'configures manual signing via API' do
          expect(mock_configurator).to receive(:configure!).and_return({
                                                                         'id' => 1,
                                                                         'name' => 'App Store Profile'
                                                                       })

          Dir.chdir(temp_project_dir) do
            output = capture_output { Mysigner::CLI.start(['build']) }
            expect(output).to include('Configuring manual signing')
            expect(output).to include('✓ Configured with profile: App Store Profile')
          end
        end
      end

      context 'with custom options' do
        it 'supports --configuration flag' do
          expect(mock_executor).to receive(:build!).with(
            'App',
            'Debug',
            anything
          )

          Dir.chdir(temp_project_dir) do
            capture_output { Mysigner::CLI.start(['build', '--configuration', 'Debug']) }
          end
        end

        it 'supports --scheme flag' do
          expect(mock_executor).to receive(:build!).with(
            anything,
            anything,
            hash_including(scheme: 'MyScheme')
          )

          Dir.chdir(temp_project_dir) do
            capture_output { Mysigner::CLI.start(['build', '--scheme', 'MyScheme']) }
          end
        end

        it 'supports --type flag' do
          allow(mock_parser).to receive(:code_sign_style).and_return('Manual')
          allow(mock_parser).to receive(:signing_configured?).and_return(false)

          expect(mock_configurator).to receive(:configure!).with(
            anything,
            anything,
            hash_including(build_type: :adhoc)
          )

          Dir.chdir(temp_project_dir) do
            capture_output { Mysigner::CLI.start(['build', '--type', 'adhoc']) }
          end
        end
      end

      context 'with multiple targets' do
        before do
          allow(mock_parser).to receive(:targets).and_return(%w[App AppTests AppUITests])
        end

        it 'supports --target flag to specify target' do
          expect(mock_executor).to receive(:build!).with(
            'AppTests',
            anything,
            anything
          )

          Dir.chdir(temp_project_dir) do
            capture_output { Mysigner::CLI.start(['build', '--target', 'AppTests']) }
          end
        end
      end

      context 'when no project found' do
        before do
          allow(Mysigner::Build::Detector).to receive(:detect).and_raise(
            Mysigner::Build::Detector::NoProjectError.new('No Xcode project found')
          )
        end

        it 'shows error message' do
          expect do
            Dir.chdir(temp_project_dir) do
              capture_output { Mysigner::CLI.start(['build']) }
            end
          end.to raise_error(Mysigner::Build::Detector::NoProjectError, /No Xcode project found/)
        end
      end

      context 'when build fails' do
        before do
          allow(mock_executor).to receive(:build!).and_raise(
            Mysigner::Error.new('xcodebuild failed with exit code 1')
          )
        end

        it 'shows error message' do
          expect do
            Dir.chdir(temp_project_dir) do
              capture_output { Mysigner::CLI.start(['build']) }
            end
          end.to raise_error(Mysigner::Error, /xcodebuild failed/)
        end
      end
    end
  end

  # Helper method to capture stdout
  def capture_output
    original_stdout = $stdout
    $stdout = StringIO.new
    begin
      yield
      $stdout.string
    ensure
      $stdout = original_stdout
    end
  end
end
