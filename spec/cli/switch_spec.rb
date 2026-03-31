# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner switch', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:user_email) { 'dev@example.com' }
  let(:current_org_id) { '123' }

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

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(Mysigner::Client).to receive(:new).and_return(client)
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
    end

    it 'shows the login guidance and exits' do
      output = capture_stdout { cli.switch }

      expect(output).to include("Not logged in. Run 'mysigner login' first.")
      expect { cli.switch }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe 'when only one organization is available' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:user_email).and_return(user_email)
      allow(config).to receive(:current_organization_id).and_return(current_org_id)
      allow(config).to receive(:organization_ids).and_return([current_org_id])
      allow(client).to receive(:get).with("/api/v1/organizations/#{current_org_id}").and_return(
        data: { 'id' => current_org_id, 'name' => 'Only Organization' }
      )
      allow(client).to receive(:get).with('/api/v1/user/organizations').and_return(
        data: {
          'organizations' => [
            { 'id' => current_org_id, 'name' => 'Only Organization', 'role' => 'admin', 'member_count' => 5 }
          ]
        }
      )
    end

    it 'shows that there is nothing to switch to' do
      output = capture_stdout { cli.switch }

      expect(output).to include('Switch Organization')
      expect(output).to include('Current organization:')
      expect(output).to include('Only Organization')
      expect(output).to include('You only have access to one organization.')
      expect(output).to include('Nothing to switch to!')
      expect(output).not_to include('Select organization')
    end
  end

  describe 'when switching to another saved organization' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:user_email).and_return(user_email)
      allow(config).to receive(:current_organization_id).and_return(current_org_id)
      allow(config).to receive(:organization_ids).and_return(%w[123 456])
      allow(config).to receive(:has_token_for_org?).with('123').and_return(true)
      allow(config).to receive(:has_token_for_org?).with('456').and_return(true)
      allow(config).to receive(:org_name).with('123').and_return('Current Org')
      allow(config).to receive(:org_name).with('456').and_return('Another Org')
      allow(config).to receive(:current_organization_id=).with('456')
      allow(config).to receive(:save)
      allow(client).to receive(:get).with("/api/v1/organizations/#{current_org_id}").and_return(
        data: { 'id' => current_org_id, 'name' => 'Current Org' }
      )
      allow(client).to receive(:get).with('/api/v1/user/organizations').and_return(
        data: {
          'organizations' => [
            { 'id' => '123', 'name' => 'Current Org', 'role' => 'admin', 'member_count' => 5 },
            { 'id' => '456', 'name' => 'Another Org', 'role' => 'developer', 'member_count' => 10 }
          ]
        }
      )
      allow(cli).to receive(:ask).and_return('2')
    end

    it 'switches and saves the new current organization' do
      output = capture_stdout { cli.switch }

      expect(output).to include('Available organizations:')
      expect(output).to include('1. ✓ Current Org (current)')
      expect(output).to include('2. ✓ Another Org')
      expect(output).to include('Successfully switched to: Another Org')
      expect(output).to include("Run 'mysigner status' to verify your new configuration")
      expect(config).to have_received(:current_organization_id=).with('456')
      expect(config).to have_received(:save)
    end
  end

  describe 'when switching to an organization without a saved token' do
    let(:validation_client) { instance_double(Mysigner::Client) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:user_email).and_return(user_email)
      allow(config).to receive(:current_organization_id).and_return(current_org_id)
      allow(config).to receive(:organization_ids).and_return(%w[123 456])
      allow(config).to receive(:has_token_for_org?).with('123').and_return(true)
      allow(config).to receive(:has_token_for_org?).with('456').and_return(false)
      allow(config).to receive(:org_name).with('123').and_return('Current Org')
      allow(config).to receive(:org_name).with('456').and_return('Another Org')
      allow(config).to receive(:save_token_for_org).with('456', 'Another Org', 'new_token_456')
      allow(config).to receive(:current_organization_id=).with('456')
      allow(config).to receive(:save)
      allow(client).to receive(:get).with("/api/v1/organizations/#{current_org_id}").and_return(
        data: { 'id' => current_org_id, 'name' => 'Current Org' }
      )
      allow(client).to receive(:get).with('/api/v1/user/organizations').and_return(
        data: {
          'organizations' => [
            { 'id' => '123', 'name' => 'Current Org', 'role' => 'admin', 'member_count' => 5 },
            { 'id' => '456', 'name' => 'Another Org', 'role' => 'developer', 'member_count' => 10 }
          ]
        }
      )
      allow(Mysigner::Client).to receive(:new).and_return(client, validation_client)
      allow(validation_client).to receive(:get).with('/api/v1/organizations/456').and_return(
        data: { 'id' => '456', 'name' => 'Another Org', 'token_organization_id' => '456' }
      )
      allow(cli).to receive(:ask).and_return('2', 'new_token_456')
    end

    it 'prompts for and saves a new org token before switching' do
      output = capture_stdout { cli.switch }

      expect(output).to include("You don't have a token for 'Another Org' yet.")
      expect(output).to include('Token validated successfully')
      expect(output).to include('Successfully switched to: Another Org')
      expect(config).to have_received(:save_token_for_org).with('456', 'Another Org', 'new_token_456')
      expect(config).to have_received(:current_organization_id=).with('456')
    end
  end

  describe 'error handling' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:user_email).and_return(user_email)
      allow(config).to receive(:current_organization_id).and_return(current_org_id)
    end

    it 'surfaces client errors and exits' do
      allow(client).to receive(:get).with("/api/v1/organizations/#{current_org_id}").and_raise(
        Mysigner::ClientError.new('Organization not found')
      )

      output = capture_stdout { cli.switch }

      expect(output).to include('Failed to switch organization')
      expect(output).to include('Organization not found')
      expect { cli.switch }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe 'help text' do
    it 'matches the current command description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help switch]) }

      expect(help_output).to include('Switch to a different organization')
      expect(help_output).to include('organization-specific tokens')
      expect(help_output).to include('same user in all organizations')
    end
  end
end
