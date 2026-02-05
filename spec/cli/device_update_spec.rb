# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner device update', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }
  let(:device_id) { 'dev_456' }

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
      # Stub to prevent errors if execution continues
      allow(client).to receive(:get).and_return({ data: {} })
      allow(client).to receive(:patch).and_return({ data: { 'device' => {} } })
      cli.options = { platform: 'IOS' }
    end

    it 'shows error message' do
      output = capture_stdout { cli.device('update', device_id, 'New Name') }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.device('update', device_id, 'New Name') }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('update', device_id, 'New Name')
    end
  end

  describe 'when no arguments provided' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      # Stub to prevent errors if execution continues
      allow(client).to receive(:get).and_return({ data: {} })
      allow(client).to receive(:patch).and_return({ data: { 'device' => {} } })
      cli.options = { platform: 'IOS' }
    end

    it 'shows usage message' do
      output = capture_stdout { cli.device('update') }
      expect(output).to include('Usage: mysigner device update ID NEW_NAME')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('update')
    end
  end

  describe 'when only ID provided' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_return({ data: {} })
      allow(client).to receive(:patch).and_return({ data: { 'device' => {} } })
      cli.options = { platform: 'IOS' }
    end

    it 'shows usage message' do
      output = capture_stdout { cli.device('update', device_id) }
      expect(output).to include('Usage: mysigner device update ID NEW_NAME')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('update', device_id)
    end
  end

  describe 'successful device update' do
    let(:get_response) {
      {
        data: {
          'id' => device_id,
          'name' => 'Old iPhone Name',
          'udid' => '00008110-000123456789ABCD',
          'platform' => 'IOS',
          'device_class' => 'IPHONE',
          'status' => 'ENABLED'
        }
      }
    }

    let(:patch_response) {
      {
        data: {
          'device' => {
            'id' => device_id,
            'name' => 'New iPhone Name',
            'udid' => '00008110-000123456789ABCD',
            'platform' => 'IOS',
            'device_class' => 'IPHONE',
            'status' => 'ENABLED'
          }
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/devices/#{device_id}").and_return(get_response)
      allow(client).to receive(:patch).and_return(patch_response)
      
      cli.options = { platform: 'IOS' }
    end

    it 'shows updating message' do
      output = capture_stdout { cli.device('update', device_id, 'New iPhone Name') }
      expect(output).to include('Updating device')
    end

    it 'fetches current device details' do
      expect(client).to receive(:get).with("/api/v1/organizations/#{org_id}/devices/#{device_id}")
      cli.device('update', device_id, 'New iPhone Name')
    end

    it 'shows current name' do
      output = capture_stdout { cli.device('update', device_id, 'New iPhone Name') }
      expect(output).to include('Current name:')
      expect(output).to include('Old iPhone Name')
    end

    it 'shows new name' do
      output = capture_stdout { cli.device('update', device_id, 'New iPhone Name') }
      expect(output).to include('New name:')
      expect(output).to include('New iPhone Name')
    end

    it 'patches device with new name' do
      expect(client).to receive(:patch).with(
        "/api/v1/organizations/#{org_id}/devices/#{device_id}",
        body: { name: 'New iPhone Name' }
      )
      cli.device('update', device_id, 'New iPhone Name')
    end

    it 'shows success message' do
      output = capture_stdout { cli.device('update', device_id, 'New iPhone Name') }
      expect(output).to include('Device updated successfully')
    end

    it 'shows updated device details' do
      output = capture_stdout { cli.device('update', device_id, 'New iPhone Name') }
      expect(output).to include('Details:')
      expect(output).to include('Name:')
      expect(output).to include('New iPhone Name')
      expect(output).to include('UDID:')
      expect(output).to include('00008110-000123456789ABCD')
      expect(output).to include('Platform:')
      expect(output).to include('IOS')
    end

    it 'does not exit with error' do
      expect(cli).not_to receive(:exit)
      cli.device('update', device_id, 'New iPhone Name')
    end
  end

  describe 'when device not found' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_raise(Mysigner::NotFoundError)
      
      cli.options = { platform: 'IOS' }
    end

    it 'shows device not found error' do
      output = capture_stdout { cli.device('update', device_id, 'New Name') }
      expect(output).to include('Device not found')
      expect(output).to include(device_id)
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('update', device_id, 'New Name')
    end
  end

  describe 'when API fails' do
    let(:get_response) {
      {
        data: {
          'id' => device_id,
          'name' => 'Old Name',
          'udid' => '00008110-000123456789ABCD',
          'platform' => 'IOS',
          'device_class' => 'IPHONE',
          'status' => 'ENABLED'
        }
      }
    }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(client).to receive(:get).and_return(get_response)
      allow(client).to receive(:patch).and_raise(Mysigner::ClientError.new('Connection timeout'))
      
      cli.options = { platform: 'IOS' }
    end

    it 'shows API error' do
      output = capture_stdout { cli.device('update', device_id, 'New Name') }
      expect(output).to include('Failed to update device')
      expect(output).to include('Connection timeout')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.device('update', device_id, 'New Name')
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'device']) }
      expect(help_output).to include('Manage devices')
    end

    it 'shows subcommands' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'device']) }
      expect(help_output).to include('add')
      expect(help_output).to include('update')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)
      
      output = capture_stdout { Mysigner::CLI.start(['device', 'update', device_id, 'New Name']) }
      expect(output).to include('Not logged in')
    end
  end
end

