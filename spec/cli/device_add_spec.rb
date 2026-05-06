# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner device add', type: :cli do
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
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(nil)
      allow(config).to receive(:api_token).and_return(nil)
      allow(config).to receive(:organization_id).and_return('123')
      allow(config).to receive(:current_organization_id).and_return('123')
      allow(config).to receive(:user_email).and_return(nil)
      # Stub to prevent errors if execution continues
      allow(client).to receive(:post).and_return({ data: { 'device' => {} } })
      cli.options = { platform: 'IOS' }
    end

    it 'shows error message' do
      output = capture_stdout { cli.device('add', 'iPhone 15', '00008110-000123456789ABCD') }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.device('add', 'iPhone 15', '00008110-000123456789ABCD') }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('add', 'iPhone 15', '00008110-000123456789ABCD')
    end
  end

  describe 'when no arguments provided' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      # Stub to prevent errors if execution continues
      allow(client).to receive(:post).and_return({ data: { 'device' => {} } })
      cli.options = { platform: 'IOS' }
    end

    it 'shows usage message' do
      output = capture_stdout { cli.device('add') }
      expect(output).to include('Usage: mysigner device add NAME UDID')
    end

    it 'shows platform option' do
      output = capture_stdout { cli.device('add') }
      expect(output).to include('--platform')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('add')
    end
  end

  describe 'when only NAME provided' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:post).and_return({ data: { 'device' => {} } })
      cli.options = { platform: 'IOS' }
    end

    it 'shows usage message' do
      output = capture_stdout { cli.device('add', 'iPhone 15') }
      expect(output).to include('Usage: mysigner device add NAME UDID')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('add', 'iPhone 15')
    end
  end

  describe 'successful device registration with default platform' do
    let(:device_response) do
      {
        data: {
          'device' => {
            'id' => 'dev_123',
            'name' => 'iPhone 15 Pro',
            'udid' => '00008110-000123456789ABCD',
            'platform' => 'IOS',
            'device_class' => 'IPHONE',
            'status' => 'ENABLED'
          }
        }
      }
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:post).and_return(device_response)

      cli.options = { platform: 'IOS' }
    end

    it 'shows registering message' do
      output = capture_stdout { cli.device('add', 'iPhone 15 Pro', '00008110-000123456789ABCD') }
      expect(output).to include('Registering device')
    end

    it 'posts to API with device data' do
      expect(client).to receive(:post).with(
        "/api/v1/organizations/#{org_id}/devices",
        body: {
          name: 'iPhone 15 Pro',
          udid: '00008110-000123456789ABCD',
          platform: 'IOS'
        }
      )
      cli.device('add', 'iPhone 15 Pro', '00008110-000123456789ABCD')
    end

    it 'shows success message' do
      output = capture_stdout { cli.device('add', 'iPhone 15 Pro', '00008110-000123456789ABCD') }
      expect(output).to include('Device registered successfully')
    end

    it 'shows device details' do
      output = capture_stdout { cli.device('add', 'iPhone 15 Pro', '00008110-000123456789ABCD') }
      expect(output).to include('Details:')
      expect(output).to include('Name:')
      expect(output).to include('iPhone 15 Pro')
      expect(output).to include('UDID:')
      expect(output).to include('00008110-000123456789ABCD')
      expect(output).to include('Platform:')
      expect(output).to include('IOS')
      expect(output).to include('Status:')
      expect(output).to include('ENABLED')
    end

    it 'does not exit with error' do
      expect(cli).not_to receive(:exit)
      cli.device('add', 'iPhone 15 Pro', '00008110-000123456789ABCD')
    end
  end

  describe 'successful device registration with custom platform' do
    let(:device_response) do
      {
        data: {
          'device' => {
            'id' => 'dev_456',
            'name' => 'MacBook Pro',
            'udid' => 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX',
            'platform' => 'MAC_OS',
            'device_class' => 'MAC',
            'status' => 'ENABLED'
          }
        }
      }
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:post).and_return(device_response)

      cli.options = { platform: 'mac_os' }
    end

    it 'uppercases platform before sending to API' do
      expect(client).to receive(:post).with(
        "/api/v1/organizations/#{org_id}/devices",
        body: {
          name: 'MacBook Pro',
          udid: 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX',
          platform: 'MAC_OS'
        }
      )
      cli.device('add', 'MacBook Pro', 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX')
    end

    it 'shows MAC_OS platform in output' do
      output = capture_stdout { cli.device('add', 'MacBook Pro', 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX') }
      expect(output).to include('MAC_OS')
    end
  end

  describe 'when validation fails' do
    let(:validation_error) do
      Mysigner::ValidationError.new('Validation failed', {
                                      'udid' => ['is invalid', 'must be 40 characters'],
                                      'name' => ['is too short']
                                    })
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:post).and_raise(validation_error)

      cli.options = { platform: 'IOS' }
    end

    it 'shows validation failed header' do
      output = capture_stdout { cli.device('add', 'i', 'invalid') }
      expect(output).to include('Validation failed')
    end

    it 'shows field-specific errors' do
      output = capture_stdout { cli.device('add', 'i', 'invalid') }
      expect(output).to include('udid:')
      expect(output).to include('is invalid')
      expect(output).to include('must be 40 characters')
      expect(output).to include('name:')
      expect(output).to include('is too short')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('add', 'i', 'invalid')
    end
  end

  describe 'when validation fails without details' do
    let(:validation_error) do
      Mysigner::ValidationError.new('Invalid device data')
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:post).and_raise(validation_error)

      cli.options = { platform: 'IOS' }
    end

    it 'shows validation error message' do
      output = capture_stdout { cli.device('add', 'iPhone', 'invalid') }
      expect(output).to include('Validation failed')
      expect(output).to include('Invalid device data')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('add', 'iPhone', 'invalid')
    end
  end

  describe 'when device already exists' do
    let(:client_error) do
      Mysigner::ClientError.new('Device with this UDID already exists')
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:post).and_raise(client_error)

      cli.options = { platform: 'IOS' }
    end

    it 'shows duplicate device error' do
      output = capture_stdout { cli.device('add', 'iPhone 15', '00008110-000123456789ABCD') }
      expect(output).to include('Device with this UDID already exists')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('add', 'iPhone 15', '00008110-000123456789ABCD')
    end
  end

  describe 'when API fails' do
    let(:client_error) do
      Mysigner::ClientError.new('Connection timeout')
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:post).and_raise(client_error)

      cli.options = { platform: 'IOS' }
    end

    it 'shows API error' do
      output = capture_stdout { cli.device('add', 'iPhone 15', '00008110-000123456789ABCD') }
      expect(output).to include('Failed to register device')
      expect(output).to include('Connection timeout')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('add', 'iPhone 15', '00008110-000123456789ABCD')
    end
  end

  describe 'when unknown action provided' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      cli.options = { platform: 'IOS' }
    end

    it 'shows unknown action error' do
      output = capture_stdout { cli.device('delete', '123') }
      expect(output).to include('Unknown action: delete')
    end

    it 'shows available actions' do
      output = capture_stdout { cli.device('delete', '123') }
      expect(output).to include('Available actions:')
      expect(output).to include('add')
      expect(output).to include('update')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('delete', '123')
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help device]) }
      expect(help_output).to include('Register and manage test devices')
    end

    it 'shows subcommands' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help device]) }
      expect(help_output).to include('add')
      expect(help_output).to include('update')
    end

    it 'shows platform option' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help device]) }
      expect(help_output).to include('--platform')
    end
  end

  describe 'integration tests', :integration do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(%w[device add iPhone 00008110-000123456789ABCD]) }
      expect(output).to include('Not logged in')
    end
  end
end
