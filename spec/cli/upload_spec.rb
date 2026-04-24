# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner upload testflight', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }
  let(:ipa_path) { '/path/to/MyApp.ipa' }

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
    # Legacy uploader path (default is ASC REST uploader now)
    ENV['MYSIGNER_USE_LEGACY_ASC'] = '1'
  end

  after do
    ENV.delete('MYSIGNER_USE_LEGACY_ASC')
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(nil)
      allow(config).to receive(:api_token).and_return(nil)
      allow(config).to receive(:organization_id).and_return(nil)
      allow(config).to receive(:current_organization_id).and_return(nil)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).and_return(true) # Stub to prevent errors if execution continues
      allow(client).to receive(:get) # Stub to prevent errors if execution continues
    end

    it 'shows error message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.upload('testflight', ipa_path)
    end
  end

  describe 'when target is not testflight' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).and_return(true) # Stub to prevent errors if execution continues
      allow(client).to receive(:get) # Stub to prevent errors if execution continues
    end

    it 'shows error message' do
      output = capture_stdout { cli.upload('appstore', ipa_path) }
      expect(output).to include("Only 'testflight' target is supported")
    end

    it 'shows usage' do
      output = capture_stdout { cli.upload('appstore', ipa_path) }
      expect(output).to include('Usage: mysigner upload testflight')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.upload('appstore', ipa_path)
    end
  end

  describe 'when IPA file does not exist' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(false)
      allow(client).to receive(:get) # Stub to prevent errors if execution continues
    end

    it 'shows upload header' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Upload to TestFlight')
    end

    it 'shows error message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('IPA file not found')
      expect(output).to include(ipa_path)
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.upload('testflight', ipa_path)
    end
  end

  describe 'when App Store Connect credentials not configured' do
    let(:org_response) do
      {
        data: {
          'app_store_connect_configured' => false
        }
      }
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
    end

    it 'shows fetching credentials message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Fetching App Store Connect credentials')
    end

    it 'shows error message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('App Store Connect credentials not configured')
    end

    it 'shows setup guidance' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('mysigner doctor')
      expect(output).to include('mysigner onboard')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.upload('testflight', ipa_path)
    end
  end

  describe 'when credentials fetch fails' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      allow(client).to receive(:get).and_raise(Mysigner::ClientError.new('API connection failed'))
    end

    it 'shows error message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Error fetching credentials')
      expect(output).to include('API connection failed')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.upload('testflight', ipa_path)
    end
  end

  describe 'when credentials are invalid' do
    let(:org_response) do
      {
        data: {
          'app_store_connect_configured' => true,
          'app_store_connect_key_id' => 'ABC123',
          'app_store_connect_issuer_id' => nil, # Missing issuer
          'app_store_connect_private_key' => 'key_content'
        }
      }
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
    end

    it 'shows error message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Invalid credentials received from API')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.upload('testflight', ipa_path)
    end
  end

  describe 'successful upload' do
    let(:org_response) do
      {
        data: {
          'app_store_connect_configured' => true,
          'app_store_connect_key_id' => 'ABC123',
          'app_store_connect_issuer_id' => 'def456-ghi-789',
          'app_store_connect_private_key' => '-----BEGIN PRIVATE KEY-----\nkey_content\n-----END PRIVATE KEY-----'
        }
      }
    end
    let(:uploader) { instance_double(Mysigner::Upload::Uploader) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)
      allow(uploader).to receive(:upload!).and_return({ success: true })
      # Default options
      cli.options = { wait: false }
    end

    it 'shows upload header' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Upload to TestFlight')
    end

    it 'shows fetching credentials' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Fetching App Store Connect credentials')
    end

    it 'shows credentials loaded' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Credentials loaded')
    end

    it 'creates uploader with credentials' do
      expect(Mysigner::Upload::Uploader).to receive(:new).with(
        ipa_path,
        api_key: 'ABC123',
        api_issuer: 'def456-ghi-789',
        private_key: '-----BEGIN PRIVATE KEY-----\nkey_content\n-----END PRIVATE KEY-----'
      )
      cli.upload('testflight', ipa_path)
    end

    it 'uploads without waiting by default' do
      expect(uploader).to receive(:upload!).with(wait_for_processing: false)
      cli.upload('testflight', ipa_path)
    end

    it 'shows success message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Upload complete!')
    end

    it 'shows next steps' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Next steps:')
      expect(output).to include('Open App Store Connect')
      expect(output).to include('Wait for processing')
      expect(output).to include('Distribute to TestFlight testers')
    end

    context 'with --wait flag' do
      before do
        cli.options = { wait: true }
      end

      it 'uploads with waiting enabled' do
        expect(uploader).to receive(:upload!).with(wait_for_processing: true)
        cli.upload('testflight', ipa_path)
      end
    end
  end

  describe 'when transporter not found' do
    let(:org_response) do
      {
        data: {
          'app_store_connect_configured' => true,
          'app_store_connect_key_id' => 'ABC123',
          'app_store_connect_issuer_id' => 'def456-ghi-789',
          'app_store_connect_private_key' => 'key_content'
        }
      }
    end
    let(:uploader) { instance_double(Mysigner::Upload::Uploader) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)
      allow(uploader).to receive(:upload!).and_raise(
        Mysigner::Upload::Uploader::TransporterNotFoundError.new('No upload tool available')
      )
      cli.options = { wait: false }
    end

    it 'shows error message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('No upload tool available')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.upload('testflight', ipa_path)
    end
  end

  describe 'when upload fails' do
    let(:org_response) do
      {
        data: {
          'app_store_connect_configured' => true,
          'app_store_connect_key_id' => 'ABC123',
          'app_store_connect_issuer_id' => 'def456-ghi-789',
          'app_store_connect_private_key' => 'key_content'
        }
      }
    end
    let(:uploader) { instance_double(Mysigner::Upload::Uploader) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)
      allow(uploader).to receive(:upload!).and_raise(
        Mysigner::Upload::Uploader::UploadError.new('Upload failed: authentication error')
      )
      cli.options = { wait: false }
    end

    it 'shows upload error message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Upload Error')
      expect(output).to include('authentication error')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.upload('testflight', ipa_path)
    end
  end

  describe 'when unexpected error occurs' do
    let(:org_response) do
      {
        data: {
          'app_store_connect_configured' => true,
          'app_store_connect_key_id' => 'ABC123',
          'app_store_connect_issuer_id' => 'def456-ghi-789',
          'app_store_connect_private_key' => 'key_content'
        }
      }
    end
    let(:uploader) { instance_double(Mysigner::Upload::Uploader) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)
      allow(uploader).to receive(:upload!).and_raise(StandardError.new('Unexpected failure'))
      cli.options = { wait: false }
    end

    it 'shows unexpected error message' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Unexpected error')
      expect(output).to include('Unexpected failure')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.upload('testflight', ipa_path)
    end

    context 'with DEBUG environment variable' do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('DEBUG').and_return('true')
      end

      it 'shows backtrace' do
        # Just verify it doesn't crash with DEBUG enabled
        expect { cli.upload('testflight', ipa_path) }.not_to raise_error
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help upload]) }
      expect(help_output).to include('Upload existing .ipa to TestFlight')
    end

    it 'shows target and path arguments' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help upload]) }
      expect(help_output).to include('testflight')
      expect(help_output).to include('IPA_PATH')
    end

    it 'shows wait option' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help upload]) }
      expect(help_output).to include('--wait')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)

      output = capture_stdout { Mysigner::CLI.start(['upload', 'testflight', ipa_path]) }
      expect(output).to include('Not logged in')
    end
  end
end
