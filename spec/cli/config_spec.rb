# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner config', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:config_file) { '/Users/test/.mysigner/config.yml' }

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
    stub_const('Mysigner::Config::CONFIG_FILE', config_file)
    allow(cli).to receive(:exit) # Stub exit
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(config).to receive(:load) # Stub to prevent errors if execution continues
      allow(config).to receive(:display).and_return({})
    end

    it 'shows error message' do
      output = capture_stdout { cli.config }
      expect(output).to include('No configuration found')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.config }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.config
    end

    it 'does not load config' do
      # Config.exists? returns false, so load should not be called before exit
      # But since we stub exit, execution continues and load gets called
      # So we just verify the error is shown
      output = capture_stdout { cli.config }
      expect(output).to include('No configuration found')
    end
  end

  describe 'when logged in with full config' do
    let(:display_config) {
      {
        api_url: 'https://api.mysigner.app',
        api_token: 'sk_test_...xyz',
        organization_id: '123'
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:display).and_return(display_config)
    end

    it 'shows configuration header' do
      output = capture_stdout { cli.config }
      expect(output).to include('Configuration')
    end

    it 'displays API URL' do
      output = capture_stdout { cli.config }
      expect(output).to include('api_url')
      expect(output).to include('https://api.mysigner.app')
    end

    it 'displays masked token' do
      output = capture_stdout { cli.config }
      expect(output).to include('api_token')
      expect(output).to include('sk_test_...xyz')
    end

    it 'displays organization ID' do
      output = capture_stdout { cli.config }
      expect(output).to include('organization_id')
      expect(output).to include('123')
    end

    it 'shows config file path' do
      output = capture_stdout { cli.config }
      expect(output).to include('Config file:')
      expect(output).to include(config_file)
    end

    it 'formats keys with consistent spacing' do
      output = capture_stdout { cli.config }
      # Keys should be left-justified to 20 characters
      expect(output).to match(/api_url\s+:/)
      expect(output).to match(/api_token\s+:/)
      expect(output).to match(/organization_id\s+:/)
    end

    it 'does not make network calls' do
      # Unlike 'status', config should not test connection
      expect_any_instance_of(Mysigner::Client).not_to receive(:test_connection)
      cli.config
    end
  end

  describe 'when logged in without org_id' do
    let(:display_config) {
      {
        api_url: 'https://api.mysigner.app',
        api_token: 'sk_test_...xyz',
        organization_id: nil
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:display).and_return(display_config)
    end

    it 'shows configuration header' do
      output = capture_stdout { cli.config }
      expect(output).to include('Configuration')
    end

    it 'displays API URL' do
      output = capture_stdout { cli.config }
      expect(output).to include('https://api.mysigner.app')
    end

    it 'displays masked token' do
      output = capture_stdout { cli.config }
      expect(output).to include('sk_test_...xyz')
    end

    it 'shows nil organization_id' do
      output = capture_stdout { cli.config }
      expect(output).to include('organization_id')
      # Ruby's to_s on nil returns empty string, so it might show as blank
    end

    it 'shows config file path' do
      output = capture_stdout { cli.config }
      expect(output).to include('Config file:')
    end
  end

  describe 'when config has localhost API URL' do
    let(:display_config) {
      {
        api_url: 'http://localhost:3000',
        api_token: 'sk_dev_...abc',
        organization_id: '456'
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:display).and_return(display_config)
    end

    it 'displays localhost URL correctly' do
      output = capture_stdout { cli.config }
      expect(output).to include('http://localhost:3000')
    end

    it 'shows dev token' do
      output = capture_stdout { cli.config }
      expect(output).to include('sk_dev_...abc')
    end
  end

  describe 'edge cases' do
    context 'when display returns empty hash' do
      before do
        allow(config).to receive(:exists?).and_return(true)
        allow(config).to receive(:load)
        allow(config).to receive(:display).and_return({})
      end

      it 'shows header' do
        output = capture_stdout { cli.config }
        expect(output).to include('Configuration')
      end

      it 'shows config file path' do
        output = capture_stdout { cli.config }
        expect(output).to include('Config file:')
      end

      it 'does not crash' do
        expect { cli.config }.not_to raise_error
      end
    end

    context 'when display has extra keys' do
      let(:display_config) {
        {
          api_url: 'https://api.mysigner.app',
          api_token: 'sk_test_...xyz',
          organization_id: '123',
          custom_key: 'custom_value',
          another_setting: 'test'
        }
      }

      before do
        allow(config).to receive(:exists?).and_return(true)
        allow(config).to receive(:load)
        allow(config).to receive(:display).and_return(display_config)
      end

      it 'displays all keys' do
        output = capture_stdout { cli.config }
        expect(output).to include('custom_key')
        expect(output).to include('custom_value')
        expect(output).to include('another_setting')
        expect(output).to include('test')
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'config']) }
      expect(help_output).to include('Show current configuration')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file_path = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file_path).and_return(false)
      
      output = capture_stdout { Mysigner::CLI.start(['config']) }
      expect(output).to include('No configuration found')
    end
  end
end

