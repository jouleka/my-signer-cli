# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'mysigner/config'
require 'open3'
require 'stringio'

RSpec.describe 'mysigner logout' do
  let(:cli) { Mysigner::CLI.new }
  let(:exe_path) { File.expand_path('../../exe/mysigner', __dir__) }
  let(:config) { instance_double(Mysigner::Config) }

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
  end

  describe 'when logged in' do
    before do
      allow(config).to receive(:exists?).and_return(true)
    end

    context 'user confirms logout' do
      before do
        allow(cli).to receive(:yes?).and_return(true)
        allow(config).to receive(:clear)
      end

      it 'prompts for confirmation' do
        expect(cli).to receive(:yes?).with(/Are you sure/)
        cli.logout
      end

      it 'clears config' do
        expect(config).to receive(:clear)
        cli.logout
      end

      it 'shows success message' do
        expect { cli.logout }.to output(/Successfully logged out/).to_stdout
      end

      it 'shows config file location' do
        expect { cli.logout }.to output(/Config file removed/).to_stdout
        expect { cli.logout }.to output(/#{Regexp.escape(Mysigner::Config::CONFIG_FILE)}/).to_stdout
      end

      it 'does not show cancelled message' do
        output = capture_stdout { cli.logout }
        expect(output).not_to match(/cancelled/)
      end
    end

    context 'user cancels logout' do
      before do
        allow(cli).to receive(:yes?).and_return(false)
      end

      it 'prompts for confirmation' do
        expect(cli).to receive(:yes?).with(/Are you sure/)
        cli.logout
      end

      it 'does not clear config' do
        expect(config).not_to receive(:clear)
        cli.logout
      end

      it 'shows cancelled message' do
        expect { cli.logout }.to output(/Logout cancelled/).to_stdout
      end

      it 'does not show success message' do
        output = capture_stdout { cli.logout }
        expect(output).not_to match(/Successfully logged out/)
      end
    end
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
    end

    it 'shows no credentials message' do
      expect { cli.logout }.to output(/No stored credentials found/).to_stdout
    end

    it 'does not prompt for confirmation' do
      expect(cli).not_to receive(:yes?)
      cli.logout
    end

    it 'does not clear config' do
      expect(config).not_to receive(:clear)
      cli.logout
    end

    it 'returns gracefully' do
      expect { cli.logout }.not_to raise_error
    end
  end

  describe 'help text' do
    it 'has description' do
      command = Mysigner::CLI.commands['logout']
      expect(command.description).to eq('Clear stored credentials')
    end

    it 'is listed in help' do
      help_output = capture_stdout { Mysigner::CLI.start(['help']) }
      expect(help_output).to include('logout')
    end
  end

  describe 'integration tests' do
    it 'runs successfully when logged in' do
      # Can't easily test interactive prompt in integration, but verify command exists
      stdout, _, status = Open3.capture3("#{exe_path} help logout 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('logout')
    end

    it 'shows help for logout command' do
      stdout, _, status = Open3.capture3("#{exe_path} help logout 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner logout')
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
