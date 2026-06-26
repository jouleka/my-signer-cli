# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'mysigner/credential_resolver'

RSpec.describe 'mysigner status', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:user_email) { 'developer@example.com' }
  let(:org_id) { 'org-123' }
  let(:current_token) { 'sk_test_...xyz' }

  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  rescue SystemExit
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  def stub_logged_in_config(current_organization_id: nil, organization_ids: [], org_name: nil, encrypted: true)
    allow(config).to receive(:exists?).and_return(true)
    allow(config).to receive(:load)
    allow(config).to receive(:api_url).and_return(api_url)
    allow(config).to receive(:api_token).and_return(api_token)
    allow(config).to receive(:user_email).and_return(user_email)
    allow(config).to receive(:encrypted_config?).and_return(encrypted)
    allow(config).to receive(:current_organization_id).and_return(current_organization_id)
    allow(config).to receive(:organization_ids).and_return(organization_ids)
    allow(config).to receive(:org_name).and_return(org_name)
    allow(config).to receive(:display).and_return({ current_token: current_token })
  end

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(Mysigner::Client).to receive(:new).and_return(client)
    # 0.3.1 — keep these specs hermetic against the dev machine's own
    # ~/.mysigner/config.yml. Without this, a developer with
    # `local_only: true` set persistently would see every status example
    # take the local-only branch, breaking the logged-in path tests.
    allow(Mysigner::Config).to receive(:local_only_from_file?).and_return(false)
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
    end

    it 'shows the login guidance' do
      output = capture_stdout { cli.status }

      expect(output).to include("Not logged in. Run 'mysigner login' first.")
    end

    it 'exits with status 1' do
      expect { cli.status }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe 'when logged in without a current organization' do
    before do
      stub_logged_in_config
      allow(client).to receive(:test_connection).and_return(success: true)
    end

    it 'shows configuration and connection details' do
      output = capture_stdout { cli.status }

      expect(output).to include('My Signer Status')
      expect(output).to include("API URL:         #{api_url}")
      expect(output).to include("User:            #{user_email}")
      expect(output).to include('Encryption:      ✓ Enabled')
      expect(output).to include('Status: ✓ Connected')
    end

    it 'describes the at-rest key backend honestly (not vault-grade) on non-macOS' do
      skip 'macOS stores the key in the Keychain' if RbConfig::CONFIG['host_os'] =~ /darwin/i

      output = capture_stdout { cli.status }

      expect(output).to include('Encryption:      ✓ Enabled (local key file')
      expect(output).to include('obfuscation')
    end

    it 'does not show organization details' do
      output = capture_stdout { cli.status }

      expect(output).not_to include('Current Organization:')
      expect(output).not_to include('App Store Connect:')
    end

    it 'does not fetch organization details' do
      expect(client).not_to receive(:get)
      cli.status
    end
  end

  describe 'when logged in with a current organization' do
    let(:org_response) do
      {
        data: {
          'name' => 'Test Organization',
          'role' => 'admin',
          'member_count' => 5,
          'app_store_connect_configured' => true,
          'app_store_connect_team_id' => 'TEAM123'
        }
      }
    end

    before do
      stub_logged_in_config(
        current_organization_id: org_id,
        organization_ids: [org_id],
        org_name: 'Test Organization'
      )
      allow(client).to receive(:test_connection).and_return(success: true)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
    end

    it 'shows organization and App Store Connect details' do
      output = capture_stdout { cli.status }

      expect(output).to include('Current Organization:')
      expect(output).to include('Name:  Test Organization')
      expect(output).to include("ID:    #{org_id}")
      expect(output).to include("Token: #{current_token}")
      expect(output).to include('Role:   admin')
      expect(output).to include('Members: 5')
      expect(output).to include('App Store Connect:')
      expect(output).to include('✓ Configured')
      expect(output).to include('Team ID: TEAM123')
    end

    it 'fetches organization details' do
      expect(client).to receive(:get).with("/api/v1/organizations/#{org_id}")
      cli.status
    end
  end

  describe 'error handling' do
    before do
      stub_logged_in_config(
        current_organization_id: org_id,
        organization_ids: [org_id],
        org_name: 'Test Organization'
      )
    end

    context 'when the token is invalid' do
      before do
        allow(client).to receive(:test_connection).and_raise(Mysigner::UnauthorizedError.new('Unauthorized: Invalid token'))
      end

      it 'shows the unauthorized status' do
        output = capture_stdout { cli.status }

        expect(output).to include('Status: ✗ Unauthorized (invalid token)')
      end

      it 'exits with status 1' do
        expect { cli.status }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end
    end

    context 'when the API connection fails' do
      before do
        allow(client).to receive(:test_connection).and_raise(Mysigner::ConnectionError.new('Failed to connect to API'))
      end

      it 'shows the connection failure' do
        output = capture_stdout { cli.status }

        expect(output).to include('Status: ✗ Connection failed')
        expect(output).to include('Error: Failed to connect to API')
      end

      it 'exits with status 1' do
        expect { cli.status }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end
    end

    context 'when organization lookup fails' do
      before do
        allow(client).to receive(:test_connection).and_return(success: true)
        allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_raise(StandardError.new('Organization not found'))
      end

      it 'shows the generic error state' do
        output = capture_stdout { cli.status }

        expect(output).to include('Status: ✗ Error')
        expect(output).to include('Error: Organization not found')
      end

      it 'exits with status 1' do
        expect { cli.status }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end
    end
  end

  describe 'help text' do
    it 'uses the current description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help status]) }

      expect(help_output).to include('Check connection, credentials, and App Store Connect setup')
    end
  end

  describe 'in local-only mode' do
    let(:cli) { Mysigner::CLI.new }

    before do
      ENV.delete('MYSIGNER_LOCAL_ONLY')
      allow(cli).to receive(:options).and_return({ local_only: true })
    end
    after { ENV.delete('MYSIGNER_LOCAL_ONLY') }

    it 'prints the local-mode summary and does not require MySigner login' do
      allow(Mysigner::CredentialResolver).to receive(:resolve_asc)
        .and_raise(Mysigner::CredentialResolver::CredentialNotFoundError, 'none')
      allow(Mysigner::CredentialResolver).to receive(:resolve_play)
        .and_raise(Mysigner::CredentialResolver::CredentialNotFoundError, 'none')
      allow(Mysigner::CredentialResolver).to receive(:resolve_android_keystore)
        .and_raise(Mysigner::CredentialResolver::CredentialNotFoundError, 'none')

      output = capture_stdout { cli.status }

      expect(output).to include('Local-only mode: ENABLED')
      expect(output).to match(/Source:.*(--local-only flag|MYSIGNER_LOCAL_ONLY|config file)/)
      expect(output).not_to include('Not logged in')
      expect(output).to include('Credential discovery:')
      expect(output).to include('ASC keys:')
      expect(output).to include('Play SA-JSON:')
      expect(output).to include('Android keystore:')
    end

    # 0.3.1 — pre-fix, status used `ENV[…] && !empty?` for source
    # attribution, so MYSIGNER_LOCAL_ONLY=0 (falsy per Config.truthy_env?)
    # plus file=true would incorrectly report "Source: env var" instead of
    # "Source: config file". Now the env-source check uses the same
    # truthy parser the cascade uses.
    it 'attributes the source to the config file when env var is set to a falsy value' do
      ENV['MYSIGNER_LOCAL_ONLY'] = '0'
      allow(cli).to receive(:options).and_return({}) # no --local-only flag
      allow(Mysigner::Config).to receive(:local_only_from_file?).and_return(true)
      allow(Mysigner::CredentialResolver).to receive(:resolve_asc)
        .and_raise(Mysigner::CredentialResolver::CredentialNotFoundError, 'none')
      allow(Mysigner::CredentialResolver).to receive(:resolve_play)
        .and_raise(Mysigner::CredentialResolver::CredentialNotFoundError, 'none')
      allow(Mysigner::CredentialResolver).to receive(:resolve_android_keystore)
        .and_raise(Mysigner::CredentialResolver::CredentialNotFoundError, 'none')

      output = capture_stdout { cli.status }

      expect(output).to include('Source: config file')
      expect(output).not_to include('Source: MYSIGNER_LOCAL_ONLY env var')
    end
  end
end
