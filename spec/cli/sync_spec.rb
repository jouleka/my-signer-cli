# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner sync', type: :cli do
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
      allow(client).to receive(:post).and_return({ success: true, data: {} })
    end

    it 'shows error message' do
      output = capture_stdout { cli.sync }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.sync }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.sync
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

    describe 'sync iOS (default)' do
      let(:ios_sync_response) {
        {
          success: true,
          data: {
            'synced_at' => '2026-02-06T10:00:00Z',
            'summary' => {
              'apps' => 5,
              'builds' => 12,
              'certificates' => 3,
              'devices' => 25,
              'profiles' => 8
            }
          }
        }
      }

      before do
        allow(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
          .and_return(ios_sync_response)
      end

      it 'shows syncing message' do
        output = capture_stdout { cli.sync }
        expect(output).to include('Syncing data from App Store Connect')
      end

      it 'calls iOS sync endpoint' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
        cli.sync
      end

      it 'shows success message' do
        output = capture_stdout { cli.sync }
        expect(output).to include('iOS sync completed')
      end

      it 'shows last synced time' do
        output = capture_stdout { cli.sync }
        expect(output).to include('Last synced')
      end

      it 'shows sync summary' do
        output = capture_stdout { cli.sync }
        expect(output).to include('Summary')
        expect(output).to include('Apps: 5')
        expect(output).to include('Builds: 12')
        expect(output).to include('Certificates: 3')
        expect(output).to include('Devices: 25')
        expect(output).to include('Profiles: 8')
      end
    end

    describe 'sync iOS (explicit)' do
      let(:ios_sync_response) {
        { success: true, data: { 'synced_at' => '2026-02-06T10:00:00Z' } }
      }

      before do
        allow(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
          .and_return(ios_sync_response)
      end

      it 'syncs with explicit ios argument' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
        cli.sync('ios')
      end

      it 'syncs with apple alias' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
        cli.sync('apple')
      end

      it 'syncs with appstore alias' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
        cli.sync('appstore')
      end
    end

    describe 'sync Android' do
      let(:android_sync_response) {
        { success: true, data: {} }
      }

      before do
        allow(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
          .and_return(android_sync_response)
      end

      it 'shows syncing message' do
        output = capture_stdout { cli.sync('android') }
        expect(output).to include('Syncing data from Google Play')
      end

      it 'calls Android sync endpoint' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
        cli.sync('android')
      end

      it 'shows success message' do
        output = capture_stdout { cli.sync('android') }
        expect(output).to include('Android sync started')
      end

      it 'shows background info' do
        output = capture_stdout { cli.sync('android') }
        expect(output).to include('Sync runs in the background')
      end

      it 'syncs with google alias' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
        cli.sync('google')
      end

      it 'syncs with googleplay alias' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
        cli.sync('googleplay')
      end

      it 'syncs with play alias' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
        cli.sync('play')
      end
    end

    describe 'sync all' do
      let(:ios_sync_response) {
        { success: true, data: { 'synced_at' => '2026-02-06T10:00:00Z' } }
      }
      let(:android_sync_response) {
        { success: true, data: {} }
      }

      before do
        allow(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
          .and_return(ios_sync_response)
        allow(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
          .and_return(android_sync_response)
      end

      it 'syncs both platforms with all argument' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
        cli.sync('all')
      end

      it 'syncs both platforms with both argument' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
        cli.sync('both')
      end

      it 'shows iOS sync message' do
        output = capture_stdout { cli.sync('all') }
        expect(output).to include('Syncing data from App Store Connect')
      end

      it 'shows Android sync message' do
        output = capture_stdout { cli.sync('all') }
        expect(output).to include('Syncing data from Google Play')
      end
    end

    describe 'with --force option' do
      let(:ios_sync_response) {
        { success: true, data: {} }
      }

      before do
        cli.options = { force: true }
        allow(client).to receive(:post).and_return(ios_sync_response)
      end

      it 'sends force parameter' do
        expect(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: true })
        cli.sync
      end
    end

    describe 'invalid platform' do
      it 'shows error for unknown platform' do
        output = capture_stdout { cli.sync('invalid') }
        expect(output).to include('Unknown platform')
        expect(output).to include('invalid')
      end

      it 'shows valid platforms' do
        output = capture_stdout { cli.sync('invalid') }
        expect(output).to include('Valid platforms')
        expect(output).to include('ios')
        expect(output).to include('android')
        expect(output).to include('all')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.sync('invalid')
      end
    end

    describe 'when iOS sync fails' do
      before do
        allow(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
          .and_return({ success: false, error: 'Sync error' })
      end

      it 'shows failure message' do
        output = capture_stdout { cli.sync }
        expect(output).to include('iOS sync failed')
        expect(output).to include('Sync error')
      end
    end

    describe 'when iOS sync raises exception' do
      before do
        allow(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync", body: { force: nil })
          .and_raise(StandardError.new('Connection error'))
      end

      it 'shows failure message' do
        output = capture_stdout { cli.sync }
        expect(output).to include('iOS sync failed')
        expect(output).to include('Connection error')
      end
    end

    describe 'when Google Play not configured' do
      before do
        allow(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
          .and_raise(Mysigner::ClientError.new('No active Google Play credential'))
      end

      it 'shows not configured error' do
        output = capture_stdout { cli.sync('android') }
        expect(output).to include('Google Play not configured')
      end

      it 'shows setup guidance' do
        output = capture_stdout { cli.sync('android') }
        expect(output).to include('Set up credentials first')
        expect(output).to include('My Signer dashboard')
      end
    end

    describe 'when Android sync fails' do
      before do
        allow(client).to receive(:post)
          .with("/api/v1/organizations/#{org_id}/sync_google_play", body: { force: nil })
          .and_return({ success: false, error: 'Sync failed' })
      end

      it 'shows failure message' do
        output = capture_stdout { cli.sync('android') }
        expect(output).to include('Android sync failed')
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'sync']) }
      expect(help_output).to include('Sync')
    end

    it 'shows force option' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'sync']) }
      expect(help_output).to include('--force')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['sync']) }
      expect(output).to include('Not logged in')
    end
  end
end
