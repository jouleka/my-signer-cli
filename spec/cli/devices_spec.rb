# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner devices', type: :cli do
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
      allow(client).to receive(:get).and_return({
                                                  data: {
                                                    'devices' => [],
                                                    'pagination' => { 'page' => 1, 'per_page' => 50,
                                                                      'total_pages' => 0, 'total' => 0 }
                                                  }
                                                })
    end

    it 'shows error message' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.devices }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.devices
    end
  end

  describe 'when no devices found' do
    let(:empty_response) do
      {
        data: {
          'devices' => [],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 0,
            'total' => 0
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
      allow(client).to receive(:get).and_return(empty_response)

      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows header' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Devices')
    end

    it 'shows no devices message' do
      output = capture_stdout { cli.devices }
      expect(output).to include('No devices found')
    end

    it 'shows helpful tip' do
      output = capture_stdout { cli.devices }
      expect(output).to include('mysigner device add')
    end

    it 'does not exit with error' do
      expect(cli).not_to receive(:exit)
      cli.devices
    end
  end

  describe 'list devices' do
    let(:devices_response) do
      {
        data: {
          'devices' => [
            {
              'id' => 'dev_1',
              'name' => 'iPhone 15 Pro',
              'udid' => '00008110-000123456789ABCD',
              'platform' => 'IOS',
              'device_class' => 'IPHONE',
              'status' => 'ENABLED'
            },
            {
              'id' => 'dev_2',
              'name' => 'iPad Air',
              'udid' => '00008103-987654321FEDCBA0',
              'platform' => 'IOS',
              'device_class' => 'IPAD',
              'status' => 'DISABLED'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 1,
            'total' => 2
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
      allow(client).to receive(:get).and_return(devices_response)

      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows header' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Devices')
    end

    it 'fetches devices from API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/devices",
        params: { page: 1, per_page: 50 }
      )
      cli.devices
    end

    it 'shows device names' do
      output = capture_stdout { cli.devices }
      expect(output).to include('iPhone 15 Pro')
      expect(output).to include('iPad Air')
    end

    it 'shows device UDIDs' do
      output = capture_stdout { cli.devices }
      expect(output).to include('00008110-000123456789ABCD')
      expect(output).to include('00008103-987654321FEDCBA0')
    end

    it 'shows device platforms' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Platform: IOS')
    end

    it 'shows device classes' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Class: IPHONE')
      expect(output).to include('Class: IPAD')
    end

    it 'shows device status' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Status: ENABLED')
      expect(output).to include('Status: DISABLED')
    end

    it 'shows enabled status with checkmark' do
      output = capture_stdout { cli.devices }
      expect(output).to include('✓ iPhone 15 Pro')
    end

    it 'shows disabled status with X' do
      output = capture_stdout { cli.devices }
      expect(output).to include('✗ iPad Air')
    end

    it 'shows pagination info' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Page 1 of 1')
      expect(output).to include('2 total')
    end

    it 'does not show next page hint when on last page' do
      output = capture_stdout { cli.devices }
      expect(output).not_to include('to see more')
    end
  end

  describe 'with platform filter' do
    let(:devices_response) do
      {
        data: {
          'devices' => [
            {
              'id' => 'dev_1',
              'name' => 'MacBook Pro',
              'udid' => 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX',
              'platform' => 'MAC_OS',
              'device_class' => 'MAC',
              'status' => 'ENABLED'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 1,
            'total' => 1
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
      allow(client).to receive(:get).and_return(devices_response)

      cli.options = { page: 1, per_page: 50, platform: 'mac_os' }
    end

    it 'sends platform filter to API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/devices",
        params: { page: 1, per_page: 50, platform: 'MAC_OS' }
      )
      cli.devices
    end

    it 'shows filtered devices' do
      output = capture_stdout { cli.devices }
      expect(output).to include('MacBook Pro')
      expect(output).to include('MAC_OS')
    end
  end

  describe 'with status filter' do
    let(:devices_response) do
      {
        data: {
          'devices' => [
            {
              'id' => 'dev_1',
              'name' => 'iPhone 15 Pro',
              'udid' => '00008110-000123456789ABCD',
              'platform' => 'IOS',
              'device_class' => 'IPHONE',
              'status' => 'ENABLED'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 1,
            'total' => 1
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
      allow(client).to receive(:get).and_return(devices_response)

      cli.options = { page: 1, per_page: 50, status: 'enabled' }
    end

    it 'sends status filter to API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/devices",
        params: { page: 1, per_page: 50, status: 'ENABLED' }
      )
      cli.devices
    end

    it 'shows only enabled devices' do
      output = capture_stdout { cli.devices }
      expect(output).to include('iPhone 15 Pro')
      expect(output).to include('✓')
    end
  end

  describe 'with search query' do
    let(:devices_response) do
      {
        data: {
          'devices' => [
            {
              'id' => 'dev_1',
              'name' => 'iPhone 15 Pro',
              'udid' => '00008110-000123456789ABCD',
              'platform' => 'IOS',
              'device_class' => 'IPHONE',
              'status' => 'ENABLED'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 50,
            'total_pages' => 1,
            'total' => 1
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
      allow(client).to receive(:get).and_return(devices_response)

      cli.options = { page: 1, per_page: 50, search: 'iPhone 15' }
    end

    it 'sends search query to API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/devices",
        params: { page: 1, per_page: 50, q: 'iPhone 15' }
      )
      cli.devices
    end

    it 'shows search results' do
      output = capture_stdout { cli.devices }
      expect(output).to include('iPhone 15 Pro')
    end
  end

  describe 'with pagination' do
    let(:devices_response) do
      {
        data: {
          'devices' => [
            {
              'id' => 'dev_1',
              'name' => 'Device 1',
              'udid' => '00008110-000000000000001',
              'platform' => 'IOS',
              'device_class' => 'IPHONE',
              'status' => 'ENABLED'
            }
          ],
          'pagination' => {
            'page' => 1,
            'per_page' => 1,
            'total_pages' => 5,
            'total' => 5
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
      allow(client).to receive(:get).and_return(devices_response)

      cli.options = { page: 1, per_page: 1 }
    end

    it 'shows current page number' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Page 1 of 5')
    end

    it 'shows total count' do
      output = capture_stdout { cli.devices }
      expect(output).to include('5 total')
    end

    it 'shows next page hint when not on last page' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Run with --page 2 to see more')
    end
  end

  describe 'when API fails' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).and_raise(Mysigner::ClientError.new('Connection failed'))

      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows error message' do
      output = capture_stdout { cli.devices }
      expect(output).to include('Failed to fetch devices')
      expect(output).to include('Connection failed')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.devices
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help devices]) }
      expect(help_output).to include('List registered test devices')
    end

    it 'shows platform option' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help devices]) }
      expect(help_output).to include('--platform')
    end

    it 'shows status option' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help devices]) }
      expect(help_output).to include('--status')
    end

    it 'shows search option' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help devices]) }
      expect(help_output).to include('--search')
    end

    it 'shows pagination options' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help devices]) }
      expect(help_output).to include('--page')
      expect(help_output).to include('--per-page')
    end
  end

  describe 'integration tests', :integration do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['devices']) }
      expect(output).to include('Not logged in')
    end
  end
end
