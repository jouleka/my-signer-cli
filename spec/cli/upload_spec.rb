# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'mysigner/upload/asc_rest_uploader'

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

  describe 'successful upload' do
    let(:rest_uploader) { instance_double(Mysigner::Upload::AscRestUploader) }
    let(:apple_apps_response) do
      { data: { 'data' => { 'apps' => [{ 'id' => 'apple-app-1' }] } } }
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
      allow(Mysigner::Upload::Uploader).to receive(:extract_ipa_info)
        .with(ipa_path)
        .and_return(cf_bundle_version: '1', cf_bundle_short_version_string: '1.0', bundle_id: 'com.example.app')
      allow(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/apple_apps",
        params: { bundle_id: 'com.example.app' }
      ).and_return(apple_apps_response)
      allow(Mysigner::Upload::AscRestUploader).to receive(:new).and_return(rest_uploader)
      allow(rest_uploader).to receive(:call).and_return({ final_state: 'COMPLETE' })
      # Default options
      cli.options = { wait: false }
    end

    it 'shows upload header' do
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Upload to TestFlight')
    end

    it 'looks up the Apple app via MySigner using the IPA bundle ID' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/apple_apps",
        params: { bundle_id: 'com.example.app' }
      ).and_return(apple_apps_response)
      cli.upload('testflight', ipa_path)
    end

    it 'creates the REST uploader with the resolved apple_app_id' do
      expect(Mysigner::Upload::AscRestUploader).to receive(:new).with(
        hash_including(
          client: client,
          organization_id: org_id,
          ipa_path: ipa_path,
          apple_app_id: 'apple-app-1',
          platform: 'IOS'
        )
      ).and_return(rest_uploader)
      cli.upload('testflight', ipa_path)
    end

    it 'invokes the REST uploader' do
      expect(rest_uploader).to receive(:call).and_return({ final_state: 'COMPLETE' })
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
  end

  describe 'when bundle ID is missing from the IPA' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      # extract_ipa_info comes back with no bundle_id — covers a corrupt IPA.
      allow(Mysigner::Upload::Uploader).to receive(:extract_ipa_info)
        .with(ipa_path)
        .and_return(cf_bundle_version: '1', cf_bundle_short_version_string: '1.0', bundle_id: nil)
      # `exit` is stubbed at the top level so execution falls through; stub
      # the /apple_apps lookup with an empty match so the downstream code
      # doesn't explode on the unstubbed client call.
      allow(client).to receive(:get).and_return({ data: { 'data' => { 'apps' => [] } } })
      cli.options = { wait: false }
    end

    it 'shows a clear extraction error and exits 1' do
      expect(cli).to receive(:exit).with(1).at_least(:once)
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include('Could not extract bundle identifier')
    end
  end

  describe 'when the Apple app is unknown to MySigner' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      allow(Mysigner::Upload::Uploader).to receive(:extract_ipa_info)
        .with(ipa_path)
        .and_return(cf_bundle_version: '1', cf_bundle_short_version_string: '1.0', bundle_id: 'com.unknown.app')
      # /apple_apps returns no matches — the user has not synced this app yet.
      allow(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/apple_apps",
        params: { bundle_id: 'com.unknown.app' }
      ).and_return({ data: { 'data' => { 'apps' => [] } } })
      cli.options = { wait: false }
    end

    it 'surfaces the bundle ID and hints to run sync' do
      expect(cli).to receive(:exit).with(1)
      output = capture_stdout { cli.upload('testflight', ipa_path) }
      expect(output).to include("'com.unknown.app'")
      expect(output).to include('mysigner sync ios')
    end
  end

  describe 'when unexpected error occurs' do
    let(:rest_uploader) { instance_double(Mysigner::Upload::AscRestUploader) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(File).to receive(:exist?).with(ipa_path).and_return(true)
      allow(Mysigner::Upload::Uploader).to receive(:extract_ipa_info)
        .with(ipa_path)
        .and_return(cf_bundle_version: '1', cf_bundle_short_version_string: '1.0', bundle_id: 'com.example.app')
      allow(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/apple_apps",
        params: { bundle_id: 'com.example.app' }
      ).and_return({ data: { 'data' => { 'apps' => [{ 'id' => 'apple-app-1' }] } } })
      allow(Mysigner::Upload::AscRestUploader).to receive(:new).and_return(rest_uploader)
      allow(rest_uploader).to receive(:call).and_raise(StandardError.new('Unexpected failure'))
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

  describe 'integration tests', :integration do
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
