# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner orgs', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:user_email) { 'developer@example.com' }

  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  rescue SystemExit
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  def stub_logged_in_config(current_organization_id:, organization_ids:, org_names:, token_org_ids:)
    allow(config).to receive(:exists?).and_return(true)
    allow(config).to receive(:load)
    allow(config).to receive(:api_url).and_return(api_url)
    allow(config).to receive(:api_token).and_return(api_token)
    allow(config).to receive(:user_email).and_return(user_email)
    allow(config).to receive(:current_organization_id).and_return(current_organization_id)
    allow(config).to receive(:organization_ids).and_return(organization_ids)
    allow(config).to receive(:has_token_for_org?) { |org_id| token_org_ids.include?(org_id) }
    allow(config).to receive(:org_name) { |org_id| org_names[org_id] }
  end

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(Mysigner::Client).to receive(:new).and_return(client)
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
    end

    it 'shows the login guidance' do
      output = capture_stdout { cli.orgs }

      expect(output).to include("Not logged in. Run 'mysigner login' first.")
    end

    it 'exits with status 1' do
      expect { cli.orgs }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe 'when there are no organizations' do
    before do
      stub_logged_in_config(current_organization_id: nil, organization_ids: [], org_names: {}, token_org_ids: [])
      allow(client).to receive(:get).with('/api/v1/user/organizations').and_return(data: { 'organizations' => [] })
    end

    it 'shows an empty state' do
      output = capture_stdout { cli.orgs }

      expect(output).to include('Organizations')
      expect(output).to include('No organizations found')
      expect(output).not_to include('Total:')
    end
  end

  describe 'when organizations are available' do
    let(:api_response) do
      {
        data: {
          'organizations' => [
            { 'id' => 'org-123', 'name' => 'Current Org', 'role' => 'admin', 'member_count' => 5 },
            { 'id' => 'org-456', 'name' => 'Another Org', 'role' => 'developer', 'member_count' => 3 }
          ]
        }
      }
    end

    before do
      stub_logged_in_config(
        current_organization_id: 'org-123',
        organization_ids: %w[org-123 org-456],
        org_names: { 'org-123' => 'Current Org', 'org-456' => 'Another Org' },
        token_org_ids: ['org-123']
      )
      allow(client).to receive(:get).with('/api/v1/user/organizations').and_return(api_response)
    end

    it 'shows the merged organization list with token state' do
      output = capture_stdout { cli.orgs }

      expect(output).to include('✓ Current Org (current)')
      expect(output).to include('ID: org-123 | Role: admin | Members: 5')
      expect(output).to include('⚠️ Another Org')
      expect(output).to include('ID: org-456 | Role: developer | Members: 3')
      expect(output).to include('Total: 2 organization(s)')
      expect(output).to include('Legend: ✓ = Has token | ⚠️  = Need token')
      expect(output).to include("Tip: Use 'mysigner switch' to change organizations")
    end
  end

  describe 'when only a saved organization name is available' do
    before do
      stub_logged_in_config(
        current_organization_id: 'org-123',
        organization_ids: ['org-123'],
        org_names: { 'org-123' => 'Saved Org' },
        token_org_ids: ['org-123']
      )
      allow(client).to receive(:get).with('/api/v1/user/organizations').and_return(data: { 'organizations' => [] })
    end

    it 'shows the saved organization entry' do
      output = capture_stdout { cli.orgs }

      expect(output).to include('✓ Saved Org (current)')
      expect(output).to include('ID: org-123 | Token saved')
    end
  end

  describe 'error handling' do
    before do
      stub_logged_in_config(
        current_organization_id: 'org-123',
        organization_ids: ['org-123'],
        org_names: { 'org-123' => 'Current Org' },
        token_org_ids: ['org-123']
      )
    end

    it 'shows a client error and exits' do
      allow(client).to receive(:get).with('/api/v1/user/organizations').and_raise(Mysigner::ClientError.new('Connection failed'))

      output = capture_stdout { cli.orgs }

      expect(output).to include('Failed to fetch organizations: Connection failed')
      expect { cli.orgs }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe 'help text' do
    it 'uses the current description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help orgs]) }

      expect(help_output).to include("List all organizations you're a member of")
    end
  end
end
