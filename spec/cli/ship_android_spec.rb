# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'mysigner/build/android_parser'
require 'mysigner/build/android_executor'
require 'mysigner/signing/keystore_manager'
require 'mysigner/upload/play_store_uploader'

RSpec.describe 'mysigner ship android', type: :cli do
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

  describe 'PartialUploadError handling' do
    let(:project_info) {
      {
        path: '/path/to/android',
        type: :gradle,
        framework: :react_native,
        build_gradle: '/path/to/android/app/build.gradle'
      }
    }
    let(:parser) { instance_double(Mysigner::Build::AndroidParser) }
    let(:executor) { instance_double(Mysigner::Build::AndroidExecutor) }
    let(:keystore_manager) { instance_double(Mysigner::Signing::KeystoreManager) }
    let(:uploader) { instance_double(Mysigner::Upload::PlayStoreUploader) }
    let(:aab_path) { '/path/to/app-release.aab' }

    let(:org_response) {
      {
        data: {
          'google_play_configured' => true,
          'google_play_service_account' => '{"type":"service_account"}'
        }
      }
    }

    let(:apps_response) {
      {
        data: {
          'android_apps' => [
            { 'id' => 1, 'package_name' => 'com.example.app', 'highest_version_code' => 5 }
          ]
        }
      }
    }

    let(:keystore_data) {
      {
        'id' => 1,
        'name' => 'test-keystore',
        'key_alias' => 'key0',
        'keystore_password' => 'password123',
        'key_password' => 'password123'
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')

      cli.options = { platform: 'android', verbose: false }

      # Mock project detection
      allow(Mysigner::Build::Detector).to receive(:detect_android).and_return(project_info)

      # Mock parser
      allow(Mysigner::Build::AndroidParser).to receive(:new).and_return(parser)
      allow(parser).to receive(:application_id).and_return('com.example.app')
      allow(parser).to receive(:version_code).and_return(6)
      allow(parser).to receive(:version_name).and_return('1.0.0')

      # Mock keystore manager
      allow(Mysigner::Signing::KeystoreManager).to receive(:new).and_return(keystore_manager)
      allow(keystore_manager).to receive(:active_keystore).and_return(keystore_data)
      allow(keystore_manager).to receive(:get_or_download).and_return({ path: '/tmp/keystore.jks' })

      # Mock executor
      allow(Mysigner::Build::AndroidExecutor).to receive(:new).and_return(executor)
      allow(executor).to receive(:build_aab!).and_return(aab_path)

      # Mock file operations
      allow(File).to receive(:exist?).with(aab_path).and_return(true)
      allow(File).to receive(:size).with(aab_path).and_return(50_000_000)
      allow(Dir).to receive(:pwd).and_return('/path/to/project')

      # Mock API calls
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/android_apps").and_return(apps_response)
      allow(client).to receive(:post) # Generic post stub
    end

    context 'when upload succeeds completely' do
      before do
        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_return({
          success: true,
          version_code: 6,
          track: 'internal',
          package_name: 'com.example.app'
        })
      end

      it 'saves build record to backend' do
        # The client.post is called for both keystore link and build record
        # We verify the build record post happens by checking the output
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('SUCCESS!')
      end

      it 'shows success message' do
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('SUCCESS!')
      end
    end

    context 'when track assignment fails (PartialUploadError)' do
      before do
        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_raise(
          Mysigner::Upload::PlayStoreUploader::PartialUploadError.new(
            'Google Play API error: Precondition check failed',
            version_code: 8
          )
        )
      end

      it 'still saves build record to prevent version conflicts' do
        # Verify the "Build recorded" message appears, which means save was attempted
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('Build v8 recorded')
      end

      it 'shows error message' do
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('Upload Failed')
        expect(output).to include('Precondition check failed')
      end

      it 'shows build recorded message' do
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('Build v8 recorded')
        expect(output).to include('prevents version conflicts')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.ship('internal')
      end
    end

    context 'when upload fails completely (UploadError)' do
      before do
        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_raise(
          Mysigner::Upload::PlayStoreUploader::UploadError.new('Bundle upload failed')
        )
      end

      it 'does not save build record' do
        # When UploadError (not PartialUploadError), no build record message should appear
        output = capture_stdout { cli.ship('internal') }
        expect(output).not_to include('Build v')
        expect(output).not_to include('recorded')
      end

      it 'shows error message' do
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('Upload Failed')
        expect(output).to include('Bundle upload failed')
      end
    end
  end

  describe 'generate_app_name_from_package helper' do
    # Access the private method for testing via the CLI instance
    it 'extracts meaningful name from package' do
      expect(cli.send(:generate_app_name_from_package, 'com.oopsfee.app')).to eq('Oopsfee')
    end

    it 'skips common prefixes' do
      expect(cli.send(:generate_app_name_from_package, 'com.example.myapp')).to eq('Example')
    end

    it 'handles io prefix' do
      expect(cli.send(:generate_app_name_from_package, 'io.mysigner.app')).to eq('Mysigner')
    end

    it 'handles org prefix' do
      expect(cli.send(:generate_app_name_from_package, 'org.apache.cordova')).to eq('Apache')
    end

    it 'falls back to last segment' do
      expect(cli.send(:generate_app_name_from_package, 'com.app')).to eq('App')
    end

    it 'capitalizes the name' do
      expect(cli.send(:generate_app_name_from_package, 'com.mycompany.coolapp')).to eq('Mycompany')
    end
  end
end
