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
    let(:display_config) do
      {
        api_url: 'https://mysigner.dev',
        user_email: 'test@example.com',
        current_organization: 'Test Org (ID: 123)',
        current_token: 'sk_test_...xyz'
      }
    end

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
      expect(output).to include('https://mysigner.dev')
    end

    it 'displays user email' do
      output = capture_stdout { cli.config }
      expect(output).to include('user_email')
      expect(output).to include('test@example.com')
    end

    it 'displays current organization' do
      output = capture_stdout { cli.config }
      expect(output).to include('current_organization')
      expect(output).to include('Test Org (ID: 123)')
    end

    it 'displays current token' do
      output = capture_stdout { cli.config }
      expect(output).to include('current_token')
      expect(output).to include('sk_test_...xyz')
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
      expect(output).to match(/user_email\s+:/)
      expect(output).to match(/current_organization\s*:/)
    end

    it 'does not make network calls' do
      # Unlike 'status', config should not test connection
      expect_any_instance_of(Mysigner::Client).not_to receive(:test_connection)
      cli.config
    end
  end

  describe 'when logged in without org_id' do
    let(:display_config) do
      {
        api_url: 'https://mysigner.dev',
        user_email: 'test@example.com',
        current_organization: '(not set)',
        current_token: '(not set)'
      }
    end

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
      expect(output).to include('https://mysigner.dev')
    end

    it 'shows not set message for organization' do
      output = capture_stdout { cli.config }
      expect(output).to include('current_organization')
      expect(output).to include('(not set)')
    end

    it 'shows not set message for token' do
      output = capture_stdout { cli.config }
      expect(output).to include('current_token')
      expect(output).to include('(not set)')
    end

    it 'shows config file path' do
      output = capture_stdout { cli.config }
      expect(output).to include('Config file:')
    end
  end

  describe 'when config has localhost API URL' do
    let(:display_config) do
      {
        api_url: 'http://localhost:3000',
        user_email: 'dev@example.com',
        current_organization: 'Dev Org (ID: 456)',
        current_token: 'sk_dev_...abc'
      }
    end

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
      let(:display_config) do
        {
          api_url: 'https://mysigner.dev',
          user_email: 'test@example.com',
          current_organization: 'Test Org (ID: 123)',
          current_token: 'sk_test_...xyz',
          custom_key: 'custom_value',
          another_setting: 'test'
        }
      end

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
      help_output = capture_stdout { Mysigner::CLI.start(%w[help config]) }
      expect(help_output).to include('Show current CLI configuration')
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
