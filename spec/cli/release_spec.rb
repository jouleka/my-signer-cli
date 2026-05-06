# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner release', type: :cli do
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
      allow(client).to receive(:get).and_return({ data: { 'app_store_releases' => [] } })
    end

    it 'shows error message' do
      output = capture_stdout { cli.release('list') }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.release('list') }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.release('list')
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

    describe 'release list' do
      context 'when releases exist' do
        let(:releases) do
          [
            {
              'id' => 1,
              'bundle_identifier' => 'com.example.app',
              'app_name' => 'My App',
              'release_type' => 'after_approval',
              'auto_submit' => true,
              'phased_release' => true,
              'version_string' => '1.2.0'
            },
            {
              'id' => 2,
              'bundle_identifier' => 'com.example.app2',
              'app_name' => 'Other App',
              'release_type' => 'manual',
              'auto_submit' => false,
              'phased_release' => false,
              'version_string' => '2.0.0'
            }
          ]
        end

        before do
          allow(client).to receive(:get).and_return({
                                                      data: { 'app_store_releases' => releases }
                                                    })
        end

        it 'shows header' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('App Store Releases')
        end

        it 'fetches releases from API' do
          expect(client).to receive(:get).with(
            "/api/v1/organizations/#{org_id}/app_store_releases",
            params: {}
          )
          cli.release('list')
        end

        it 'shows app names' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('My App')
          expect(output).to include('Other App')
        end

        it 'shows release IDs' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('ID: 1')
          expect(output).to include('ID: 2')
        end

        it 'shows bundle identifiers' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('Bundle ID: com.example.app')
          expect(output).to include('Bundle ID: com.example.app2')
        end

        it 'shows release type' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('Release Type: after_approval')
          expect(output).to include('Release Type: manual')
        end

        it 'shows auto submit status' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('Auto Submit: Yes')
          expect(output).to include('Auto Submit: No')
        end

        it 'shows phased release status' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('Phased Release: Yes')
          expect(output).to include('Phased Release: No')
        end

        it 'shows version' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('Version: 1.2.0')
          expect(output).to include('Version: 2.0.0')
        end

        it 'shows total count' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('Total: 2 release(s)')
        end
      end

      context 'with bundle-id filter' do
        before do
          cli.options = { bundle_id: 'com.example.app' }
          allow(client).to receive(:get).and_return({
                                                      data: { 'app_store_releases' => [] }
                                                    })
        end

        it 'sends bundle_id filter to API' do
          expect(client).to receive(:get).with(
            "/api/v1/organizations/#{org_id}/app_store_releases",
            params: { bundle_id: 'com.example.app' }
          )
          cli.release('list')
        end
      end

      context 'when no releases found' do
        before do
          allow(client).to receive(:get).and_return({
                                                      data: { 'app_store_releases' => [] }
                                                    })
        end

        it 'shows no releases message' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('No release configurations found')
        end

        it 'shows helpful hint' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('mysigner release create')
        end

        it 'does not exit with error' do
          expect(cli).not_to receive(:exit)
          cli.release('list')
        end
      end

      context 'when API fails' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::ClientError.new('Connection failed')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.release('list') }
          expect(output).to include('Failed to fetch releases')
          expect(output).to include('Connection failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('list')
        end
      end
    end

    describe 'release show' do
      context 'when release exists' do
        let(:release_response) do
          {
            data: {
              'app_store_release' => {
                'id' => 1,
                'app_name' => 'My App',
                'bundle_identifier' => 'com.example.app',
                'version_string' => '1.2.0',
                'release_type' => 'after_approval',
                'auto_submit' => true,
                'phased_release' => true,
                'whats_new' => 'Bug fixes and improvements',
                'support_url' => 'https://support.example.com',
                'marketing_url' => 'https://example.com',
                'privacy_url' => 'https://example.com/privacy',
                'scheduled_date' => '2025-03-01T10:00:00Z'
              }
            }
          }
        end

        before do
          allow(client).to receive(:get).and_return(release_response)
        end

        it 'shows release header' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('Release Configuration (ID: 1)')
        end

        it 'fetches release from API' do
          expect(client).to receive(:get).with(
            "/api/v1/organizations/#{org_id}/app_store_releases/1"
          )
          cli.release('show', '1')
        end

        it 'shows app name' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('App Name:        My App')
        end

        it 'shows bundle identifier' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('Bundle ID:       com.example.app')
        end

        it 'shows version' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('Version:         1.2.0')
        end

        it 'shows release type' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('Release Type:    after_approval')
        end

        it 'shows auto submit' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('Auto Submit:     Yes')
        end

        it 'shows phased release' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('Phased Release:  Yes')
        end

        it "shows what's new" do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include("What's New:")
          expect(output).to include('Bug fixes and improvements')
        end

        it 'shows URLs' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('Support:    https://support.example.com')
          expect(output).to include('Marketing:  https://example.com')
          expect(output).to include('Privacy:    https://example.com/privacy')
        end

        it 'shows scheduled date' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('Scheduled Date: 2025-03-01T10:00:00Z')
        end
      end

      context 'when ID is missing' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::NotFoundError.new('Not found')
          )
        end

        it 'shows usage error' do
          output = capture_stdout { cli.release('show') }
          expect(output).to include('Usage: mysigner release show ID')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('show')
        end
      end

      context 'when release not found' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::NotFoundError.new('Not found')
          )
        end

        it 'shows not found error' do
          output = capture_stdout { cli.release('show', '999') }
          expect(output).to include('Release not found')
        end

        it 'shows hint to list releases' do
          output = capture_stdout { cli.release('show', '999') }
          expect(output).to include('mysigner release list')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('show', '999')
        end
      end

      context 'when API fails' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::ClientError.new('Server error')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.release('show', '1') }
          expect(output).to include('Failed to fetch release')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('show', '1')
        end
      end
    end

    describe 'release create' do
      context 'when successful' do
        let(:create_response) do
          {
            data: {
              'app_store_release' => {
                'id' => 1,
                'bundle_identifier' => 'com.example.app',
                'release_type' => 'after_approval',
                'auto_submit' => true,
                'phased_release' => true
              }
            }
          }
        end

        before do
          cli.options = { bundle_id_id: 42, auto_submit: true, phased_release: true }
          allow(client).to receive(:post).and_return(create_response)
        end

        it 'shows creating message' do
          output = capture_stdout { cli.release('create') }
          expect(output).to include('Creating release configuration')
        end

        it 'calls create API' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/app_store_releases",
            body: { bundle_id_id: 42, auto_submit: true, phased_release: true }
          )
          cli.release('create')
        end

        it 'shows success message' do
          output = capture_stdout { cli.release('create') }
          expect(output).to include('Release configuration created')
        end

        it 'shows release details' do
          output = capture_stdout { cli.release('create') }
          expect(output).to include('ID:')
          expect(output).to include('Auto Submit:    Yes')
          expect(output).to include('Phased Release: Yes')
        end
      end

      context 'when conflict (409 - already exists)' do
        before do
          cli.options = { bundle_id_id: 42 }
          allow(client).to receive(:post).and_raise(
            Mysigner::ValidationError.new('Release already exists for this bundle ID')
          )
        end

        it 'shows conflict message' do
          output = capture_stdout { cli.release('create') }
          expect(output).to include('already exists')
        end

        it 'suggests update command' do
          output = capture_stdout { cli.release('create') }
          expect(output).to include('mysigner release update')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('create')
        end
      end

      context 'when validation error' do
        before do
          cli.options = { bundle_id_id: 42 }
          allow(client).to receive(:post).and_raise(
            Mysigner::ValidationError.new('Invalid parameters', { 'release_type' => ['is not included in the list'] })
          )
        end

        it 'shows validation error' do
          output = capture_stdout { cli.release('create') }
          expect(output).to include('Validation failed')
        end

        it 'shows field errors' do
          output = capture_stdout { cli.release('create') }
          expect(output).to include('release_type')
          expect(output).to include('is not included in the list')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('create')
        end
      end

      context 'when API error with 409' do
        before do
          cli.options = { bundle_id_id: 42 }
          allow(client).to receive(:post).and_raise(
            Mysigner::ClientError.new('409 Conflict: already exists')
          )
        end

        it 'shows conflict message' do
          output = capture_stdout { cli.release('create') }
          expect(output).to include('already exists')
        end

        it 'suggests update and list' do
          output = capture_stdout { cli.release('create') }
          expect(output).to include('mysigner release update')
          expect(output).to include('mysigner release list')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('create')
        end
      end
    end

    describe 'release update' do
      context 'when successful' do
        let(:update_response) do
          {
            data: {
              'app_store_release' => {
                'id' => 1,
                'bundle_identifier' => 'com.example.app',
                'release_type' => 'after_approval',
                'auto_submit' => true,
                'phased_release' => false
              }
            }
          }
        end

        before do
          cli.options = { whats_new: 'New features', auto_submit: true }
          allow(client).to receive(:patch).and_return(update_response)
        end

        it 'shows updating message' do
          output = capture_stdout { cli.release('update', '1') }
          expect(output).to include('Updating release configuration')
        end

        it 'calls update API with only provided fields' do
          expect(client).to receive(:patch).with(
            "/api/v1/organizations/#{org_id}/app_store_releases/1",
            body: { whats_new: 'New features', auto_submit: true }
          )
          cli.release('update', '1')
        end

        it 'shows success message' do
          output = capture_stdout { cli.release('update', '1') }
          expect(output).to include('Release configuration updated')
        end

        it 'shows updated details' do
          output = capture_stdout { cli.release('update', '1') }
          expect(output).to include('ID:')
          expect(output).to include('Auto Submit:    Yes')
        end
      end

      context 'when ID is missing' do
        before do
          allow(client).to receive(:patch).and_raise(
            Mysigner::NotFoundError.new('Not found')
          )
        end

        it 'shows usage error' do
          output = capture_stdout { cli.release('update') }
          expect(output).to include('Usage: mysigner release update ID')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('update')
        end
      end

      context 'when release not found' do
        before do
          cli.options = { whats_new: 'Updated' }
          allow(client).to receive(:patch).and_raise(
            Mysigner::NotFoundError.new('Not found')
          )
        end

        it 'shows not found error' do
          output = capture_stdout { cli.release('update', '999') }
          expect(output).to include('Release not found')
        end

        it 'shows hint to list releases' do
          output = capture_stdout { cli.release('update', '999') }
          expect(output).to include('mysigner release list')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('update', '999')
        end
      end

      context 'when validation error' do
        before do
          cli.options = { release_type: 'invalid' }
          allow(client).to receive(:patch).and_raise(
            Mysigner::ValidationError.new('Invalid parameters', { 'release_type' => ['is not included in the list'] })
          )
        end

        it 'shows validation error' do
          output = capture_stdout { cli.release('update', '1') }
          expect(output).to include('Validation failed')
        end

        it 'shows field errors' do
          output = capture_stdout { cli.release('update', '1') }
          expect(output).to include('release_type')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('update', '1')
        end
      end

      context 'when API fails' do
        before do
          cli.options = { whats_new: 'Updated' }
          allow(client).to receive(:patch).and_raise(
            Mysigner::ClientError.new('Server error')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.release('update', '1') }
          expect(output).to include('Failed to update release')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.release('update', '1')
        end
      end
    end

    describe 'unknown action' do
      it 'shows error for unknown action' do
        output = capture_stdout { cli.release('unknown') }
        expect(output).to include('Unknown action')
      end

      it 'shows available actions' do
        output = capture_stdout { cli.release('unknown') }
        expect(output).to include('list')
        expect(output).to include('show')
        expect(output).to include('create')
        expect(output).to include('update')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.release('unknown')
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help release]) }
      expect(help_output).to include('release')
    end
  end

  describe 'integration tests', :integration do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(%w[release list]) }
      expect(output).to include('Not logged in')
    end
  end
end
