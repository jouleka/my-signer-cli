# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner switch', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:current_org_id) { '123' }

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
        data: { 'organizations' => [] } 
      })
    end

    it 'shows error message' do
      output = capture_stdout { cli.switch }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.switch }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.switch
    end
  end

  describe 'when user has only one organization' do
    let(:current_org_response) {
      {
        data: {
          'id' => current_org_id,
          'name' => 'Only Organization'
        }
      }
    }

    let(:orgs_response) {
      {
        data: {
          'organizations' => [
            {
              'id' => current_org_id,
              'name' => 'Only Organization',
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
      allow(config).to receive(:organization_id).and_return(current_org_id)
      allow(client).to receive(:get).with("/api/v1/organizations/#{current_org_id}").and_return(current_org_response)
      allow(client).to receive(:get).with('/api/v1/organizations').and_return(orgs_response)
    end

    it 'shows switch header' do
      output = capture_stdout { cli.switch }
      expect(output).to include('Switch Organization')
    end

    it 'shows current organization' do
      output = capture_stdout { cli.switch }
      expect(output).to include('Current organization:')
      expect(output).to include('Only Organization')
      expect(output).to include("ID: #{current_org_id}")
    end

    it 'shows message that nothing to switch to' do
      output = capture_stdout { cli.switch }
      expect(output).to include('You only have access to one organization')
      expect(output).to include('Nothing to switch to')
    end

    it 'does not prompt for selection' do
      expect(cli).not_to receive(:ask)
      cli.switch
    end

    it 'does not update config' do
      expect(config).not_to receive(:organization_id=)
      expect(config).not_to receive(:save)
      cli.switch
    end

    it 'does not exit with error' do
      expect(cli).not_to receive(:exit).with(1)
      cli.switch
    end
  end

  describe 'when user has multiple organizations' do
    let(:current_org_response) {
      {
        data: {
          'id' => '123',
          'name' => 'Current Org'
        }
      }
    }

    let(:orgs_response) {
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
      allow(client).to receive(:get).with("/api/v1/organizations/123").and_return(current_org_response)
      allow(client).to receive(:get).with('/api/v1/organizations').and_return(orgs_response)
    end

    it 'shows switch header' do
      allow(cli).to receive(:ask).and_return('2')
      allow(config).to receive(:organization_id=)
      allow(config).to receive(:save)
      
      output = capture_stdout { cli.switch }
      expect(output).to include('Switch Organization')
    end

    it 'shows current organization' do
      allow(cli).to receive(:ask).and_return('2')
      allow(config).to receive(:organization_id=)
      allow(config).to receive(:save)
      
      output = capture_stdout { cli.switch }
      expect(output).to include('Current organization:')
      expect(output).to include('Current Org (ID: 123)')
    end

    it 'shows all available organizations' do
      allow(cli).to receive(:ask).and_return('2')
      allow(config).to receive(:organization_id=)
      allow(config).to receive(:save)
      
      output = capture_stdout { cli.switch }
      expect(output).to include('Available organizations:')
      expect(output).to include('1. Current Org (current) (admin)')
      expect(output).to include('2. Another Org (developer)')
      expect(output).to include('3. Third Org (owner)')
    end

    it 'marks current organization' do
      allow(cli).to receive(:ask).and_return('2')
      allow(config).to receive(:organization_id=)
      allow(config).to receive(:save)
      
      output = capture_stdout { cli.switch }
      expect(output).to include('Current Org (current)')
      expect(output).not_to include('Another Org (current)')
      expect(output).not_to include('Third Org (current)')
    end

    it 'prompts for selection' do
      allow(config).to receive(:organization_id=)
      allow(config).to receive(:save)
      
      expect(cli).to receive(:ask).with("Select organization (1-3):", limited_to: ['1', '2', '3']).and_return('2')
      cli.switch
    end

    context 'when user selects current organization' do
      before do
        allow(cli).to receive(:ask).and_return('1') # Current Org
      end

      it 'shows already using message' do
        output = capture_stdout { cli.switch }
        expect(output).to include('Already using this organization')
      end

      it 'does not update config' do
        expect(config).not_to receive(:organization_id=)
        expect(config).not_to receive(:save)
        cli.switch
      end
    end

    context 'when user selects different organization' do
      before do
        allow(cli).to receive(:ask).and_return('2') # Another Org (456)
        allow(config).to receive(:organization_id=)
        allow(config).to receive(:save)
      end

      it 'updates organization ID' do
        expect(config).to receive(:organization_id=).with('456')
        cli.switch
      end

      it 'saves config' do
        expect(config).to receive(:save)
        cli.switch
      end

      it 'shows success message' do
        output = capture_stdout { cli.switch }
        expect(output).to include('Successfully switched')
        expect(output).to include('New organization: Another Org')
      end

      it 'shows verification tip' do
        output = capture_stdout { cli.switch }
        expect(output).to include('mysigner status')
      end
    end

    context 'when organization has no role' do
      before do
        orgs_response[:data]['organizations'][1].delete('role')
        allow(cli).to receive(:ask).and_return('2')
        allow(config).to receive(:organization_id=)
        allow(config).to receive(:save)
      end

      it 'defaults to viewer' do
        output = capture_stdout { cli.switch }
        expect(output).to include('2. Another Org (viewer)')
      end
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

    context 'when fetching current org fails' do
      before do
        allow(client).to receive(:get).with('/api/v1/organizations/123').and_raise(
          Mysigner::ClientError.new('Organization not found')
        )
      end

      it 'shows error message' do
        output = capture_stdout { cli.switch }
        expect(output).to include('Failed to switch organization')
        expect(output).to include('Organization not found')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.switch
      end
    end

    context 'when fetching organizations list fails' do
      let(:current_org_response) {
        {
          data: {
            'id' => '123',
            'name' => 'Current Org'
          }
        }
      }

      before do
        allow(client).to receive(:get).with('/api/v1/organizations/123').and_return(current_org_response)
        allow(client).to receive(:get).with('/api/v1/organizations').and_raise(
          Mysigner::ClientError.new('Failed to fetch organizations')
        )
      end

      it 'shows error message' do
        output = capture_stdout { cli.switch }
        expect(output).to include('Failed to switch organization')
        expect(output).to include('Failed to fetch organizations')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.switch
      end
    end

    context 'when connection fails' do
      before do
        allow(client).to receive(:get).and_raise(
          Mysigner::ClientError.new('Connection failed')
        )
      end

      it 'shows error message' do
        output = capture_stdout { cli.switch }
        expect(output).to include('Failed to switch organization')
        expect(output).to include('Connection failed')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.switch
      end
    end

    context 'when token is invalid (401)' do
      before do
        allow(client).to receive(:get).and_raise(
          Mysigner::UnauthorizedError.new('Invalid token')
        )
      end

      it 'shows error message' do
        output = capture_stdout { cli.switch }
        expect(output).to include('Failed to switch organization')
        expect(output).to include('Invalid token')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.switch
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'switch']) }
      expect(help_output).to include('Switch to a different organization')
    end

    it 'has long description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'switch']) }
      expect(help_output).to include('without logging out')
      expect(help_output).to include('current organization')
      expect(help_output).to include('available')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)
      
      output = capture_stdout { Mysigner::CLI.start(['switch']) }
      expect(output).to include('Not logged in')
    end
  end
end

