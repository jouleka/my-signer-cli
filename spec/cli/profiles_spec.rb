# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner profiles', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://api.mysigner.app' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }

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
      # Stub to prevent errors if execution continues
      allow(client).to receive(:get).and_return({
        data: {
          'profiles' => [],
          'pagination' => { 'page' => 1, 'per_page' => 50, 'total_pages' => 0, 'total' => 0 }
        }
      })
    end

    it 'shows error message' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profiles
    end
  end

  describe 'when no profiles found' do
    let(:empty_response) {
      {
        data: {
          'profiles' => [],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 0,
            'total' => 0
          }
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_return(empty_response)
      
      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows header' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Provisioning Profiles')
    end

    it 'shows no profiles message' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('No profiles found')
    end

    it 'shows helpful tip' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('created automatically when you request code signing')
    end

    it 'does not exit with error' do
      expect(cli).not_to receive(:exit)
      cli.profiles
    end
  end

  describe 'list profiles' do
    let(:profiles_response) {
      {
        data: {
          'profiles' => [
            {
              'id' => 'prof_1',
              'name' => 'iOS App Store Profile',
              'profile_type' => 'APP_STORE',
              'bundle_id' => 'com.example.app',
              'status' => 'ACTIVE',
              'expires_at' => '2025-12-31T23:59:59Z'
            },
            {
              'id' => 'prof_2',
              'name' => 'iOS Development Profile',
              'profile_type' => 'DEVELOPMENT',
              'bundle_id' => 'com.example.app',
              'status' => 'EXPIRED',
              'expires_at' => '2024-01-01T00:00:00Z'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 1,
            'total' => 2
          }
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_return(profiles_response)
      
      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows header' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Provisioning Profiles')
    end

    it 'fetches profiles from API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/profiles",
        params: { page: 1, per_page: 50 }
      )
      cli.profiles
    end

    it 'shows profile names' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('iOS App Store Profile')
      expect(output).to include('iOS Development Profile')
    end

    it 'shows profile IDs' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('prof_1')
      expect(output).to include('prof_2')
    end

    it 'shows profile types' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Type: APP_STORE')
      expect(output).to include('Type: DEVELOPMENT')
    end

    it 'shows bundle IDs' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Bundle ID: com.example.app')
    end

    it 'shows profile status' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Status: ACTIVE')
      expect(output).to include('Status: EXPIRED')
    end

    it 'shows expiration dates' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Expires: 2025-12-31')
      expect(output).to include('Expires: 2024-01-01')
    end

    it 'shows active status with checkmark' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('✓ iOS App Store Profile')
    end

    it 'shows expired status with X' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('✗ iOS Development Profile')
    end

    it 'shows pagination info' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Page 1 of 1')
      expect(output).to include('2 total')
    end

    it 'does not show next page hint when on last page' do
      output = capture_stdout { cli.profiles }
      expect(output).not_to include('to see more')
    end
  end

  describe 'with type filter' do
    let(:profiles_response) {
      {
        data: {
          'profiles' => [
            {
              'id' => 'prof_1',
              'name' => 'App Store Profile',
              'profile_type' => 'APP_STORE',
              'bundle_id' => 'com.example.app',
              'status' => 'ACTIVE',
              'expires_at' => '2025-12-31T23:59:59Z'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 1,
            'total' => 1
          }
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_return(profiles_response)
      
      cli.options = { page: 1, per_page: 50, type: 'app_store' }
    end

    it 'sends type filter to API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/profiles",
        params: { page: 1, per_page: 50, type: 'APP_STORE' }
      )
      cli.profiles
    end

    it 'shows filtered profiles' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('App Store Profile')
      expect(output).to include('APP_STORE')
    end
  end

  describe 'with status filter' do
    let(:profiles_response) {
      {
        data: {
          'profiles' => [
            {
              'id' => 'prof_1',
              'name' => 'Active Profile',
              'profile_type' => 'DEVELOPMENT',
              'bundle_id' => 'com.example.app',
              'status' => 'ACTIVE',
              'expires_at' => '2025-12-31T23:59:59Z'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 1,
            'total' => 1
          }
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_return(profiles_response)
      
      cli.options = { page: 1, per_page: 50, status: 'active' }
    end

    it 'sends status filter to API as state parameter' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/profiles",
        params: { page: 1, per_page: 50, state: 'ACTIVE' }
      )
      cli.profiles
    end

    it 'shows only active profiles' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Active Profile')
      expect(output).to include('✓')
    end
  end

  describe 'with search query' do
    let(:profiles_response) {
      {
        data: {
          'profiles' => [
            {
              'id' => 'prof_1',
              'name' => 'Example App Profile',
              'profile_type' => 'DEVELOPMENT',
              'bundle_id' => 'com.example.app',
              'status' => 'ACTIVE',
              'expires_at' => '2025-12-31T23:59:59Z'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 1,
            'total' => 1
          }
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_return(profiles_response)
      
      cli.options = { page: 1, per_page: 50, search: 'Example' }
    end

    it 'sends search query to API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/profiles",
        params: { page: 1, per_page: 50, q: 'Example' }
      )
      cli.profiles
    end

    it 'shows search results' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Example App Profile')
    end
  end

  describe 'with pagination' do
    let(:profiles_response) {
      {
        data: {
          'profiles' => [
            {
              'id' => 'prof_1',
              'name' => 'Profile 1',
              'profile_type' => 'DEVELOPMENT',
              'bundle_id' => 'com.example.app',
              'status' => 'ACTIVE'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 1,
            'total_pages' => 5,
            'total' => 5
          }
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_return(profiles_response)
      
      cli.options = { page: 1, per_page: 1 }
    end

    it 'shows current page number' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Page 1 of 5')
    end

    it 'shows total count' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('5 total')
    end

    it 'shows next page hint when not on last page' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Run with --page 2 to see more')
    end
  end

  describe 'when API fails' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_raise(Mysigner::ClientError.new('Connection failed'))
      
      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows error message' do
      output = capture_stdout { cli.profiles }
      expect(output).to include('Failed to fetch profiles')
      expect(output).to include('Connection failed')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.profiles
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'profiles']) }
      expect(help_output).to include('List provisioning profiles')
    end

    it 'shows type option' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'profiles']) }
      expect(help_output).to include('--type')
    end

    it 'shows status option' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'profiles']) }
      expect(help_output).to include('--status')
    end

    it 'shows search option' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'profiles']) }
      expect(help_output).to include('--search')
    end

    it 'shows pagination options' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'profiles']) }
      expect(help_output).to include('--page')
      expect(help_output).to include('--per-page')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)
      
      output = capture_stdout { Mysigner::CLI.start(['profiles']) }
      expect(output).to include('Not logged in')
    end
  end
end

