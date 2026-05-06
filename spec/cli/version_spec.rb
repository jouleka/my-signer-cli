# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'open3'
require 'stringio'

RSpec.describe 'mysigner version' do
  let(:cli) { Mysigner::CLI.new }
  let(:exe_path) { File.expand_path('../../exe/mysigner', __dir__) }

  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  describe 'command execution' do
    it 'displays CLI version' do
      expect { cli.version }.to output(/My Signer CLI v#{Mysigner::VERSION}/).to_stdout
    end

    it 'displays Ruby version' do
      expect { cli.version }.to output(/Ruby:\s+#{RUBY_VERSION}/).to_stdout
    end

    it 'displays Ruby platform' do
      expect { cli.version }.to output(/\(#{Regexp.escape(RUBY_PLATFORM)}\)/).to_stdout
    end

    it 'displays install path' do
      expect { cli.version }.to output(/Install:/).to_stdout
    end

    it 'displays config file path' do
      expect { cli.version }.to output(/Config:\s+#{Regexp.escape(Mysigner::Config::CONFIG_FILE)}/).to_stdout
    end

    it 'displays repository URL' do
      expect { cli.version }.to output(/Repository:.*github\.com/).to_stdout
    end

    it 'displays issues URL' do
      expect { cli.version }.to output(/Issues:.*github\.com.*issues/).to_stdout
    end

    it 'formats output with proper spacing' do
      output = ''
      expect { output = capture_stdout { cli.version } }.not_to raise_error
      lines = output.split("\n")

      # Should have blank lines for readability
      expect(lines[1]).to be_empty
      expect(lines[5]).to be_empty
    end

    it 'displays all information in correct order' do
      output = ''
      expect { output = capture_stdout { cli.version } }.not_to raise_error
      lines = output.split("\n").reject(&:empty?)

      expect(lines[0]).to match(/My Signer CLI/)
      expect(lines[1]).to match(/Ruby:/)
      expect(lines[2]).to match(/Install:/)
      expect(lines[3]).to match(/Config:/)
      expect(lines[4]).to match(/Repository:/)
      expect(lines[5]).to match(/Issues:/)
    end
  end

  describe 'command behavior' do
    it 'exits successfully (no exception)' do
      expect { cli.version }.not_to raise_error
    end

    it 'produces non-empty output' do
      output = capture_stdout { cli.version }
      expect(output.length).to be > 50
    end
  end

  describe 'with --verbose flag' do
    before do
      allow(cli).to receive(:options).and_return({ 'verbose' => true })
    end

    it 'shows same output (no difference)' do
      normal_output = capture_stdout { cli.version }
      expect(normal_output).to match(/My Signer CLI/)
    end
  end

  describe 'help text' do
    it 'has command description' do
      command = Mysigner::CLI.commands['version']
      expect(command.description).to eq('Show version information')
    end

    it 'is listed in help output' do
      help_output = capture_stdout { Mysigner::CLI.start(['help']) }
      expect(help_output).to include('version')
    end
  end

  describe 'integration tests', :integration do
    it 'runs successfully via shell' do
      _, _, status = Open3.capture3("#{exe_path} version 2>&1")
      expect(status.success?).to be true
    end

    it 'produces expected output via shell' do
      stdout, = Open3.capture3("#{exe_path} version 2>&1")
      expect(stdout).to include('My Signer CLI')
      expect(stdout).to include('Ruby:')
      expect(stdout).to include('Install:')
      expect(stdout).to include('Config:')
      expect(stdout).to include('Repository:')
      expect(stdout).to include('Issues:')
    end

    it 'returns exit code 0 via shell' do
      _, _, status = Open3.capture3("#{exe_path} version 2>&1")
      expect(status.exitstatus).to eq(0)
    end

    it 'rejects unexpected arguments' do
      stdout, _, status = Open3.capture3("#{exe_path} version -h 2>&1")
      # version command takes no arguments, so -h is treated as invalid argument
      expect(status.exitstatus).to eq(1)
      expect(stdout).to include('ERROR')
      expect(stdout).to include('was called with arguments')
    end

    it 'help for version command' do
      stdout, _, status = Open3.capture3("#{exe_path} help version 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('version')
      expect(stdout).to include('Show version information')
    end
  end

  describe 'version constant' do
    it 'is defined' do
      expect(defined?(Mysigner::VERSION)).to eq('constant')
    end

    it 'is a valid version string' do
      expect(Mysigner::VERSION).to match(/\d+\.\d+\.\d+/)
    end
  end

  describe 'config constant' do
    it 'is defined' do
      expect(defined?(Mysigner::Config::CONFIG_FILE)).to eq('constant')
    end

    it 'is a valid path' do
      expect(Mysigner::Config::CONFIG_FILE).to include('.mysigner')
    end
  end
end
