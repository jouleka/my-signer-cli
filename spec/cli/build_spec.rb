# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner build', type: :cli do
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
    allow(config).to receive(:user_email).and_return(nil)
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(nil)
      allow(config).to receive(:api_token).and_return(nil)
      allow(config).to receive(:current_organization_id).and_return(nil)
    end

    it 'shows error message' do
      output = capture_stdout { cli.build }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.build }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.build
    end
  end

  describe 'when not in a project directory' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(
        Mysigner::Build::Detector::NoProjectError.new('No Xcode project found')
      )
    end

    it 'shows detecting message' do
      output = capture_stdout { cli.build }
      expect(output).to include('Detecting project')
    end

    it 'shows error message' do
      output = capture_stdout { cli.build }
      expect(output).to include('No Xcode project found')
    end

    it 'shows supported project types' do
      output = capture_stdout { cli.build }
      expect(output).to include('Supported project types:')
      expect(output).to include('Native iOS')
      expect(output).to include('Capacitor/Ionic')
      expect(output).to include('React Native')
      expect(output).to include('Flutter')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.build
    end
  end

  describe 'when project is a framework or library' do
    let(:project_info) do
      {
        path: '/path/to/MyFramework.xcodeproj',
        type: :project,
        framework: :native
      }
    end
    let(:parser) { instance_double(Mysigner::Build::Parser) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
      allow(parser).to receive(:product_type).and_return(:framework)
      # Stub other methods that might be called if execution continues past exit
      allow(parser).to receive(:has_multiple_apps?).and_return(false)
      allow(parser).to receive(:main_target).and_return(double('target', name: 'Framework'))
      allow(parser).to receive(:target_platform).and_return(:ios)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:bundle_id).and_return('com.example.framework')
      allow(parser).to receive(:code_sign_style).and_return(nil)
      allow(parser).to receive(:team_id).and_return(nil)
      allow(client).to receive(:get) # Stub any API calls
    end

    it 'shows error message' do
      output = capture_stdout { cli.build }
      expect(output).to include('Cannot build framework')
    end

    it 'shows guidance' do
      output = capture_stdout { cli.build }
      expect(output).to include('My Signer builds')
      expect(output).to include('builds a framework')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.build
    end
  end

  describe 'successful build flow' do
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
    let(:archive_path) { '/path/to/MyApp.xcarchive' }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:current_organization_id).and_return(org_id)

      allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)

      # Mock parser methods
      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_multiple_apps?).and_return(false)
      allow(parser).to receive(:main_target).and_return(main_target)
      allow(parser).to receive(:target_platform).and_return(:ios)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:bundle_id).and_return('com.example.myapp')
      allow(parser).to receive(:code_sign_style).and_return('Automatic')
      allow(parser).to receive(:team_id).and_return('ABC123')

      # Mock validator
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      allow(validator).to receive(:validate!)

      # Mock executor
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
      allow(executor).to receive(:build!).and_return(archive_path)
    end

    it 'shows detecting message' do
      output = capture_stdout { cli.build }
      expect(output).to include('Detecting project')
    end

    it 'shows project found' do
      output = capture_stdout { cli.build }
      expect(output).to include('Found: MyApp.xcodeproj')
      expect(output).to include('Native iOS')
    end

    it 'shows target' do
      output = capture_stdout { cli.build }
      expect(output).to include('Target: MyApp')
    end

    it 'shows bundle ID' do
      output = capture_stdout { cli.build }
      expect(output).to include('Bundle ID: com.example.myapp')
    end

    it 'shows configuration' do
      output = capture_stdout { cli.build }
      expect(output).to include('Configuration:')
    end

    it 'shows signing style' do
      output = capture_stdout { cli.build }
      expect(output).to include('Signing: Automatic')
    end

    it 'shows automatic signing message' do
      output = capture_stdout { cli.build }
      expect(output).to include('Using Automatic signing')
    end

    it 'validates signing setup' do
      expect(validator).to receive(:validate!)
      cli.build
    end

    it 'builds the project' do
      expect(executor).to receive(:build!)
      cli.build
    end

    it 'shows success message' do
      output = capture_stdout { cli.build }
      expect(output).to include('Build succeeded!')
    end

    it 'shows archive path' do
      output = capture_stdout { cli.build }
      expect(output).to include('Archive:')
      expect(output).to include(archive_path)
    end

    it 'shows next steps' do
      output = capture_stdout { cli.build }
      expect(output).to include('Next steps:')
      expect(output).to include('mysigner export')
      expect(output).to include('mysigner ship testflight')
    end
  end

  describe 'when project has multiple apps' do
    let(:project_info) do
      {
        path: '/path/to/MultiApp.xcodeproj',
        type: :project,
        framework: :native
      }
    end
    let(:parser) { instance_double(Mysigner::Build::Parser) }
    let(:app1) { double('target', name: 'App1') }
    let(:app2) { double('target', name: 'App2') }
    let(:validator) { instance_double(Mysigner::Signing::Validator) }
    let(:executor) { instance_double(Mysigner::Build::Executor) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:current_organization_id).and_return(org_id)

      allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)

      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_multiple_apps?).and_return(true)
      allow(parser).to receive(:app_targets).and_return([app1, app2])
      allow(parser).to receive(:target_platform).and_return(:ios)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:bundle_id).and_return('com.example.app')
      allow(parser).to receive(:code_sign_style).and_return('Automatic')
      allow(parser).to receive(:team_id).and_return('ABC123')

      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      allow(validator).to receive(:validate!)
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
      allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')

      allow(cli).to receive(:ask).and_return('1')
    end

    it 'shows multiple apps message' do
      output = capture_stdout { cli.build }
      expect(output).to include('Multiple apps found')
    end

    it 'lists all apps' do
      output = capture_stdout { cli.build }
      expect(output).to include('1. App1')
      expect(output).to include('2. App2')
    end

    it 'prompts for selection' do
      expect(cli).to receive(:ask).with(/Select app to build/, limited_to: %w[1 2])
      cli.build
    end
  end

  describe 'team ID scenarios' do
    let(:project_info) { { path: '/path/to/App.xcodeproj', type: :project, framework: :native } }
    let(:parser) { instance_double(Mysigner::Build::Parser) }
    let(:main_target) { double('target', name: 'App') }
    let(:validator) { instance_double(Mysigner::Signing::Validator) }
    let(:executor) { instance_double(Mysigner::Build::Executor) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:current_organization_id).and_return(org_id)

      allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_multiple_apps?).and_return(false)
      allow(parser).to receive(:main_target).and_return(main_target)
      allow(parser).to receive(:target_platform).and_return(:ios)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:bundle_id).and_return('com.example.app')
      allow(parser).to receive(:code_sign_style).and_return('Automatic')

      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      allow(validator).to receive(:validate!)
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
      allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
    end

    context 'when --team flag is provided' do
      it 'uses the provided team ID' do
        allow(parser).to receive(:team_id).and_return('PROJECT_TEAM')

        expect(Mysigner::Signing::Validator).to receive(:new).with(
          parser, 'App', 'Release', team_id: 'CUSTOM_TEAM'
        )

        cli.options = { team: 'CUSTOM_TEAM', configuration: 'Release' }
        cli.build
      end
    end

    context 'when project has no team and API has team' do
      before do
        allow(parser).to receive(:team_id).and_return(nil)
        allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return({
                                                                                            'app_store_connect_team_id' => 'API_TEAM'
                                                                                          })
      end

      it 'fetches team from API' do
        output = capture_stdout { cli.build }
        expect(output).to include('No team set in project')
        expect(output).to include('Using team from My Signer: API_TEAM')
      end
    end

    context 'when project has no team and API has no team' do
      before do
        allow(parser).to receive(:team_id).and_return(nil)
        allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return({
                                                                                            'app_store_connect_team_id' => nil
                                                                                          })
      end

      it 'shows warning' do
        output = capture_stdout { cli.build }
        expect(output).to include('No team ID configured in My Signer')
      end
    end
  end

  describe 'when pre-build validation fails' do
    let(:project_info) { { path: '/path/to/App.xcodeproj', type: :project, framework: :native } }
    let(:parser) { instance_double(Mysigner::Build::Parser) }
    let(:main_target) { double('target', name: 'App') }
    let(:validator) { instance_double(Mysigner::Signing::Validator) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:current_organization_id).and_return(org_id)

      allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_multiple_apps?).and_return(false)
      allow(parser).to receive(:main_target).and_return(main_target)
      allow(parser).to receive(:target_platform).and_return(:ios)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:bundle_id).and_return('com.example.app')
      allow(parser).to receive(:code_sign_style).and_return('Automatic')
      allow(parser).to receive(:team_id).and_return(nil)

      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return({
                                                                                          'app_store_connect_team_id' => nil
                                                                                        })

      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      allow(validator).to receive(:validate!).and_raise(
        Mysigner::Signing::Validator::ValidationError.new('No development team set')
      )
    end

    it 'shows validation message' do
      output = capture_stdout { cli.build }
      expect(output).to include('Validating signing setup')
    end

    it 'shows error message' do
      output = capture_stdout { cli.build }
      expect(output).to include('No development team set')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.build
    end
  end

  describe 'when build fails' do
    let(:project_info) { { path: '/path/to/App.xcodeproj', type: :project, framework: :native } }
    let(:parser) { instance_double(Mysigner::Build::Parser) }
    let(:main_target) { double('target', name: 'App') }
    let(:validator) { instance_double(Mysigner::Signing::Validator) }
    let(:executor) { instance_double(Mysigner::Build::Executor) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:current_organization_id).and_return(org_id)

      allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_multiple_apps?).and_return(false)
      allow(parser).to receive(:main_target).and_return(main_target)
      allow(parser).to receive(:target_platform).and_return(:ios)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:bundle_id).and_return('com.example.app')
      allow(parser).to receive(:code_sign_style).and_return('Automatic')
      allow(parser).to receive(:team_id).and_return('ABC123')

      allow(client).to receive(:get) # Stub any API calls

      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      allow(validator).to receive(:validate!)
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
      allow(executor).to receive(:build!).and_raise(
        Mysigner::Build::Executor::BuildError.new('Compilation failed')
      )
    end

    it 'shows error message' do
      output = capture_stdout { cli.build }
      expect(output).to include('Compilation failed')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.build
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help build]) }
      expect(help_output).to include('Build .xcarchive only')
    end

    it 'shows options' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help build]) }
      expect(help_output).to include('--configuration')
      expect(help_output).to include('--target')
      expect(help_output).to include('--scheme')
      expect(help_output).to include('--team')
    end
  end

  describe 'integration tests', :integration do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['build']) }
      expect(output).to include('Not logged in')
    end
  end
end
