# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'mysigner/build/detector'
require 'mysigner/build/android_executor'
require 'mysigner/build/android_parser'
require 'mysigner/signing/keystore_manager'

RSpec.describe 'mysigner android', type: :cli do
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
      # Stub client and detector for when execution continues past stubbed exit
      allow(client).to receive(:get).and_return({ data: { 'android_apps' => [] } })
      allow(client).to receive(:post).and_return({ data: { 'android_app' => {} } })
      allow(Mysigner::Build::Detector).to receive(:detect_android).and_raise(
        Mysigner::Build::Detector::NoProjectError.new('No project')
      )
      allow(cli).to receive(:parse_expo_config).and_return(nil)
    end

    it 'shows error message for android init' do
      output = capture_stdout { cli.android('init') }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.android('init') }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.android('init')
    end
  end

  describe 'when logged in' do
    let(:parser) { instance_double(Mysigner::Build::AndroidParser) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')
    end

    describe 'android init' do
      context 'native Android project' do
        let(:project_info) do
          { path: '/project/android', type: :gradle, framework: :native }
        end

        before do
          allow(Mysigner::Build::Detector).to receive(:detect_android).and_return(project_info)
          allow(Mysigner::Build::AndroidParser).to receive(:new).and_return(parser)
          allow(parser).to receive(:application_id).and_return('com.example.myapp')
          allow(parser).to receive(:app_name).and_return('My App')
          allow(client).to receive(:get).and_return({ data: { 'android_apps' => [] } })
          allow(client).to receive(:post).and_return({
                                                       data: { 'android_app' => { 'id' => 1,
                                                                                  'package_name' => 'com.example.myapp', 'name' => 'My App' } }
                                                     })
        end

        it 'shows detecting message' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('Detecting project')
        end

        it 'shows detected project type' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('Found')
        end

        it 'shows package name' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('com.example.myapp')
        end

        it 'shows app name' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('My App')
        end

        it 'registers the app with API' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/android_apps",
            body: { android_app: { package_name: 'com.example.myapp', name: 'My App' } }
          )
          cli.android('init')
        end

        it 'shows success message' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('App registered successfully')
        end

        it 'shows next steps' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('Next steps')
          expect(output).to include('Google Play Console')
        end
      end

      context 'React Native project' do
        let(:project_info) do
          { path: '/project/android', type: :gradle, framework: :react_native }
        end

        before do
          allow(Mysigner::Build::Detector).to receive(:detect_android).and_return(project_info)
          allow(Mysigner::Build::AndroidParser).to receive(:new).and_return(parser)
          allow(parser).to receive(:application_id).and_return('com.example.rnapp')
          allow(parser).to receive(:app_name).and_return('RN App')
          allow(client).to receive(:get).and_return({ data: { 'android_apps' => [] } })
          allow(client).to receive(:post).and_return({
                                                       data: { 'android_app' => { 'id' => 1,
                                                                                  'package_name' => 'com.example.rnapp' } }
                                                     })
        end

        it 'shows React Native project type' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('React native')
        end
      end

      context 'Expo project' do
        before do
          allow(Mysigner::Build::Detector).to receive(:detect_android).and_raise(
            Mysigner::Build::Detector::NoProjectError.new('No project')
          )
          allow(cli).to receive(:parse_expo_config).and_return({
                                                                 package_name: 'com.example.expoapp',
                                                                 name: 'Expo App',
                                                                 version_code: 1,
                                                                 version: '1.0.0'
                                                               })
          allow(client).to receive(:get).and_return({ data: { 'android_apps' => [] } })
          allow(client).to receive(:post).and_return({
                                                       data: { 'android_app' => { 'id' => 1,
                                                                                  'package_name' => 'com.example.expoapp' } }
                                                     })
        end

        it 'detects Expo project' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('Expo')
        end

        it 'shows package from app.json' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('com.example.expoapp')
        end
      end

      context 'Expo project without android.package' do
        before do
          allow(Mysigner::Build::Detector).to receive(:detect_android).and_raise(
            Mysigner::Build::Detector::NoProjectError.new('No project')
          )
          allow(cli).to receive(:parse_expo_config).and_return(nil)
          # Stub client for when stubbed exit doesn't halt execution
          allow(client).to receive(:get).and_return({ data: { 'android_apps' => [] } })
          allow(client).to receive(:post).and_return({ data: { 'android_app' => {} } })
        end

        it 'shows error about missing package' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('No Android project')
        end

        it 'shows app.json guidance' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('android.package')
          expect(output).to include('app.json')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.android('init')
        end
      end

      context 'no Android project found' do
        before do
          allow(Mysigner::Build::Detector).to receive(:detect_android).and_raise(
            Mysigner::Build::Detector::NoProjectError.new('No project')
          )
          allow(cli).to receive(:parse_expo_config).and_return(nil)
          # Stub client for when stubbed exit doesn't halt execution
          allow(client).to receive(:get).and_return({ data: { 'android_apps' => [] } })
          allow(client).to receive(:post).and_return({ data: { 'android_app' => {} } })
        end

        it 'shows error message' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('No Android project')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.android('init')
        end
      end

      context 'app already registered' do
        let(:project_info) do
          { path: '/project/android', type: :gradle, framework: :native }
        end
        let(:existing_app) do
          { 'id' => 42, 'package_name' => 'com.example.myapp', 'name' => 'My App', 'builds_count' => 5 }
        end

        before do
          allow(Mysigner::Build::Detector).to receive(:detect_android).and_return(project_info)
          allow(Mysigner::Build::AndroidParser).to receive(:new).and_return(parser)
          allow(parser).to receive(:application_id).and_return('com.example.myapp')
          allow(parser).to receive(:app_name).and_return('My App')
          allow(client).to receive(:get).and_return({
                                                      data: { 'android_apps' => [existing_app] }
                                                    })
        end

        it 'shows already registered message' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('App already registered')
        end

        it 'shows app details' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('ID:')
          expect(output).to include('42')
        end

        it 'shows next steps for existing app' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('mysigner ship')
        end
      end

      context 'validation error' do
        let(:project_info) do
          { path: '/project/android', type: :gradle, framework: :native }
        end

        before do
          allow(Mysigner::Build::Detector).to receive(:detect_android).and_return(project_info)
          allow(Mysigner::Build::AndroidParser).to receive(:new).and_return(parser)
          allow(parser).to receive(:application_id).and_return('com.example.myapp')
          allow(parser).to receive(:app_name).and_return('My App')
          allow(client).to receive(:get).and_return({ data: { 'android_apps' => [] } })

          error = Mysigner::ValidationError.new('Validation failed')
          allow(error).to receive(:details).and_return({ 'package_name' => ['is invalid'] })
          allow(client).to receive(:post).and_raise(error)
        end

        it 'shows validation error' do
          output = capture_stdout { cli.android('init') }
          expect(output).to include('Validation failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.android('init')
        end
      end
    end

    describe 'android add' do
      context 'with valid package name' do
        before do
          allow(client).to receive(:post).and_return({
                                                       data: { 'android_app' => { 'id' => 1,
                                                                                  'package_name' => 'com.example.newapp', 'name' => nil } }
                                                     })
        end

        it 'shows registering message' do
          output = capture_stdout { cli.android('add', 'com.example.newapp') }
          expect(output).to include('Registering Android app')
        end

        it 'shows the package name' do
          output = capture_stdout { cli.android('add', 'com.example.newapp') }
          expect(output).to include('com.example.newapp')
        end

        it 'registers with API' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/android_apps",
            body: { android_app: { package_name: 'com.example.newapp' } }
          )
          cli.android('add', 'com.example.newapp')
        end

        it 'shows success message' do
          output = capture_stdout { cli.android('add', 'com.example.newapp') }
          expect(output).to include('App registered successfully')
        end
      end

      context 'with custom name' do
        before do
          cli.options = { name: 'Custom App Name' }
          allow(client).to receive(:post).and_return({
                                                       data: { 'android_app' => { 'id' => 1,
                                                                                  'package_name' => 'com.example.app', 'name' => 'Custom App Name' } }
                                                     })
        end

        it 'shows the custom name' do
          output = capture_stdout { cli.android('add', 'com.example.app') }
          expect(output).to include('Custom App Name')
        end

        it 'sends name to API' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/android_apps",
            body: { android_app: { package_name: 'com.example.app', name: 'Custom App Name' } }
          )
          cli.android('add', 'com.example.app')
        end
      end

      context 'when package name is missing' do
        before do
          # Stub client.post for when execution continues past stubbed exit
          allow(client).to receive(:post).and_return({ data: { 'android_app' => {} } })
        end

        it 'shows usage error' do
          output = capture_stdout { cli.android('add') }
          expect(output).to include('Usage: mysigner android add PACKAGE_NAME')
        end

        it 'shows example' do
          output = capture_stdout { cli.android('add') }
          expect(output).to include('mysigner android add com.example.myapp')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.android('add')
        end
      end

      context 'when app already exists' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::ClientError.new('already exists')
          )
        end

        it 'shows already exists error' do
          output = capture_stdout { cli.android('add', 'com.existing.app') }
          expect(output).to include('already exists')
        end

        it 'suggests list command' do
          output = capture_stdout { cli.android('add', 'com.existing.app') }
          expect(output).to include('mysigner android list')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.android('add', 'com.existing.app')
        end
      end

      context 'validation error' do
        before do
          error = Mysigner::ValidationError.new('Validation failed')
          allow(error).to receive(:details).and_return({ 'package_name' => ['is invalid'] })
          allow(client).to receive(:post).and_raise(error)
        end

        it 'shows validation error' do
          output = capture_stdout { cli.android('add', 'invalid') }
          expect(output).to include('Validation failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.android('add', 'invalid')
        end
      end
    end

    describe 'android build' do
      let(:parser) { double('AndroidParser') }
      let(:aab_path) { '/project/app/build/outputs/bundle/release/app-release.aab' }

      before do
        allow(cli).to receive(:expo_project?).and_return(false)
        allow(Dir).to receive(:pwd).and_return('/project')
      end

      context 'native Android project' do
        let(:project_info) do
          {
            path: '/project/android',
            type: :gradle,
            framework: :native,
            directory: '/project',
            android_directory: '/project/android'
          }
        end

        before do
          allow(Mysigner::Build::Detector).to receive(:detect_android).and_return(project_info)
          allow(Mysigner::Build::AndroidParser).to receive(:new).and_return(parser)
          allow(parser).to receive(:application_id).and_return('com.example.app')
          allow(parser).to receive(:version_code).and_return(1)
          allow(parser).to receive(:version_name).and_return('1.0.0')
          # Stub internal methods called during build
          allow(cli).to receive(:fetch_keystore_for_build).and_return(nil)
          allow(cli).to receive(:fetch_highest_version_code).and_return(nil)
          allow(cli).to receive(:build_gradle_aab).and_return(aab_path)
          allow(File).to receive(:exist?).with(aab_path).and_return(true)
          allow(File).to receive(:size).with(aab_path).and_return(50_000_000)
          allow(File).to receive(:dirname).with(aab_path).and_return('/project/app/build/outputs/bundle/release')
          # Prevent opening folder
          allow(cli).to receive(:system)
        end

        it 'shows building message' do
          output = capture_stdout { cli.android('build') }
          expect(output).to include('Building Android App Bundle')
        end

        it 'builds the AAB' do
          expect(cli).to receive(:build_gradle_aab).and_return(aab_path)
          cli.android('build')
        end
      end
    end

    describe 'android list' do
      it 'delegates to apps command' do
        expect(cli).to receive(:invoke).with(:apps, [], platform: 'android')
        cli.android('list')
      end
    end

    describe 'unknown action' do
      it 'shows error for unknown action' do
        output = capture_stdout { cli.android('unknown') }
        expect(output).to include('Unknown action')
      end

      it 'shows available actions' do
        output = capture_stdout { cli.android('unknown') }
        expect(output).to include('init')
        expect(output).to include('add')
        expect(output).to include('build')
        expect(output).to include('list')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.android('unknown')
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help android]) }
      expect(help_output).to include('Android')
    end

    it 'shows subcommands' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help android]) }
      expect(help_output).to include('init')
      expect(help_output).to include('add')
      expect(help_output).to include('build')
    end
  end

  describe 'integration tests', :integration do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout do
        expect { Mysigner::CLI.start(%w[android init]) }.to raise_error(SystemExit)
      end
      expect(output).to include('Not logged in')
    end
  end
end
