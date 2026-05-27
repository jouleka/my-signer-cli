# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'open3'
require 'stringio'

RSpec.describe 'mysigner doctor' do
  let(:cli) { Mysigner::CLI.new }
  let(:exe_path) { File.expand_path('../../exe/mysigner', __dir__) }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }

  # Shared helper: stub all the backtick shell-outs the doctor command makes.
  # The real `$CHILD_STATUS` is set by the last real subprocess, so we
  # invoke `true` as a sanity process before returning a fake string for
  # each expected command (see CLAUDE context notes).
  def stub_backticks(cli, overrides = {})
    defaults = {
      /xcodebuild -version/ => "Xcode 15.0\n",
      /sudo -n xcodebuild/ => 'Xcode license accepted',
      /df -h/ => 'Filesystem  50%  /',
      /security find-identity/ => '1) ABC123 "Apple Distribution: Test (TEAM123)"',
      /java -version/ => "openjdk version \"17.0.0\"\n",
      /gradle --version/ => 'Gradle 8.0',
      %r{/usr/libexec/java_home} => '/Library/Java/JavaVirtualMachines/openjdk-17.jdk/Contents/Home'
    }
    combined = defaults.merge(overrides)

    allow(cli).to receive(:`).and_wrap_original do |original, cmd|
      # Invoke a real subprocess so $CHILD_STATUS is populated.
      original.call('true')
      match = combined.keys.find { |pattern| cmd =~ pattern }
      match ? combined[match] : ''
    end
  end

  before do
    # Config class-level stubs: disable env-config short-circuit so the
    # instance-level `config` double is used.
    allow(Mysigner::Config).to receive(:env_configured?).and_return(false)
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(config).to receive(:from_env?).and_return(false)

    allow(Mysigner::Client).to receive(:new).and_return(client)

    # Default: no Android SDK + no Android project so those checks exit quickly.
    stub_const('ENV', ENV.to_hash.except('ANDROID_HOME', 'ANDROID_SDK_ROOT', 'JAVA_HOME'))
    allow(cli).to receive(:system).with('which java > /dev/null 2>&1').and_return(false)
    allow(cli).to receive(:system).with('which gradle > /dev/null 2>&1').and_return(false)
    allow(cli).to receive(:system).with('which /usr/libexec/java_home > /dev/null 2>&1').and_return(false)
    allow(Mysigner::Build::Detector).to receive(:detect_android)
      .and_raise(Mysigner::Build::Detector::NoProjectError)

    # Prevent the project-signing deep-check branch from firing.
    # (Organization GET returns no app_store_connect_configured so the
    # signing/project-check block is skipped entirely.)
  end

  describe 'perfect environment - all checks pass' do
    before do
      # Xcode installed
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)

      # Command Line Tools installed
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)

      # altool available
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)

      # iTMSTransporter available
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)

      # Logged in with working API
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(config).to receive(:user_email).and_return('user@test.com')
      allow(config).to receive(:current_organization_id).and_return(nil)
      allow(client).to receive(:test_connection).and_return({})

      stub_backticks(cli)

      # No project in directory
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(Mysigner::Build::Detector::NoProjectError)
    end

    it 'shows success message' do
      expect { cli.doctor }.to output(/All checks passed/).to_stdout
    end

    it 'checks Xcode' do
      expect { cli.doctor }.to output(/Xcode installed/).to_stdout
    end

    it 'checks Command Line Tools' do
      expect { cli.doctor }.to output(/Command Line Tools installed/).to_stdout
    end

    it 'checks altool' do
      expect { cli.doctor }.to output(/xcrun altool available/).to_stdout
    end

    it 'checks iTMSTransporter' do
      expect { cli.doctor }.to output(/iTMSTransporter available/).to_stdout
    end

    it 'checks login status' do
      expect { cli.doctor }.to output(/Logged in/).to_stdout
    end

    it 'checks API connection' do
      expect { cli.doctor }.to output(/API connection working/).to_stdout
    end

    it 'checks disk space' do
      expect { cli.doctor }.to output(/Sufficient disk space/).to_stdout
    end

    it 'suggests next step' do
      expect { cli.doctor }.to output(/mysigner ship testflight/).to_stdout
    end

    it 'does not show any issues' do
      output = capture_stdout { cli.doctor }
      expect(output).not_to match(/issue\(s\) found/)
    end
  end

  describe 'when Xcode is missing' do
    before do
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(false)
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(false)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(false)
      allow(File).to receive(:exist?).and_return(false)
      allow(config).to receive(:exists?).and_return(false)
      stub_backticks(cli)
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(Mysigner::Build::Detector::NoProjectError)
    end

    it 'shows Xcode not found error' do
      expect { cli.doctor }.to output(/Xcode not found/).to_stdout
    end

    it 'reports issues found' do
      expect { cli.doctor }.to output(/issue\(s\) found/).to_stdout
    end

    it 'includes Xcode in issues list' do
      expect { cli.doctor }.to output(/Xcode is not installed/).to_stdout
    end
  end

  describe 'when Command Line Tools missing' do
    before do
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(false)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(false)
      allow(File).to receive(:exist?).and_return(false)
      allow(config).to receive(:exists?).and_return(false)
      stub_backticks(cli)
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(Mysigner::Build::Detector::NoProjectError)
    end

    it 'shows Command Line Tools error' do
      expect { cli.doctor }.to output(/Command Line Tools not found/).to_stdout
    end

    it 'shows install command' do
      expect { cli.doctor }.to output(/xcode-select --install/).to_stdout
    end
  end

  describe 'when altool missing (warning only)' do
    before do
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(false)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(config).to receive(:user_email).and_return('user@test.com')
      allow(config).to receive(:current_organization_id).and_return(nil)
      allow(client).to receive(:test_connection).and_return({})
      stub_backticks(cli)
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(Mysigner::Build::Detector::NoProjectError)
    end

    it 'shows altool warning' do
      expect { cli.doctor }.to output(/altool not found/).to_stdout
    end

    it 'shows warning count, not issue count' do
      expect { cli.doctor }.to output(/warning\(s\)/).to_stdout
    end

    it 'still shows mostly good message' do
      expect { cli.doctor }.to output(/mostly good/).to_stdout
    end
  end

  describe 'when not logged in' do
    before do
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(false)
      stub_backticks(cli)
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(Mysigner::Build::Detector::NoProjectError)
    end

    it 'shows not logged in error' do
      expect { cli.doctor }.to output(/Not logged in/).to_stdout
    end

    it 'suggests login command' do
      # Product text recommends `mysigner onboard` now; keep spec lenient
      # so either onboard or login copy satisfies.
      expect { cli.doctor }.to output(/mysigner (onboard|login)/).to_stdout
    end
  end

  describe 'when API connection fails' do
    before do
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(config).to receive(:user_email).and_return('user@test.com')
      allow(config).to receive(:current_organization_id).and_return(nil)
      allow(client).to receive(:test_connection)
        .and_raise(Mysigner::ConnectionError.new('Connection failed'))
      stub_backticks(cli)
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(Mysigner::Build::Detector::NoProjectError)
    end

    it 'shows API connection error' do
      expect { cli.doctor }.to output(/Cannot connect to API/).to_stdout
    end

    it 'provides helpful message' do
      expect { cli.doctor }.to output(/check your network/).to_stdout
    end
  end

  describe 'when disk space is low' do
    before do
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(config).to receive(:user_email).and_return('user@test.com')
      allow(config).to receive(:current_organization_id).and_return(nil)
      allow(client).to receive(:test_connection).and_return({})
      stub_backticks(cli, /df -h/ => 'Filesystem  95%  /')
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(Mysigner::Build::Detector::NoProjectError)
    end

    it 'shows low disk space warning' do
      expect { cli.doctor }.to output(/Low disk space/).to_stdout
    end

    it 'shows percentage' do
      expect { cli.doctor }.to output(/95% used/).to_stdout
    end

    it 'warns about build failures' do
      expect { cli.doctor }.to output(/may cause build failures/).to_stdout
    end
  end

  describe 'when in a Native iOS project' do
    before do
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(config).to receive(:user_email).and_return('user@test.com')
      allow(config).to receive(:current_organization_id).and_return(nil)
      allow(client).to receive(:test_connection).and_return({})
      stub_backticks(cli)

      # Project detected
      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
                                                                        path: '/test/MyApp.xcodeproj',
                                                                        framework: :native
                                                                      })
    end

    it 'detects Native iOS project' do
      expect { cli.doctor }.to output(/Found Native iOS project/).to_stdout
    end

    it 'shows project name' do
      expect { cli.doctor }.to output(/MyApp\.xcodeproj/).to_stdout
    end
  end

  describe 'when in a React Native project' do
    before do
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(config).to receive(:user_email).and_return('user@test.com')
      allow(config).to receive(:current_organization_id).and_return(nil)
      allow(client).to receive(:test_connection).and_return({})
      stub_backticks(cli)

      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
                                                                        path: '/test/ios/MyApp.xcworkspace',
                                                                        framework: :react_native
                                                                      })
    end

    it 'detects React Native project' do
      expect { cli.doctor }.to output(/Found React Native project/).to_stdout
    end
  end

  describe 'help text' do
    it 'has command description' do
      command = Mysigner::CLI.commands['doctor']
      # Product description uses lower-case 'diagnose'
      expect(command.description.downcase).to include('diagnose')
    end
  end

  describe 'integration tests', :integration do
    it 'runs successfully via shell' do
      _, _, status = Open3.capture3("#{exe_path} doctor 2>&1")
      expect(status.success?).to be true
    end

    it 'produces health check output' do
      stdout, = Open3.capture3("#{exe_path} doctor 2>&1")
      expect(stdout).to include('Health Check')
    end

    it 'returns exit code 0' do
      _, _, status = Open3.capture3("#{exe_path} doctor 2>&1")
      expect(status.exitstatus).to eq(0)
    end
  end

  describe 'mysigner doctor --local-only' do
    let(:cli) { Mysigner::CLI.new }

    before do
      ENV.delete('MYSIGNER_LOCAL_ONLY')
      allow(cli).to receive(:options).and_return({ local_only: true, platform: 'ios' })
      allow(cli).to receive(:system).and_return(true)
      allow(cli).to receive(:`).and_return('')
      allow(Socket).to receive(:tcp)
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(StandardError)
    end
    after { ENV.delete('MYSIGNER_LOCAL_ONLY') }

    it 'announces local-only mode instead of demanding login' do
      output = capture_stdout { cli.doctor }
      expect(output).to include('Local-only mode active')
      expect(output).not_to include('Not logged in')
      expect(output).not_to match(/Run ['`]mysigner onboard['`]/)
    end

    it 'does not add "Run mysigner onboard" to the issues list' do
      output = capture_stdout { cli.doctor }
      expect(output).not_to include("Run 'mysigner onboard' to authenticate")
    end

    it 'still runs the local environment checks' do
      output = capture_stdout { cli.doctor }
      expect(output).to include('Checking Xcode')
      expect(output).to include('Checking disk space')
    end
  end

  # Helper method
  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end
end
