# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner gp-credential', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }

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
    allow(cli).to receive(:exit)
    cli.options = {}
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
      allow(client).to receive(:get).and_return({ data: { 'google_play_credentials' => [] } })
    end

    it 'shows error message' do
      output = capture_stdout { cli.gp_credential('list') }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.gp_credential('list') }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.gp_credential('list')
    end
  end

  describe 'when logged in' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')
    end

    describe 'gp-credential list' do
      context 'when credentials exist' do
        let(:credentials) do
          [
            {
              'id' => 1,
              'name' => 'Production Key',
              'developer_account_id' => 'dev-123',
              'active' => true,
              'last_synced_at' => '2024-01-15T10:30:00Z',
              'last_sync_status' => 'success'
            },
            {
              'id' => 2,
              'name' => 'Staging Key',
              'developer_account_id' => 'dev-456',
              'active' => false,
              'last_synced_at' => '2024-01-14T08:00:00Z',
              'last_sync_status' => 'failed'
            }
          ]
        end

        before do
          allow(client).to receive(:get).and_return({
                                                      data: { 'google_play_credentials' => credentials }
                                                    })
        end

        it 'shows header' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('Google Play Credentials')
        end

        it 'fetches credentials from API' do
          expect(client).to receive(:get).with(
            "/api/v1/organizations/#{org_id}/google_play_credentials"
          )
          cli.gp_credential('list')
        end

        it 'shows credential names' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('Production Key')
          expect(output).to include('Staging Key')
        end

        it 'shows credential IDs' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('ID: 1')
          expect(output).to include('ID: 2')
        end

        it 'shows developer account IDs' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('Developer Account: dev-123')
          expect(output).to include('Developer Account: dev-456')
        end

        it 'shows active status' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('Active: Yes')
          expect(output).to include('Active: No')
        end

        it 'shows active credential with checkmark' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('✓ Production Key')
        end

        it 'shows last synced timestamp' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('Last Synced: 2024-01-15')
        end

        it 'shows sync status with color' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('Sync Status: success')
          expect(output).to include('Sync Status: failed')
        end

        it 'shows total count' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('Total: 2 credential(s)')
        end
      end

      context 'when no credentials found' do
        before do
          allow(client).to receive(:get).and_return({
                                                      data: { 'google_play_credentials' => [] }
                                                    })
        end

        it 'shows no credentials message' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('No Google Play credentials found')
        end

        it 'shows helpful hint' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('mysigner onboard')
        end

        it 'does not exit with error' do
          expect(cli).not_to receive(:exit)
          cli.gp_credential('list')
        end
      end

      context 'when API fails' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::ClientError.new('Connection failed')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.gp_credential('list') }
          expect(output).to include('Failed to fetch credentials')
          expect(output).to include('Connection failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('list')
        end
      end
    end

    describe 'gp-credential delete' do
      context 'when confirmed' do
        before do
          allow(cli).to receive(:yes?).and_return(true)
          allow(client).to receive(:delete)
        end

        it 'shows warning message' do
          output = capture_stdout { cli.gp_credential('delete', '1') }
          expect(output).to include('You are about to delete')
        end

        it 'deletes the credential' do
          expect(client).to receive(:delete).with(
            "/api/v1/organizations/#{org_id}/google_play_credentials/1"
          )
          cli.gp_credential('delete', '1')
        end

        it 'shows success message' do
          output = capture_stdout { cli.gp_credential('delete', '1') }
          expect(output).to include('Google Play credential deleted')
        end
      end

      context 'when cancelled' do
        before do
          allow(cli).to receive(:yes?).and_return(false)
        end

        it 'does not delete' do
          expect(client).not_to receive(:delete)
          cli.gp_credential('delete', '1')
        end

        it 'shows cancellation message' do
          output = capture_stdout { cli.gp_credential('delete', '1') }
          expect(output).to include('Deletion cancelled')
        end
      end

      context 'when ID is missing' do
        before do
          allow(cli).to receive(:yes?).and_return(false)
        end

        it 'shows usage error' do
          output = capture_stdout { cli.gp_credential('delete') }
          expect(output).to include('Usage: mysigner gp-credential delete ID')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('delete')
        end
      end

      context 'when credential not found' do
        before do
          allow(cli).to receive(:yes?).and_return(true)
          allow(client).to receive(:delete).and_raise(
            Mysigner::NotFoundError.new('Not found')
          )
        end

        it 'shows not found error' do
          output = capture_stdout { cli.gp_credential('delete', '999') }
          expect(output).to include('Credential not found')
        end

        it 'shows hint to list credentials' do
          output = capture_stdout { cli.gp_credential('delete', '999') }
          expect(output).to include('mysigner gp-credential list')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('delete', '999')
        end
      end

      context 'when delete fails' do
        before do
          allow(cli).to receive(:yes?).and_return(true)
          allow(client).to receive(:delete).and_raise(
            Mysigner::ClientError.new('Server error')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.gp_credential('delete', '1') }
          expect(output).to include('Delete failed')
          expect(output).to include('Server error')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('delete', '1')
        end
      end
    end

    describe 'gp-credential activate' do
      context 'when credential exists' do
        let(:activate_response) do
          {
            data: {
              'google_play_credential' => {
                'id' => 1,
                'name' => 'Production Key',
                'active' => true
              }
            }
          }
        end

        before do
          allow(client).to receive(:post).and_return(activate_response)
        end

        it 'shows activating message' do
          output = capture_stdout { cli.gp_credential('activate', '1') }
          expect(output).to include('Activating credential')
        end

        it 'activates the credential' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/google_play_credentials/1/activate"
          )
          cli.gp_credential('activate', '1')
        end

        it 'shows success message' do
          output = capture_stdout { cli.gp_credential('activate', '1') }
          expect(output).to include('Credential activated')
        end

        it 'shows which credential is now active' do
          output = capture_stdout { cli.gp_credential('activate', '1') }
          expect(output).to include('Production Key')
          expect(output).to include('active Google Play credential')
        end
      end

      context 'when ID is missing' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::NotFoundError.new('ID required')
          )
        end

        it 'shows usage error' do
          output = capture_stdout { cli.gp_credential('activate') }
          expect(output).to include('Usage: mysigner gp-credential activate ID')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('activate')
        end
      end

      context 'when credential not found' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::NotFoundError.new('Not found')
          )
        end

        it 'shows not found error' do
          output = capture_stdout { cli.gp_credential('activate', '999') }
          expect(output).to include('Credential not found')
        end

        it 'shows hint to list credentials' do
          output = capture_stdout { cli.gp_credential('activate', '999') }
          expect(output).to include('mysigner gp-credential list')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('activate', '999')
        end
      end

      context 'when activation fails' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::ClientError.new('Activation failed')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.gp_credential('activate', '1') }
          expect(output).to include('Activation failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('activate', '1')
        end
      end
    end

    describe 'gp-credential test' do
      context 'when connection succeeds' do
        before do
          allow(client).to receive(:post).and_return({
                                                       data: { 'success' => true }
                                                     })
        end

        it 'shows testing message' do
          output = capture_stdout { cli.gp_credential('test', '1') }
          expect(output).to include('Testing credential connection')
        end

        it 'calls test endpoint' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/google_play_credentials/1/test"
          )
          cli.gp_credential('test', '1')
        end

        it 'shows success message' do
          output = capture_stdout { cli.gp_credential('test', '1') }
          expect(output).to include('Connection successful')
        end

        it 'shows confirmation' do
          output = capture_stdout { cli.gp_credential('test', '1') }
          expect(output).to include('Google Play API is reachable')
        end
      end

      context 'when connection fails' do
        before do
          allow(client).to receive(:post).and_return({
                                                       data: { 'success' => false,
                                                               'error' => 'Invalid service account key' }
                                                     })
        end

        it 'shows failure message' do
          output = capture_stdout { cli.gp_credential('test', '1') }
          expect(output).to include('Connection failed')
        end

        it 'shows error details' do
          output = capture_stdout { cli.gp_credential('test', '1') }
          expect(output).to include('Invalid service account key')
        end

        it 'shows troubleshooting tips' do
          output = capture_stdout { cli.gp_credential('test', '1') }
          expect(output).to include('service account')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('test', '1')
        end
      end

      context 'when ID is missing' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::NotFoundError.new('ID required')
          )
        end

        it 'shows usage error' do
          output = capture_stdout { cli.gp_credential('test') }
          expect(output).to include('Usage: mysigner gp-credential test ID')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('test')
        end
      end

      context 'when credential not found' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::NotFoundError.new('Not found')
          )
        end

        it 'shows not found error' do
          output = capture_stdout { cli.gp_credential('test', '999') }
          expect(output).to include('Credential not found')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('test', '999')
        end
      end

      context 'when API fails' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::ClientError.new('Connection timeout')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.gp_credential('test', '1') }
          expect(output).to include('Test failed')
          expect(output).to include('Connection timeout')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.gp_credential('test', '1')
        end
      end
    end

    describe 'unknown action' do
      it 'shows error for unknown action' do
        output = capture_stdout { cli.gp_credential('unknown') }
        expect(output).to include('Unknown action')
      end

      it 'shows available actions' do
        output = capture_stdout { cli.gp_credential('unknown') }
        expect(output).to include('list')
        expect(output).to include('delete')
        expect(output).to include('activate')
        expect(output).to include('test')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.gp_credential('unknown')
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help gp-credential]) }
      expect(help_output).to include('gp-credential')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(%w[gp-credential list]) }
      expect(output).to include('Not logged in')
    end
  end
end
