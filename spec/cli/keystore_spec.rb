# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'mysigner/signing/keystore_manager'

RSpec.describe 'mysigner keystore', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }
  let(:keystore_manager) { instance_double(Mysigner::Signing::KeystoreManager) }

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

    # Stub KeystoreManager
    allow(Mysigner::Signing::KeystoreManager).to receive(:new).and_return(keystore_manager)
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
      # Stub keystore_manager to allow execution to continue for testing output
      allow(keystore_manager).to receive(:list).and_return([])
    end

    it 'shows error message' do
      output = capture_stdout { cli.keystore('list') }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.keystore('list') }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.keystore('list')
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

    describe 'keystore list' do
      context 'when keystores exist' do
        let(:keystores) do
          [
            { 'id' => 1, 'name' => 'Release Key', 'key_alias' => 'release', 'package_name' => 'com.example.app',
              'active' => true },
            { 'id' => 2, 'name' => 'Debug Key', 'key_alias' => 'debug', 'active' => false }
          ]
        end

        before do
          allow(keystore_manager).to receive(:list).and_return(keystores)
        end

        it 'shows header' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('Android Keystores')
        end

        it 'shows keystore names' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('Release Key')
          expect(output).to include('Debug Key')
        end

        it 'shows keystore IDs' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('ID: 1')
          expect(output).to include('ID: 2')
        end

        it 'shows key aliases' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('Key Alias: release')
          expect(output).to include('Key Alias: debug')
        end

        it 'shows package name when present' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('App: com.example.app')
        end

        it 'shows active status' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('Active: Yes')
          expect(output).to include('Active: No')
        end

        it 'shows active keystore with checkmark' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('✓ Release Key')
        end

        it 'shows total count' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('Total: 2 keystore')
        end
      end

      context 'when no keystores found' do
        before do
          allow(keystore_manager).to receive(:list).and_return([])
        end

        it 'shows no keystores message' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('No keystores found')
        end

        it 'shows helpful tip' do
          output = capture_stdout { cli.keystore('list') }
          expect(output).to include('mysigner keystore upload')
        end
      end

      context 'with --app-id filter' do
        before do
          cli.options = { app_id: 42 }
          allow(keystore_manager).to receive(:list).with(android_app_id: 42).and_return([])
        end

        it 'passes app_id to manager' do
          expect(keystore_manager).to receive(:list).with(android_app_id: 42)
          cli.keystore('list')
        end
      end
    end

    describe 'keystore upload' do
      let(:keystore_path) { '/path/to/keystore.jks' }
      let(:upload_result) do
        { 'id' => 1, 'name' => 'My Key', 'key_alias' => 'key0', 'active' => true }
      end

      context 'with valid keystore' do
        before do
          cli.options = { name: 'My Key', alias: 'key0' }
          allow(File).to receive(:exist?).with(keystore_path).and_return(true)
          allow(cli).to receive(:ask).and_return('password123')
          allow(keystore_manager).to receive(:upload).and_return(upload_result)
        end

        it 'shows uploading message' do
          output = capture_stdout { cli.keystore('upload', keystore_path) }
          expect(output).to include('Uploading keystore')
        end

        it 'uploads the keystore' do
          expect(keystore_manager).to receive(:upload).with(
            name: 'My Key',
            keystore_path: keystore_path,
            keystore_password: 'password123',
            key_alias: 'key0',
            key_password: 'password123',
            android_app_id: nil,
            active: true
          )
          cli.keystore('upload', keystore_path)
        end

        it 'shows success message' do
          output = capture_stdout { cli.keystore('upload', keystore_path) }
          expect(output).to include('Keystore uploaded successfully')
        end

        it 'shows keystore details' do
          output = capture_stdout { cli.keystore('upload', keystore_path) }
          expect(output).to include('ID:')
          expect(output).to include('Name:')
          expect(output).to include('Key Alias:')
        end
      end

      context 'when path is missing' do
        before do
          # Stub File.exist? for nil to prevent TypeError when stubbed exit doesn't halt execution
          allow(File).to receive(:exist?).with(nil).and_return(false)
          # Stub ask calls that happen when execution continues past stubbed exit
          allow(cli).to receive(:ask).and_return('')
          # Stub upload for when it's called with empty values
          allow(keystore_manager).to receive(:upload).and_return({})
        end

        it 'shows usage error' do
          output = capture_stdout { cli.keystore('upload') }
          expect(output).to include('Usage: mysigner keystore upload PATH')
        end

        it 'shows example' do
          output = capture_stdout { cli.keystore('upload') }
          expect(output).to include('mysigner keystore upload')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('upload')
        end
      end

      context 'when file not found' do
        before do
          allow(File).to receive(:exist?).with('/nonexistent.jks').and_return(false)
          # Stub ask calls that happen when execution continues past stubbed exit
          allow(cli).to receive(:ask).and_return('password')
          # Stub upload for when it's called after stubbed exit
          allow(keystore_manager).to receive(:upload).and_return({})
        end

        it 'shows file not found error' do
          output = capture_stdout { cli.keystore('upload', '/nonexistent.jks') }
          expect(output).to include('File not found')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('upload', '/nonexistent.jks')
        end
      end

      context 'when keystore validation fails' do
        before do
          cli.options = { name: 'My Key', alias: 'key0' }
          allow(File).to receive(:exist?).with(keystore_path).and_return(true)
          allow(cli).to receive(:ask).and_return('wrong_password')

          allow(keystore_manager).to receive(:upload).and_raise(
            Mysigner::Signing::KeystoreManager::KeystoreError.new('Invalid password')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.keystore('upload', keystore_path) }
          expect(output).to include('Upload failed')
          expect(output).to include('Invalid password')
        end

        it 'shows troubleshooting tips' do
          output = capture_stdout { cli.keystore('upload', keystore_path) }
          expect(output).to include('Keystore Upload Failed')
          expect(output).to include('keytool')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('upload', keystore_path)
        end
      end

      context 'when API fails' do
        before do
          cli.options = { name: 'My Key', alias: 'key0' }
          allow(File).to receive(:exist?).with(keystore_path).and_return(true)
          allow(cli).to receive(:ask).and_return('password123')
          allow(keystore_manager).to receive(:upload).and_raise(
            Mysigner::ClientError.new('API error')
          )
        end

        it 'shows API error message' do
          output = capture_stdout { cli.keystore('upload', keystore_path) }
          expect(output).to include('API error')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('upload', keystore_path)
        end
      end
    end

    describe 'keystore download' do
      let(:download_result) do
        { path: '/tmp/keystore.jks', name: 'Release Key', key_alias: 'release' }
      end

      context 'when keystore exists' do
        before do
          allow(keystore_manager).to receive(:download).and_return(download_result)
        end

        it 'shows downloading message' do
          output = capture_stdout { cli.keystore('download', '1') }
          expect(output).to include('Downloading keystore')
        end

        it 'downloads the keystore' do
          expect(keystore_manager).to receive(:download).with('1')
          cli.keystore('download', '1')
        end

        it 'shows success message' do
          output = capture_stdout { cli.keystore('download', '1') }
          expect(output).to include('Keystore downloaded')
        end

        it 'shows keystore details' do
          output = capture_stdout { cli.keystore('download', '1') }
          expect(output).to include('Name:')
          expect(output).to include('Key Alias:')
          expect(output).to include('Path:')
        end

        it 'shows security warning' do
          output = capture_stdout { cli.keystore('download', '1') }
          expect(output).to include('Keep this file secure')
        end
      end

      context 'with --output option' do
        before do
          cli.options = { output: '/custom/path/key.jks' }
          allow(keystore_manager).to receive(:download).and_return(download_result)
          allow(FileUtils).to receive(:mv)
        end

        it 'moves file to custom path' do
          expect(FileUtils).to receive(:mv).with('/tmp/keystore.jks', '/custom/path/key.jks')
          cli.keystore('download', '1')
        end
      end

      context 'when ID is missing' do
        before do
          # Stub download to prevent errors when stubbed exit doesn't halt
          allow(keystore_manager).to receive(:download).with(nil).and_raise(
            Mysigner::Signing::KeystoreManager::KeystoreNotFoundError.new('Keystore ID required')
          )
        end

        it 'shows usage error' do
          output = capture_stdout { cli.keystore('download') }
          expect(output).to include('Usage: mysigner keystore download ID')
        end

        it 'shows hint to list keystores' do
          output = capture_stdout { cli.keystore('download') }
          expect(output).to include('mysigner keystores')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('download')
        end
      end

      context 'when keystore not found' do
        before do
          allow(keystore_manager).to receive(:download).and_raise(
            Mysigner::Signing::KeystoreManager::KeystoreNotFoundError.new('Not found')
          )
        end

        it 'shows not found error' do
          output = capture_stdout { cli.keystore('download', '999') }
          expect(output).to include('Keystore not found')
        end

        it 'shows helpful tips' do
          output = capture_stdout { cli.keystore('download', '999') }
          expect(output).to include('mysigner keystores')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('download', '999')
        end
      end

      context 'when download fails' do
        before do
          allow(keystore_manager).to receive(:download).and_raise(
            Mysigner::Signing::KeystoreManager::DownloadError.new('Network error')
          )
        end

        it 'shows download error' do
          output = capture_stdout { cli.keystore('download', '1') }
          expect(output).to include('Download failed')
          expect(output).to include('Network error')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('download', '1')
        end
      end
    end

    describe 'keystore delete' do
      context 'when keystore exists' do
        let(:keystores) do
          [{ 'id' => 1, 'name' => 'Release Key', 'key_alias' => 'release' }]
        end

        before do
          allow(keystore_manager).to receive(:list).and_return(keystores)
          allow(keystore_manager).to receive(:delete)
        end

        context 'when confirmed' do
          before do
            allow(cli).to receive(:yes?).and_return(true)
          end

          it 'shows warning message' do
            output = capture_stdout { cli.keystore('delete', '1') }
            expect(output).to include('You are about to delete')
            expect(output).to include('Release Key')
          end

          it 'deletes the keystore' do
            expect(keystore_manager).to receive(:delete).with('1')
            cli.keystore('delete', '1')
          end

          it 'shows success message' do
            output = capture_stdout { cli.keystore('delete', '1') }
            expect(output).to include('Keystore deleted')
          end
        end

        context 'when cancelled' do
          before do
            allow(cli).to receive(:yes?).and_return(false)
          end

          it 'does not delete' do
            expect(keystore_manager).not_to receive(:delete)
            cli.keystore('delete', '1')
          end

          it 'shows cancellation message' do
            output = capture_stdout { cli.keystore('delete', '1') }
            expect(output).to include('Deletion cancelled')
          end
        end
      end

      context 'when ID is missing' do
        before do
          # When stubbed exit doesn't halt, the code continues to list keystores
          # and tries to find nil in the list. Return a dummy keystore to prevent
          # NilError when it tries to access keystore['name']
          allow(keystore_manager).to receive(:list).and_return([
                                                                 { 'id' => nil, 'name' => 'Dummy',
                                                                   'key_alias' => 'dummy' }
                                                               ])
          allow(cli).to receive(:yes?).and_return(false)
        end

        it 'shows usage error' do
          output = capture_stdout { cli.keystore('delete') }
          expect(output).to include('Usage: mysigner keystore delete ID')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('delete')
        end
      end

      context 'when keystore not found' do
        before do
          # Return empty list so keystore is not found
          allow(keystore_manager).to receive(:list).and_return([])
        end

        it 'shows not found error' do
          # Use throw/catch to halt execution at exit(1)
          allow(cli).to receive(:exit).with(1).and_throw(:exit_called)
          output = capture_stdout do
            catch(:exit_called) { cli.keystore('delete', '999') }
          end
          expect(output).to include('Keystore not found')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1).and_throw(:exit_called)
          catch(:exit_called) { cli.keystore('delete', '999') }
        end
      end

      context 'when delete fails' do
        let(:keystores) do
          [{ 'id' => 1, 'name' => 'Release Key', 'key_alias' => 'release' }]
        end

        before do
          allow(keystore_manager).to receive(:list).and_return(keystores)
          allow(cli).to receive(:yes?).and_return(true)
          allow(keystore_manager).to receive(:delete).and_raise(
            Mysigner::ClientError.new('Delete failed')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.keystore('delete', '1') }
          expect(output).to include('Delete failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('delete', '1')
        end
      end
    end

    describe 'keystore activate' do
      context 'when keystore exists' do
        let(:activate_result) do
          { 'id' => 1, 'name' => 'Release Key', 'active' => true }
        end

        before do
          allow(keystore_manager).to receive(:activate).and_return(activate_result)
        end

        it 'shows activating message' do
          output = capture_stdout { cli.keystore('activate', '1') }
          expect(output).to include('Activating keystore')
        end

        it 'activates the keystore' do
          expect(keystore_manager).to receive(:activate).with('1')
          cli.keystore('activate', '1')
        end

        it 'shows success message' do
          output = capture_stdout { cli.keystore('activate', '1') }
          expect(output).to include('Keystore activated')
        end

        it 'shows which keystore is now default' do
          output = capture_stdout { cli.keystore('activate', '1') }
          expect(output).to include('Release Key')
          expect(output).to include('default keystore')
        end
      end

      context 'when ID is missing' do
        before do
          # Stub activate for nil to prevent errors when stubbed exit doesn't halt
          allow(keystore_manager).to receive(:activate).with(nil).and_raise(
            Mysigner::NotFoundError.new('ID required')
          )
        end

        it 'shows usage error' do
          output = capture_stdout { cli.keystore('activate') }
          expect(output).to include('Usage: mysigner keystore activate ID')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('activate')
        end
      end

      context 'when keystore not found' do
        before do
          allow(keystore_manager).to receive(:activate).and_raise(
            Mysigner::NotFoundError.new('Not found')
          )
        end

        it 'shows not found error' do
          output = capture_stdout { cli.keystore('activate', '999') }
          expect(output).to include('Keystore not found')
        end

        it 'shows helpful tips' do
          output = capture_stdout { cli.keystore('activate', '999') }
          expect(output).to include('mysigner keystores')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('activate', '999')
        end
      end

      context 'when activation fails' do
        before do
          allow(keystore_manager).to receive(:activate).and_raise(
            Mysigner::ClientError.new('Activation failed')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.keystore('activate', '1') }
          expect(output).to include('Activation failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.keystore('activate', '1')
        end
      end
    end

    describe 'unknown action' do
      it 'shows error for unknown action' do
        output = capture_stdout { cli.keystore('unknown') }
        expect(output).to include('Unknown action')
      end

      it 'shows available actions' do
        output = capture_stdout { cli.keystore('unknown') }
        expect(output).to include('list')
        expect(output).to include('upload')
        expect(output).to include('download')
        expect(output).to include('delete')
        expect(output).to include('activate')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.keystore('unknown')
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help keystore]) }
      expect(help_output).to include('keystore')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(%w[keystore list]) }
      expect(output).to include('Not logged in')
    end
  end
end
