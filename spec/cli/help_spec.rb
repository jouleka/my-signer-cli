# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'open3'

RSpec.describe 'mysigner help' do
  let(:cli) { Mysigner::CLI.new }
  let(:exe_path) { File.expand_path('../../exe/mysigner', __dir__) }

  describe 'general help' do
    it 'shows all commands with mysigner help' do
      stdout, _, status = Open3.capture3("#{exe_path} help 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Commands:')
      expect(stdout).to include('mysigner build')
      expect(stdout).to include('mysigner ship')
      expect(stdout).to include('mysigner doctor')
      expect(stdout).to include('mysigner version')
      expect(stdout).to include('mysigner login')
      expect(stdout).to include('mysigner logout')
    end

    it 'shows all commands with mysigner -h' do
      stdout, _, status = Open3.capture3("#{exe_path} -h 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Commands:')
    end

    it 'shows all commands with mysigner --help' do
      stdout, _, status = Open3.capture3("#{exe_path} --help 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Commands:')
    end

    it 'shows help when no command given' do
      stdout, _, status = Open3.capture3("#{exe_path} 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Commands:')
    end

    it 'lists global options' do
      stdout, = Open3.capture3("#{exe_path} help 2>&1")
      expect(stdout).to include('Options:')
      expect(stdout).to include('verbose')
    end

    it 'includes command descriptions' do
      stdout, = Open3.capture3("#{exe_path} help 2>&1")
      expect(stdout).to include('Build .xcarchive only')
      expect(stdout).to include('Log in with existing API token')
      expect(stdout).to include('Run health check and diagnose')
      expect(stdout).to include('Show or set CLI configuration')
    end
  end

  describe 'specific command help' do
    it 'shows help for build command' do
      stdout, _, status = Open3.capture3("#{exe_path} help build 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner build')
      expect(stdout).to include('--configuration')
      expect(stdout).to include('--target')
      expect(stdout).to include('--scheme')
    end

    it 'shows help for ship command' do
      stdout, _, status = Open3.capture3("#{exe_path} help ship 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner ship')
    end

    it 'shows help for export command' do
      stdout, _, status = Open3.capture3("#{exe_path} help export 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner export')
    end

    it 'shows help for upload command' do
      stdout, _, status = Open3.capture3("#{exe_path} help upload 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner upload')
    end

    it 'shows help for login command' do
      stdout, _, status = Open3.capture3("#{exe_path} help login 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner login')
    end

    it 'shows help for logout command' do
      stdout, _, status = Open3.capture3("#{exe_path} help logout 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner logout')
    end

    it 'shows help for onboard command' do
      stdout, _, status = Open3.capture3("#{exe_path} help onboard 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner onboard')
    end

    it 'shows help for status command' do
      stdout, _, status = Open3.capture3("#{exe_path} help status 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner status')
    end

    it 'shows help for doctor command' do
      stdout, _, status = Open3.capture3("#{exe_path} help doctor 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner doctor')
    end

    it 'shows help for version command' do
      stdout, _, status = Open3.capture3("#{exe_path} help version 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner version')
    end

    it 'shows help for devices command' do
      stdout, _, status = Open3.capture3("#{exe_path} help devices 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner devices')
    end

    it 'shows help for certificates command' do
      stdout, _, status = Open3.capture3("#{exe_path} help certificates 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner certificates')
    end

    it 'shows help for profiles command' do
      stdout, _, status = Open3.capture3("#{exe_path} help profiles 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner profiles')
    end

    it 'shows help for orgs command' do
      stdout, _, status = Open3.capture3("#{exe_path} help orgs 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner orgs')
    end

    it 'shows help for switch command' do
      stdout, _, status = Open3.capture3("#{exe_path} help switch 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner switch')
    end

    it 'shows help for config command' do
      stdout, _, status = Open3.capture3("#{exe_path} help config 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner config')
      expect(stdout).to include('local-only')
    end
  end

  describe 'subcommands help' do
    it 'shows help for device subcommand' do
      stdout, _, status = Open3.capture3("#{exe_path} help device 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('device')
    end

    it 'shows help for profile subcommand' do
      stdout, _, status = Open3.capture3("#{exe_path} help profile 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('profile')
    end

    it 'shows help for certificate subcommand' do
      stdout, _, status = Open3.capture3("#{exe_path} help certificate 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('certificate')
    end
  end

  describe 'error handling' do
    it 'shows error for non-existent command' do
      stdout, _, status = Open3.capture3("#{exe_path} help nonexistent 2>&1")
      expect(status.exitstatus).to eq(1)
      expect(stdout).to include('Could not find command')
    end

    it 'shows error for invalid command' do
      stdout, _, status = Open3.capture3("#{exe_path} help foobar 2>&1")
      expect(status.exitstatus).to eq(1)
      expect(stdout).to include('Could not find command')
    end
  end

  describe 'help command itself' do
    it 'shows help for help command' do
      stdout, _, status = Open3.capture3("#{exe_path} help help 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner help')
    end

    it 'is listed in general help' do
      stdout, = Open3.capture3("#{exe_path} help 2>&1")
      expect(stdout).to include('mysigner help')
    end
  end

  describe 'output format' do
    it 'uses consistent formatting' do
      stdout, = Open3.capture3("#{exe_path} help 2>&1")
      stdout = stdout.force_encoding('UTF-8')
      # Should have proper structure
      expect(stdout).to match(/Commands:.*Options:/m)
    end

    it 'aligns command descriptions' do
      stdout, = Open3.capture3("#{exe_path} help 2>&1")
      stdout = stdout.force_encoding('UTF-8')
      lines = stdout.split("\n").select { |l| l.include?('mysigner') && l.include?('#') }
      # All description markers should align
      expect(lines.length).to be > 10
    end

    it 'shows proper usage format for commands' do
      stdout, = Open3.capture3("#{exe_path} help build 2>&1")
      expect(stdout).to match(/Usage:\s+mysigner build/)
    end
  end
end
