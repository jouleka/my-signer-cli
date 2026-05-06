# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner certificates', type: :cli do
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
                                                  data: { 'certificates' => [],
                                                          'pagination' => { 'page' => 1, 'total_pages' => 0,
                                                                            'total' => 0 } }
                                                })
    end

    it 'shows error message' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.certificates
    end
  end

  describe 'when no certificates found' do
    let(:api_response) do
      {
        data: {
          'certificates' => [],
          'pagination' => { 'page' => 1, 'total_pages' => 0, 'total' => 0 }
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
      allow(client).to receive(:get).and_return(api_response)
      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows header' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Signing Certificates')
    end

    it 'shows no certificates message' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('No certificates found')
    end

    it 'shows helpful tip' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('synced automatically from App Store Connect')
    end
  end

  describe 'listing certificates successfully' do
    let(:api_response) do
      {
        data: {
          'certificates' => [
            {
              'id' => '1',
              'name' => 'iOS Distribution Certificate',
              'certificate_type' => 'DISTRIBUTION',
              'serial_number' => 'ABC123',
              'status' => 'ACTIVE',
              'expires_at' => '2025-12-31T23:59:59Z'
            },
            {
              'id' => '2',
              'name' => 'iOS Development Certificate',
              'certificate_type' => 'DEVELOPMENT',
              'serial_number' => 'DEF456',
              'status' => 'EXPIRED',
              'expires_at' => '2023-01-01T00:00:00Z'
            }
          ],
          'pagination' => { 'page' => 1, 'total_pages' => 1, 'total' => 2 }
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
      allow(client).to receive(:get).and_return(api_response)
      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows header' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Signing Certificates')
    end

    it 'displays all certificates' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('iOS Distribution Certificate')
      expect(output).to include('iOS Development Certificate')
    end

    it 'shows certificate IDs' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('ID: 1')
      expect(output).to include('ID: 2')
    end

    it 'shows certificate types' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Type: DISTRIBUTION')
      expect(output).to include('Type: DEVELOPMENT')
    end

    it 'shows serial numbers' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Serial: ABC123')
      expect(output).to include('Serial: DEF456')
    end

    it 'shows status' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Status: ACTIVE')
      expect(output).to include('Status: EXPIRED')
    end

    it 'shows expiration dates' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Expires: 2025-12-31')
      expect(output).to include('Expires: 2023-01-01')
    end

    it 'shows active certificates with checkmark' do
      output = capture_stdout { cli.certificates }
      expect(output).to match(/✓.*iOS Distribution Certificate/)
    end

    it 'shows expired certificates with X' do
      output = capture_stdout { cli.certificates }
      expect(output).to match(/✗.*iOS Development Certificate/)
    end

    it 'shows pagination info' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Page 1 of 1')
      expect(output).to include('2 total')
    end
  end

  describe 'filtering by type' do
    let(:api_response) do
      {
        data: {
          'certificates' => [
            {
              'id' => '1',
              'name' => 'iOS Distribution Certificate',
              'certificate_type' => 'DISTRIBUTION',
              'serial_number' => 'ABC123',
              'status' => 'ACTIVE',
              'expires_at' => '2025-12-31T23:59:59Z'
            }
          ],
          'pagination' => { 'page' => 1, 'total_pages' => 1, 'total' => 1 }
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
      allow(client).to receive(:get).and_return(api_response)
      cli.options = { page: 1, per_page: 50, type: 'distribution' }
    end

    it 'sends type filter to API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/certificates",
        params: hash_including(certificate_type: 'DISTRIBUTION')
      )
      cli.certificates
    end

    it 'displays filtered certificates' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('iOS Distribution Certificate')
    end
  end

  describe 'filtering by status' do
    let(:api_response) do
      {
        data: {
          'certificates' => [],
          'pagination' => { 'page' => 1, 'total_pages' => 0, 'total' => 0 }
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
      allow(client).to receive(:get).and_return(api_response)
      cli.options = { page: 1, per_page: 50, status: 'active' }
    end

    it 'sends status filter to API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/certificates",
        params: hash_including(status: 'ACTIVE')
      )
      cli.certificates
    end
  end

  describe 'searching certificates' do
    let(:api_response) do
      {
        data: {
          'certificates' => [],
          'pagination' => { 'page' => 1, 'total_pages' => 0, 'total' => 0 }
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
      allow(client).to receive(:get).and_return(api_response)
      cli.options = { page: 1, per_page: 50, search: 'Distribution' }
    end

    it 'sends search query to API' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/certificates",
        params: hash_including(q: 'Distribution')
      )
      cli.certificates
    end
  end

  describe 'pagination' do
    let(:api_response) do
      {
        data: {
          'certificates' => [
            {
              'id' => '1',
              'name' => 'Certificate 1',
              'certificate_type' => 'DISTRIBUTION',
              'serial_number' => 'ABC123',
              'status' => 'ACTIVE',
              'expires_at' => '2025-12-31T23:59:59Z'
            }
          ],
          'pagination' => { 'page' => 1, 'total_pages' => 3, 'total' => 150 }
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
      allow(client).to receive(:get).and_return(api_response)
      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows pagination info' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Page 1 of 3')
      expect(output).to include('150 total')
    end

    it 'shows next page hint when more pages available' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Run with --page 2 to see more')
    end

    context 'on last page' do
      before do
        api_response[:data]['pagination'] = { 'page' => 3, 'total_pages' => 3, 'total' => 150 }
        cli.options = { page: 3, per_page: 50 }
      end

      it 'does not show next page hint' do
        output = capture_stdout { cli.certificates }
        expect(output).not_to include('to see more')
      end
    end
  end

  describe 'error handling' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).and_raise(Mysigner::ClientError.new('API error'))
      cli.options = { page: 1, per_page: 50 }
    end

    it 'shows error message' do
      output = capture_stdout { cli.certificates }
      expect(output).to include('Failed to fetch certificates')
      expect(output).to include('API error')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.certificates
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help certificates]) }
      expect(help_output).to include('List signing certificates')
    end

    it 'shows filter options' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help certificates]) }
      expect(help_output).to include('--type')
      expect(help_output).to include('--status')
      expect(help_output).to include('--search')
    end

    it 'shows pagination options' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help certificates]) }
      expect(help_output).to include('--page')
      expect(help_output).to include('--per-page')
    end
  end

  describe 'integration tests', :integration do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['certificates']) }
      expect(output).to include('Not logged in')
    end
  end
end
