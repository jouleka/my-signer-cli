# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner orgs', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }

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
      allow(config).to receive(:organization_id).and_return(nil)
      # Stub to prevent errors if execution continues
      allow(client).to receive(:get).and_return({ data: { 'organizations' => [] } })
    end

    it 'shows error message' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.orgs
    end
  end

  describe 'when logged in with no organizations' do
    let(:api_response) {
      {
        data: {
          'organizations' => []
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(nil)
      allow(client).to receive(:get).with('/api/v1/organizations').and_return(api_response)
    end

    it 'shows organizations header' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Organizations')
    end

    it 'shows no organizations message' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('No organizations found')
    end

    it 'does not show total count' do
      output = capture_stdout { cli.orgs }
      expect(output).not_to include('Total:')
    end

    it 'does not show switch tip' do
      output = capture_stdout { cli.orgs }
      expect(output).not_to include('mysigner switch')
    end

    it 'does not exit with error' do
      expect(cli).not_to receive(:exit).with(1)
      cli.orgs
    end
  end

  describe 'when logged in with single organization' do
    let(:api_response) {
      {
        data: {
          'organizations' => [
            {
              'id' => '123',
              'name' => 'Test Organization',
              'role' => 'admin',
              'member_count' => 5
            }
          ]
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return('123')
      allow(client).to receive(:get).with('/api/v1/organizations').and_return(api_response)
    end

    it 'shows organizations header' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Organizations')
    end

    it 'displays organization name' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Test Organization')
    end

    it 'marks as current' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('(current)')
    end

    it 'displays organization ID' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('ID: 123')
    end

    it 'displays role' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Role: admin')
    end

    it 'displays member count' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Members: 5')
    end

    it 'shows total count' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Total: 1 organization(s)')
    end

    it 'shows switch tip' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('mysigner switch')
    end
  end

  describe 'when logged in with multiple organizations' do
    let(:api_response) {
      {
        data: {
          'organizations' => [
            {
              'id' => '123',
              'name' => 'Current Org',
              'role' => 'admin',
              'member_count' => 5
            },
            {
              'id' => '456',
              'name' => 'Another Org',
              'role' => 'developer',
              'member_count' => 10
            },
            {
              'id' => '789',
              'name' => 'Third Org',
              'role' => 'owner',
              'member_count' => 3
            }
          ]
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return('123')
      allow(client).to receive(:get).with('/api/v1/organizations').and_return(api_response)
    end

    it 'displays all organizations' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Current Org')
      expect(output).to include('Another Org')
      expect(output).to include('Third Org')
    end

    it 'marks only the current organization' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Current Org (current)')
      expect(output).to include('Another Org')
      expect(output).not_to include('Another Org (current)')
      expect(output).not_to include('Third Org (current)')
    end

    it 'displays all organization IDs' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('ID: 123')
      expect(output).to include('ID: 456')
      expect(output).to include('ID: 789')
    end

    it 'displays all roles' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Role: admin')
      expect(output).to include('Role: developer')
      expect(output).to include('Role: owner')
    end

    it 'displays all member counts' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Members: 5')
      expect(output).to include('Members: 10')
      expect(output).to include('Members: 3')
    end

    it 'shows correct total count' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Total: 3 organization(s)')
    end

    it 'shows switch tip' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('mysigner switch')
    end
  end

  describe 'when organization has missing fields' do
    let(:api_response) {
      {
        data: {
          'organizations' => [
            {
              'id' => '123',
              'name' => 'Minimal Org'
              # Missing role and member_count
            }
          ]
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return('123')
      allow(client).to receive(:get).with('/api/v1/organizations').and_return(api_response)
    end

    it 'defaults role to viewer' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Role: viewer')
    end

    it 'defaults member_count to 0' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Members: 0')
    end

    it 'still displays the organization' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Minimal Org')
      expect(output).to include('ID: 123')
    end
  end

  describe 'when no organization is currently selected' do
    let(:api_response) {
      {
        data: {
          'organizations' => [
            {
              'id' => '123',
              'name' => 'Org One',
              'role' => 'admin',
              'member_count' => 5
            },
            {
              'id' => '456',
              'name' => 'Org Two',
              'role' => 'developer',
              'member_count' => 3
            }
          ]
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(nil)
      allow(client).to receive(:get).with('/api/v1/organizations').and_return(api_response)
    end

    it 'does not mark any organization as current' do
      output = capture_stdout { cli.orgs }
      expect(output).not_to include('(current)')
    end

    it 'still displays all organizations' do
      output = capture_stdout { cli.orgs }
      expect(output).to include('Org One')
      expect(output).to include('Org Two')
    end
  end

  describe 'error handling' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return('123')
    end

    context 'when API connection fails' do
      before do
        allow(client).to receive(:get).and_raise(Mysigner::ClientError.new('Connection failed'))
      end

      it 'shows error message' do
        output = capture_stdout { cli.orgs }
        expect(output).to include('Failed to fetch organizations')
        expect(output).to include('Connection failed')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.orgs
      end
    end

    context 'when token is invalid (401)' do
      before do
        allow(client).to receive(:get).and_raise(Mysigner::UnauthorizedError.new('Invalid token'))
      end

      it 'shows error message' do
        output = capture_stdout { cli.orgs }
        expect(output).to include('Failed to fetch organizations')
        expect(output).to include('Invalid token')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.orgs
      end
    end

    context 'when API returns unexpected error' do
      before do
        allow(client).to receive(:get).and_raise(Mysigner::ClientError.new('Server error'))
      end

      it 'shows error message' do
        output = capture_stdout { cli.orgs }
        expect(output).to include('Failed to fetch organizations')
        expect(output).to include('Server error')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.orgs
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'orgs']) }
      expect(help_output).to include('List accessible organizations')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)
      
      output = capture_stdout { Mysigner::CLI.start(['orgs']) }
      expect(output).to include('Not logged in')
    end
  end
end

