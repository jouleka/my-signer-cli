# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner status', type: :cli do
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
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(config).to receive(:load) # Stub to prevent errors if execution continues
      allow(config).to receive(:api_url).and_return(nil)
      allow(config).to receive(:api_token).and_return(nil)
      allow(config).to receive(:organization_id).and_return(nil)
      allow(config).to receive(:display).and_return({ api_token: '' })
      allow(client).to receive(:test_connection) # Stub to prevent errors if execution continues
      allow(cli).to receive(:exit) # Stub exit
    end

    it 'shows error message' do
      output = capture_stdout { cli.status }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.status }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.status
    end
  end

  describe 'when logged in without org_id' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(nil)
      allow(config).to receive(:display).and_return({
        api_token: 'sk_test_...xyz'
      })
      allow(client).to receive(:test_connection).and_return({ success: true })
      allow(cli).to receive(:exit) # Stub exit
    end

    it 'shows status header' do
      output = capture_stdout { cli.status }
      expect(output).to include('My Signer Status')
    end

    it 'displays API URL' do
      output = capture_stdout { cli.status }
      expect(output).to include("API URL:         #{api_url}")
    end

    it 'displays masked token' do
      output = capture_stdout { cli.status }
      expect(output).to include('API Token:       sk_test_...xyz')
    end

    it 'shows org_id as not set' do
      output = capture_stdout { cli.status }
      expect(output).to include('Organization ID: (not set)')
    end

    it 'tests connection' do
      expect(client).to receive(:test_connection)
      cli.status
    end

    it 'shows connected status' do
      output = capture_stdout { cli.status }
      expect(output).to include('Status: ✓ Connected')
    end

    it 'does not show organization section' do
      output = capture_stdout { cli.status }
      expect(output).not_to include('Organization:')
    end

    it 'does not fetch organization details' do
      expect(client).not_to receive(:get)
      cli.status
    end
  end

  describe 'when logged in with org_id' do
    let(:org_response) {
      {
        data: {
          'name' => 'Test Organization',
          'role' => 'admin',
          'member_count' => 5
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:display).and_return({
        api_token: 'sk_test_...xyz'
      })
      allow(client).to receive(:test_connection).and_return({ success: true })
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
      allow(cli).to receive(:exit) # Stub exit
    end

    it 'shows status header' do
      output = capture_stdout { cli.status }
      expect(output).to include('My Signer Status')
    end

    it 'displays configuration section' do
      output = capture_stdout { cli.status }
      expect(output).to include('Configuration:')
      expect(output).to include("API URL:         #{api_url}")
      expect(output).to include('API Token:       sk_test_...xyz')
      expect(output).to include("Organization ID: #{org_id}")
    end

    it 'tests connection' do
      expect(client).to receive(:test_connection)
      cli.status
    end

    it 'shows connected status' do
      output = capture_stdout { cli.status }
      expect(output).to include('Status: ✓ Connected')
    end

    it 'fetches organization details' do
      expect(client).to receive(:get).with("/api/v1/organizations/#{org_id}")
      cli.status
    end

    it 'shows organization section' do
      output = capture_stdout { cli.status }
      expect(output).to include('Organization:')
    end

    it 'displays organization name' do
      output = capture_stdout { cli.status }
      expect(output).to include('Name:    Test Organization')
    end

    it 'displays user role' do
      output = capture_stdout { cli.status }
      expect(output).to include('Role:    admin')
    end

    it 'displays member count' do
      output = capture_stdout { cli.status }
      expect(output).to include('Members: 5')
    end

    context 'when org has no role' do
      before do
        org_response[:data]['role'] = nil
      end

      it 'defaults to member' do
        output = capture_stdout { cli.status }
        expect(output).to include('Role:    member')
      end
    end

    context 'when org has no member_count' do
      before do
        org_response[:data]['member_count'] = nil
      end

      it 'defaults to 0' do
        output = capture_stdout { cli.status }
        expect(output).to include('Members: 0')
      end
    end
  end

  describe 'error handling' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:display).and_return({
        api_token: 'sk_test_...xyz'
      })
      allow(cli).to receive(:exit) # Stub exit
    end

    context 'when token is invalid (401)' do
      before do
        allow(client).to receive(:test_connection).and_raise(Mysigner::UnauthorizedError)
      end

      it 'shows unauthorized error' do
        output = capture_stdout { cli.status }
        expect(output).to include('Status: ✗ Unauthorized')
        expect(output).to include('invalid token')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.status
      end

      it 'does not fetch organization details' do
        expect(client).not_to receive(:get)
        cli.status
      end
    end

    context 'when connection fails' do
      before do
        allow(client).to receive(:test_connection).and_raise(
          Mysigner::ConnectionError.new('Failed to connect to API')
        )
      end

      it 'shows connection failed error' do
        output = capture_stdout { cli.status }
        expect(output).to include('Status: ✗ Connection failed')
      end

      it 'shows error message' do
        output = capture_stdout { cli.status }
        expect(output).to include('Error: Failed to connect to API')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.status
      end
    end

    context 'when API returns unexpected error' do
      before do
        allow(client).to receive(:test_connection).and_raise(StandardError.new('Unexpected error'))
      end

      it 'shows generic error' do
        output = capture_stdout { cli.status }
        expect(output).to include('Status: ✗ Error')
      end

      it 'shows error message' do
        output = capture_stdout { cli.status }
        expect(output).to include('Error: Unexpected error')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.status
      end
    end

    context 'when organization fetch fails' do
      before do
        allow(client).to receive(:test_connection).and_return({ success: true })
        allow(client).to receive(:get).and_raise(StandardError.new('Organization not found'))
      end

      it 'shows error' do
        output = capture_stdout { cli.status }
        expect(output).to include('Status: ✗ Error')
      end

      it 'shows error message' do
        output = capture_stdout { cli.status }
        expect(output).to include('Error: Organization not found')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.status
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'status']) }
      expect(help_output).to include('Show connection status and configuration')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)
      
      output = capture_stdout { Mysigner::CLI.start(['status']) }
      expect(output).to include('Not logged in')
    end
  end
end

