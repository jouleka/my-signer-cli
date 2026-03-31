# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner merchant-ids and merchant-id', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }

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
    allow(cli).to receive(:exit)
    cli.options = { page: 1, per_page: 50 }
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
      allow(client).to receive(:get).and_return({ data: { 'merchant_ids' => [] } })
      allow(client).to receive(:post).and_return({ data: {} })
    end

    it 'shows error message for merchant-ids' do
      output = capture_stdout { cli.merchant_ids }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.merchant_ids }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.merchant_ids
    end
  end

  describe 'when logged in' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')
    end

    describe 'merchant-ids (list)' do
      context 'when merchant IDs exist' do
        let(:merchant_ids_response) do
          {
            data: {
              'merchant_ids' => [
                { 'id' => '1', 'identifier' => 'merchant.com.example.payments', 'name' => 'Example Payments',
                  'team_id' => 'ABC123' },
                { 'id' => '2', 'identifier' => 'merchant.com.example.store', 'name' => 'Example Store' }
              ],
              'pagination' => { 'page' => 1, 'total_pages' => 1, 'total' => 2 }
            }
          }
        end

        before do
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { page: 1, per_page: 50 })
            .and_return(merchant_ids_response)
        end

        it 'shows header' do
          output = capture_stdout { cli.merchant_ids }
          expect(output).to include('Merchant IDs')
        end

        it 'fetches merchant IDs from API' do
          expect(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { page: 1, per_page: 50 })
          cli.merchant_ids
        end

        it 'shows merchant ID identifiers' do
          output = capture_stdout { cli.merchant_ids }
          expect(output).to include('merchant.com.example.payments')
          expect(output).to include('merchant.com.example.store')
        end

        it 'shows merchant ID names when different from identifier' do
          output = capture_stdout { cli.merchant_ids }
          expect(output).to include('Example Payments')
          expect(output).to include('Example Store')
        end

        it 'shows team ID when present' do
          output = capture_stdout { cli.merchant_ids }
          expect(output).to include('Team: ABC123')
        end

        it 'shows pagination info' do
          output = capture_stdout { cli.merchant_ids }
          expect(output).to include('Page 1 of 1')
          expect(output).to include('2 total')
        end
      end

      context 'when no merchant IDs found' do
        let(:empty_response) do
          { data: { 'merchant_ids' => [] } }
        end

        before do
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { page: 1, per_page: 50 })
            .and_return(empty_response)
        end

        it 'shows no merchant IDs message' do
          output = capture_stdout { cli.merchant_ids }
          expect(output).to include('No Merchant IDs found')
        end

        it 'shows helpful tip' do
          output = capture_stdout { cli.merchant_ids }
          expect(output).to include('mysigner merchant-id create')
        end
      end

      context 'with search query' do
        let(:search_response) do
          {
            data: {
              'merchant_ids' => [
                { 'id' => '1', 'identifier' => 'merchant.com.example.payments', 'name' => 'Payments' }
              ]
            }
          }
        end

        before do
          cli.options = { page: 1, per_page: 50, search: 'payments' }
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { page: 1, per_page: 50, q: 'payments' })
            .and_return(search_response)
        end

        it 'sends search query to API' do
          expect(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { page: 1, per_page: 50, q: 'payments' })
          cli.merchant_ids
        end
      end

      context 'when API fails' do
        before do
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { page: 1, per_page: 50 })
            .and_raise(Mysigner::ClientError.new('Connection failed'))
        end

        it 'shows error message' do
          output = capture_stdout { cli.merchant_ids }
          expect(output).to include('Failed to fetch Merchant IDs')
          expect(output).to include('Connection failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.merchant_ids
        end
      end
    end

    describe 'merchant-id create' do
      context 'with valid identifier' do
        let(:success_response) do
          {
            data: {
              'merchant_id' => {
                'identifier' => 'merchant.com.company.app',
                'name' => 'merchant.com.company.app'
              }
            }
          }
        end

        before do
          cli.options = {}
          allow(client).to receive(:post).and_return(success_response)
        end

        it 'shows creating message' do
          output = capture_stdout { cli.merchant_id('create', 'merchant.com.company.app') }
          expect(output).to include('Creating Merchant ID')
        end

        it 'sends POST request to API' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/merchant_ids",
            body: { identifier: 'merchant.com.company.app', name: 'merchant.com.company.app' }
          )
          cli.merchant_id('create', 'merchant.com.company.app')
        end

        it 'shows success message' do
          output = capture_stdout { cli.merchant_id('create', 'merchant.com.company.app') }
          expect(output).to include('Merchant ID created successfully')
        end

        it 'shows the identifier' do
          output = capture_stdout { cli.merchant_id('create', 'merchant.com.company.app') }
          expect(output).to include('merchant.com.company.app')
        end
      end

      context 'with custom name' do
        let(:success_response) do
          {
            data: {
              'merchant_id' => {
                'identifier' => 'merchant.com.company.app',
                'name' => 'My Custom Payment'
              }
            }
          }
        end

        before do
          cli.options = { name: 'My Custom Payment' }
          allow(client).to receive(:post).and_return(success_response)
        end

        it 'uses the provided name' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/merchant_ids",
            body: { identifier: 'merchant.com.company.app', name: 'My Custom Payment' }
          )
          cli.merchant_id('create', 'merchant.com.company.app')
        end
      end

      context 'when identifier is missing' do
        before do
          cli.options = {}
        end

        it 'shows usage error' do
          output = capture_stdout { cli.merchant_id('create') }
          expect(output).to include('Usage: mysigner merchant-id create IDENTIFIER')
        end

        it 'shows example' do
          output = capture_stdout { cli.merchant_id('create') }
          expect(output).to include('merchant.com.company.app')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.merchant_id('create')
        end
      end

      context 'when identifier does not start with merchant.' do
        before do
          cli.options = {}
        end

        it 'shows error message' do
          output = capture_stdout { cli.merchant_id('create', 'com.company.app') }
          expect(output).to include("must start with 'merchant.'")
        end

        it 'shows example format' do
          output = capture_stdout { cli.merchant_id('create', 'com.company.app') }
          expect(output).to include('merchant.com.company.app')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.merchant_id('create', 'com.company.app')
        end
      end

      context 'when merchant ID already exists' do
        before do
          cli.options = {}
          allow(client).to receive(:post)
            .and_raise(Mysigner::ClientError.new('already exists'))
        end

        it 'shows already exists message' do
          output = capture_stdout { cli.merchant_id('create', 'merchant.com.existing.app') }
          expect(output).to include('Merchant ID already exists')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.merchant_id('create', 'merchant.com.existing.app')
        end
      end

      context 'when API fails' do
        before do
          cli.options = {}
          allow(client).to receive(:post)
            .and_raise(Mysigner::ClientError.new('API error'))
        end

        it 'shows error message' do
          output = capture_stdout { cli.merchant_id('create', 'merchant.com.company.app') }
          expect(output).to include('Failed to create Merchant ID')
          expect(output).to include('API error')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.merchant_id('create', 'merchant.com.company.app')
        end
      end
    end

    describe 'merchant-id delete' do
      context 'when merchant ID exists' do
        let(:list_response) do
          {
            data: {
              'merchant_ids' => [
                { 'id' => '42', 'identifier' => 'merchant.com.company.app' }
              ]
            }
          }
        end

        before do
          cli.options = {}
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { q: 'merchant.com.company.app' })
            .and_return(list_response)
          allow(client).to receive(:delete)
            .with("/api/v1/organizations/#{org_id}/merchant_ids/42")
            .and_return({ data: {} })
        end

        it 'shows deleting message' do
          output = capture_stdout { cli.merchant_id('delete', 'merchant.com.company.app') }
          expect(output).to include('Deleting Merchant ID')
        end

        it 'looks up merchant ID by identifier' do
          expect(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { q: 'merchant.com.company.app' })
          cli.merchant_id('delete', 'merchant.com.company.app')
        end

        it 'deletes the merchant ID by ID' do
          expect(client).to receive(:delete)
            .with("/api/v1/organizations/#{org_id}/merchant_ids/42")
          cli.merchant_id('delete', 'merchant.com.company.app')
        end

        it 'shows success message' do
          output = capture_stdout { cli.merchant_id('delete', 'merchant.com.company.app') }
          expect(output).to include('Merchant ID deleted')
        end
      end

      context 'when merchant ID not found' do
        let(:empty_response) do
          { data: { 'merchant_ids' => [] } }
        end

        before do
          cli.options = {}
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { q: 'merchant.com.nonexistent' })
            .and_return(empty_response)
        end

        it 'shows not found error' do
          output = capture_stdout { cli.merchant_id('delete', 'merchant.com.nonexistent') }
          expect(output).to include('Merchant ID not found')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.merchant_id('delete', 'merchant.com.nonexistent')
        end
      end

      context 'when identifier is missing' do
        before do
          cli.options = {}
        end

        it 'shows usage error' do
          output = capture_stdout { cli.merchant_id('delete') }
          expect(output).to include('Usage: mysigner merchant-id delete IDENTIFIER')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.merchant_id('delete')
        end
      end

      context 'when delete fails' do
        let(:list_response) do
          {
            data: {
              'merchant_ids' => [
                { 'id' => '42', 'identifier' => 'merchant.com.company.app' }
              ]
            }
          }
        end

        before do
          cli.options = {}
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/merchant_ids", params: { q: 'merchant.com.company.app' })
            .and_return(list_response)
          allow(client).to receive(:delete)
            .and_raise(Mysigner::ClientError.new('Delete failed'))
        end

        it 'shows error message' do
          output = capture_stdout { cli.merchant_id('delete', 'merchant.com.company.app') }
          expect(output).to include('Failed to delete Merchant ID')
          expect(output).to include('Delete failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.merchant_id('delete', 'merchant.com.company.app')
        end
      end
    end

    describe 'unknown action' do
      before do
        cli.options = {}
      end

      it 'shows error for unknown action' do
        output = capture_stdout { cli.merchant_id('unknown') }
        expect(output).to include('Unknown action')
      end

      it 'shows available actions' do
        output = capture_stdout { cli.merchant_id('unknown') }
        expect(output).to include('merchant-id create')
        expect(output).to include('merchant-id delete')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.merchant_id('unknown')
      end
    end
  end

  describe 'help text' do
    it 'has description for merchant-ids' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help merchant-ids]) }
      expect(help_output).to include('Merchant ID')
    end

    it 'has description for merchant-id' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help merchant-id]) }
      expect(help_output).to include('Merchant ID')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['merchant-ids']) }
      expect(output).to include('Not logged in')
    end
  end
end
