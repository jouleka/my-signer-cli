# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner ship testflight', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
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

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      # Make exit actually stop execution
      allow(cli).to receive(:exit) { throw :system_exit }
    end

    it 'shows error message' do
      output = capture_stdout do
        catch(:system_exit) { cli.ship('testflight') }
      end
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout do
        catch(:system_exit) { cli.ship('testflight') }
      end
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1) { throw :system_exit }
      catch(:system_exit) { cli.ship('testflight') }
    end
  end

  describe 'when target is invalid' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(cli).to receive(:exit) { throw :system_exit }
    end

    it 'shows error message for invalid target' do
      output = capture_stdout do
        catch(:system_exit) { cli.ship('invalid_target') }
      end
      expect(output).to include('Invalid target')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1) { throw :system_exit }
      catch(:system_exit) { cli.ship('invalid_target') }
    end
  end

  describe 'ship workflow' do
    let(:project_info) do
      {
        path: '/path/to/MyApp.xcodeproj',
        type: :project,
        framework: :native
      }
    end
    let(:parser) { instance_double(Mysigner::Build::Parser) }
    let(:main_target) { double('target', name: 'MyApp') }
    let(:validator) { instance_double(Mysigner::Signing::Validator) }
    let(:executor) { instance_double(Mysigner::Build::Executor) }
    let(:exporter) { instance_double(Mysigner::Export::Exporter) }
    let(:uploader) { instance_double(Mysigner::Upload::Uploader) }
    let(:archive_path) { '/path/to/MyApp.xcarchive' }
    let(:ipa_path) { '/path/to/MyApp.ipa' }
    let(:org_response) do
      {
        data: {
          'app_store_connect_configured' => true,
          'app_store_connect_key_id' => 'ABC123',
          'app_store_connect_issuer_id' => 'def456-ghi-789',
          'app_store_connect_private_key' => 'key_content',
          'app_store_connect_team_id' => 'TEAM123'
        }
      }
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')
      allow(config).to receive(:current_organization_id).and_return(org_id)

      # Set default options
      cli.options = { configuration: 'Release', scheme: nil, wait: false, team: nil }

      # Mock project detection
      allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)

      # Mock parser
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
      allow(parser).to receive(:main_target).and_return(main_target)
      allow(parser).to receive(:bundle_id).and_return('com.example.myapp')
      allow(parser).to receive(:team_id).and_return('TEAM123')
      allow(parser).to receive(:code_sign_style).and_return('Automatic')

      # Mock validator
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      allow(validator).to receive(:validate!)

      # Mock executor
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
      allow(executor).to receive(:build!).and_return(archive_path)

      # Mock exporter
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)
      allow(exporter).to receive(:export!).and_return(ipa_path)

      # Mock IPA file size
      allow(File).to receive(:size).with(ipa_path).and_return(10_000_000) # 10MB

      # Mock API credential fetch
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)

      # Mock uploader
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)
      allow(uploader).to receive(:upload!).and_return({ success: true })
    end

    it 'shows ship header' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('Ship to TestFlight')
    end

    it 'shows workflow steps' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('This will:')
      expect(output).to include('Detect and build your project')
      expect(output).to include('Export IPA')
      expect(output).to include('Upload to TestFlight')
    end

    it 'shows estimated time' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('Estimated time')
    end

    it 'shows build step' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('[1/3] Building Archive')
    end

    it 'detects project' do
      expect(Mysigner::Build::Detector).to receive(:detect)
      cli.ship('testflight')
    end

    it 'validates signing' do
      expect(validator).to receive(:validate!)
      cli.ship('testflight')
    end

    it 'builds archive' do
      expect(executor).to receive(:build!)
      cli.ship('testflight')
    end

    it 'shows export step' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('[2/3] Exporting IPA')
    end

    it 'exports IPA' do
      expect(exporter).to receive(:export!)
      cli.ship('testflight')
    end

    it 'shows upload step' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('[3/3] Uploading to TestFlight')
    end

    it 'fetches credentials' do
      expect(client).to receive(:get).with("/api/v1/organizations/#{org_id}")
      cli.ship('testflight')
    end

    it 'uploads to TestFlight' do
      expect(uploader).to receive(:upload!)
      cli.ship('testflight')
    end

    it 'shows success message' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('SUCCESS!')
      expect(output).to include('Your app is on TestFlight')
    end

    it 'shows summary' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('Summary')
      expect(output).to include('Project:')
      expect(output).to include('Bundle ID:')
      expect(output).to include('Target:')
      expect(output).to include('IPA Size:')
    end

    it 'shows time breakdown' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('Time Breakdown')
      expect(output).to include('Build:')
      expect(output).to include('Export:')
      expect(output).to include('Upload:')
    end

    it 'shows next steps' do
      output = capture_stdout { cli.ship('testflight') }
      expect(output).to include('Next Steps')
    end

    context 'with --wait flag' do
      before do
        cli.options = { configuration: 'Release', scheme: nil, wait: true, team: nil }
      end

      it 'passes wait flag to uploader' do
        expect(uploader).to receive(:upload!).with(wait_for_processing: true)
        cli.ship('testflight')
      end
    end

    context 'with --team flag' do
      before do
        cli.options = { configuration: 'Release', scheme: nil, wait: false, team: 'CUSTOM_TEAM' }
      end

      it 'uses custom team ID' do
        expect(executor).to receive(:build!).with(
          'MyApp',
          'Release',
          hash_including(team_id: 'CUSTOM_TEAM')
        )
        cli.ship('testflight')
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
      allow(config).to receive(:user_email).and_return('test@example.com')
      allow(config).to receive(:current_organization_id).and_return(org_id)
      cli.options = { configuration: 'Release', scheme: nil, wait: false, team: nil }
    end

    context 'when project detection fails' do
      before do
        allow(client).to receive(:get).and_return({ data: {} })
        allow(Mysigner::Build::Detector).to receive(:detect).and_raise(
          Mysigner::Build::Detector::NoProjectError.new('No project found')
        )
        allow(cli).to receive(:exit) { throw :system_exit }
      end

      it 'shows error message' do
        output = capture_stdout do
          catch(:system_exit) { cli.ship('testflight') }
        end
        expect(output).to include('No project found')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1) { throw :system_exit }
        catch(:system_exit) { cli.ship('testflight') }
      end
    end

    context 'when build fails' do
      let(:project_info) { { path: '/path/to/App.xcodeproj', type: :project, framework: :native } }
      let(:parser) { instance_double(Mysigner::Build::Parser) }
      let(:main_target) { double('target', name: 'App') }
      let(:validator) { instance_double(Mysigner::Signing::Validator) }
      let(:executor) { instance_double(Mysigner::Build::Executor) }

      before do
        allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
        allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
        allow(parser).to receive(:main_target).and_return(main_target)
        allow(parser).to receive(:bundle_id).and_return('com.example.app')
        allow(parser).to receive(:team_id).and_return('TEAM123')
        allow(parser).to receive(:code_sign_style).and_return('Automatic')
        allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
        allow(validator).to receive(:validate!)
        allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
        allow(executor).to receive(:build!).and_raise(
          Mysigner::Build::Executor::BuildError.new('Build failed')
        )
        allow(client).to receive(:get) # Stub API calls
      end

      it 'shows error message' do
        output = capture_stdout { cli.ship('testflight') }
        expect(output).to include('Build failed')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.ship('testflight')
      end
    end

    context 'when export fails' do
      let(:project_info) { { path: '/path/to/App.xcodeproj', type: :project, framework: :native } }
      let(:parser) { instance_double(Mysigner::Build::Parser) }
      let(:main_target) { double('target', name: 'App') }
      let(:validator) { instance_double(Mysigner::Signing::Validator) }
      let(:executor) { instance_double(Mysigner::Build::Executor) }
      let(:exporter) { instance_double(Mysigner::Export::Exporter) }

      before do
        allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
        allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
        allow(parser).to receive(:main_target).and_return(main_target)
        allow(parser).to receive(:bundle_id).and_return('com.example.app')
        allow(parser).to receive(:team_id).and_return('TEAM123')
        allow(parser).to receive(:code_sign_style).and_return('Automatic')
        allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
        allow(validator).to receive(:validate!)
        allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
        allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
        allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)
        allow(exporter).to receive(:export!).and_raise(
          Mysigner::Export::Exporter::ExportError.new('Export failed')
        )
        allow(client).to receive(:get) # Stub API calls
        allow(File).to receive(:exist?).and_return(true)
        allow(cli).to receive(:exit) { throw :system_exit }
      end

      it 'shows error message' do
        output = capture_stdout do
          catch(:system_exit) { cli.ship('testflight') }
        end
        expect(output).to include('Export failed')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1) { throw :system_exit }
        catch(:system_exit) { cli.ship('testflight') }
      end
    end

    context 'when credentials not configured' do
      let(:project_info) { { path: '/path/to/App.xcodeproj', type: :project, framework: :native } }
      let(:parser) { instance_double(Mysigner::Build::Parser) }
      let(:main_target) { double('target', name: 'App') }
      let(:validator) { instance_double(Mysigner::Signing::Validator) }
      let(:executor) { instance_double(Mysigner::Build::Executor) }
      let(:exporter) { instance_double(Mysigner::Export::Exporter) }
      let(:org_response) do
        {
          data: {
            'app_store_connect_configured' => false
          }
        }
      end

      before do
        allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
        allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
        allow(parser).to receive(:main_target).and_return(main_target)
        allow(parser).to receive(:bundle_id).and_return('com.example.app')
        allow(parser).to receive(:team_id).and_return('TEAM123')
        allow(parser).to receive(:code_sign_style).and_return('Automatic')
        allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
        allow(validator).to receive(:validate!)
        allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
        allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
        allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)
        allow(exporter).to receive(:export!).and_return('/path/to/app.ipa')
        allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
        allow(File).to receive(:exist?).and_return(true)
        allow(File).to receive(:size).and_return(10_000_000)
        allow(cli).to receive(:exit) { throw :system_exit }
      end

      it 'shows error message' do
        output = capture_stdout do
          catch(:system_exit) { cli.ship('testflight') }
        end
        expect(output).to include('App Store Connect credentials not configured')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1) { throw :system_exit }
        catch(:system_exit) { cli.ship('testflight') }
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help ship]) }
      expect(help_output).to include('Build your project, sign it, and upload')
    end

    it 'shows options' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help ship]) }
      expect(help_output).to include('--configuration')
      expect(help_output).to include('--scheme')
      expect(help_output).to include('--wait')
      expect(help_output).to include('--team')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(%w[ship testflight]) }
      expect(output).to include('Not logged in')
    end
  end
end
