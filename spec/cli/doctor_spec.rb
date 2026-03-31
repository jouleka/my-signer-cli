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

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(Mysigner::Client).to receive(:new).and_return(client)
  end

  describe 'perfect environment - all checks pass' do
    before do
      # Xcode installed
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:`).with('xcodebuild -version').and_return("Xcode 15.0\nBuild version 15A240d\n")

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
      allow(client).to receive(:test_connection).and_return({})

      # Good disk space
      allow(cli).to receive(:`).with('df -h . 2>/dev/null | tail -1').and_return('Filesystem  50%  /')

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
      allow(cli).to receive(:`).with('df -h . 2>/dev/null | tail -1').and_return('Filesystem  50%  /')
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
      allow(cli).to receive(:`).with('xcodebuild -version').and_return("Xcode 15.0\n")
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(false)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(false)
      allow(File).to receive(:exist?).and_return(false)
      allow(config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:`).with('df -h . 2>/dev/null | tail -1').and_return('Filesystem  50%  /')
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
      allow(cli).to receive(:`).with('xcodebuild -version').and_return("Xcode 15.0\n")
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(false)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(client).to receive(:test_connection).and_return({})
      allow(cli).to receive(:`).with('df -h . 2>/dev/null | tail -1').and_return('Filesystem  50%  /')
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
      allow(cli).to receive(:`).with('xcodebuild -version').and_return("Xcode 15.0\n")
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:`).with('df -h . 2>/dev/null | tail -1').and_return('Filesystem  50%  /')
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(Mysigner::Build::Detector::NoProjectError)
    end

    it 'shows not logged in error' do
      expect { cli.doctor }.to output(/Not logged in/).to_stdout
    end

    it 'suggests login command' do
      expect { cli.doctor }.to output(/mysigner login/).to_stdout
    end
  end

  describe 'when API connection fails' do
    before do
      allow(cli).to receive(:system).with('which xcodebuild > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:`).with('xcodebuild -version').and_return("Xcode 15.0\n")
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(client).to receive(:test_connection).and_raise(StandardError, 'Connection failed')
      allow(cli).to receive(:`).with('df -h . 2>/dev/null | tail -1').and_return('Filesystem  50%  /')
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
      allow(cli).to receive(:`).with('xcodebuild -version').and_return("Xcode 15.0\n")
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(client).to receive(:test_connection).and_return({})
      allow(cli).to receive(:`).with('df -h . 2>/dev/null | tail -1').and_return('Filesystem  95%  /')
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
      allow(cli).to receive(:`).with('xcodebuild -version').and_return("Xcode 15.0\n")
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(client).to receive(:test_connection).and_return({})
      allow(cli).to receive(:`).with('df -h . 2>/dev/null | tail -1').and_return('Filesystem  50%  /')

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
      allow(cli).to receive(:`).with('xcodebuild -version').and_return("Xcode 15.0\n")
      allow(cli).to receive(:system).with('xcode-select -p > /dev/null 2>&1').and_return(true)
      allow(cli).to receive(:system).with('xcrun --find altool > /dev/null 2>&1').and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter').and_return(true)
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return('http://test')
      allow(config).to receive(:api_token).and_return('token')
      allow(client).to receive(:test_connection).and_return({})
      allow(cli).to receive(:`).with('df -h . 2>/dev/null | tail -1').and_return('Filesystem  50%  /')

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
      expect(command.description).to include('Diagnose')
    end
  end

  describe 'integration tests' do
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
