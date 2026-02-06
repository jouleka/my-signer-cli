# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner app-groups and app-group', type: :cli do
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
      allow(client).to receive(:get).and_return({ data: { 'app_groups' => [] } })
      allow(client).to receive(:post).and_return({ data: {} })
    end

    it 'shows error message for app-groups' do
      output = capture_stdout { cli.app_groups }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.app_groups }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.app_groups
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

    describe 'app-groups (list)' do
      context 'when app groups exist' do
        let(:app_groups_response) {
          {
            data: {
              'app_groups' => [
                { 'id' => '1', 'identifier' => 'group.com.example.shared', 'name' => 'Shared Data', 'team_id' => 'ABC123' },
                { 'id' => '2', 'identifier' => 'group.com.example.widgets', 'name' => 'Widgets' }
              ],
              'pagination' => { 'page' => 1, 'total_pages' => 1, 'total' => 2 }
            }
          }
        }

        before do
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { page: 1, per_page: 50 })
            .and_return(app_groups_response)
        end

        it 'shows header' do
          output = capture_stdout { cli.app_groups }
          expect(output).to include('App Groups')
        end

        it 'fetches app groups from API' do
          expect(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { page: 1, per_page: 50 })
          cli.app_groups
        end

        it 'shows app group identifiers' do
          output = capture_stdout { cli.app_groups }
          expect(output).to include('group.com.example.shared')
          expect(output).to include('group.com.example.widgets')
        end

        it 'shows app group names when different from identifier' do
          output = capture_stdout { cli.app_groups }
          expect(output).to include('Shared Data')
          expect(output).to include('Widgets')
        end

        it 'shows team ID when present' do
          output = capture_stdout { cli.app_groups }
          expect(output).to include('Team: ABC123')
        end

        it 'shows pagination info' do
          output = capture_stdout { cli.app_groups }
          expect(output).to include('Page 1 of 1')
          expect(output).to include('2 total')
        end
      end

      context 'when no app groups found' do
        let(:empty_response) {
          { data: { 'app_groups' => [] } }
        }

        before do
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { page: 1, per_page: 50 })
            .and_return(empty_response)
        end

        it 'shows no app groups message' do
          output = capture_stdout { cli.app_groups }
          expect(output).to include('No App Groups found')
        end

        it 'shows helpful tip' do
          output = capture_stdout { cli.app_groups }
          expect(output).to include('mysigner app-group register')
        end

        it 'shows Apple Developer Portal note' do
          output = capture_stdout { cli.app_groups }
          expect(output).to include('Apple Developer Portal')
        end
      end

      context 'with search query' do
        let(:search_response) {
          {
            data: {
              'app_groups' => [
                { 'id' => '1', 'identifier' => 'group.com.example.shared', 'name' => 'Shared' }
              ]
            }
          }
        }

        before do
          cli.options = { page: 1, per_page: 50, search: 'shared' }
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { page: 1, per_page: 50, q: 'shared' })
            .and_return(search_response)
        end

        it 'sends search query to API' do
          expect(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { page: 1, per_page: 50, q: 'shared' })
          cli.app_groups
        end
      end

      context 'when API fails' do
        before do
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { page: 1, per_page: 50 })
            .and_raise(Mysigner::ClientError.new('Connection failed'))
        end

        it 'shows error message' do
          output = capture_stdout { cli.app_groups }
          expect(output).to include('Failed to fetch App Groups')
          expect(output).to include('Connection failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.app_groups
        end
      end
    end

    describe 'app-group register' do
      context 'with valid identifier' do
        let(:success_response) {
          {
            data: {
              'app_group' => {
                'identifier' => 'group.com.company.shared',
                'name' => 'group.com.company.shared'
              }
            }
          }
        }

        before do
          cli.options = {}
          allow(client).to receive(:post).and_return(success_response)
        end

        it 'shows registering message' do
          output = capture_stdout { cli.app_group('register', 'group.com.company.shared') }
          expect(output).to include('Registering App Group')
        end

        it 'sends POST request to API' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/app_groups",
            body: { identifier: 'group.com.company.shared', name: 'group.com.company.shared' }
          )
          cli.app_group('register', 'group.com.company.shared')
        end

        it 'shows success message' do
          output = capture_stdout { cli.app_group('register', 'group.com.company.shared') }
          expect(output).to include('App Group registered')
        end

        it 'shows the identifier' do
          output = capture_stdout { cli.app_group('register', 'group.com.company.shared') }
          expect(output).to include('group.com.company.shared')
        end

        it 'shows Apple Developer Portal reminder' do
          output = capture_stdout { cli.app_group('register', 'group.com.company.shared') }
          expect(output).to include('Apple Developer Portal')
        end
      end

      context 'with custom name' do
        let(:success_response) {
          {
            data: {
              'app_group' => {
                'identifier' => 'group.com.company.shared',
                'name' => 'My Shared Data'
              }
            }
          }
        }

        before do
          cli.options = { name: 'My Shared Data' }
          allow(client).to receive(:post).and_return(success_response)
        end

        it 'uses the provided name' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/app_groups",
            body: { identifier: 'group.com.company.shared', name: 'My Shared Data' }
          )
          cli.app_group('register', 'group.com.company.shared')
        end
      end

      context 'when identifier is missing' do
        before do
          cli.options = {}
        end

        it 'shows usage error' do
          output = capture_stdout { cli.app_group('register') }
          expect(output).to include('Usage: mysigner app-group register IDENTIFIER')
        end

        it 'shows example' do
          output = capture_stdout { cli.app_group('register') }
          expect(output).to include('group.com.company.shared')
        end

        it 'shows Apple Developer Portal note' do
          output = capture_stdout { cli.app_group('register') }
          expect(output).to include('Create the App Group in Apple Developer Portal first')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.app_group('register')
        end
      end

      context 'when identifier does not start with group.' do
        before do
          cli.options = {}
        end

        it 'shows error message' do
          output = capture_stdout { cli.app_group('register', 'com.company.shared') }
          expect(output).to include("must start with 'group.'")
        end

        it 'shows example format' do
          output = capture_stdout { cli.app_group('register', 'com.company.shared') }
          expect(output).to include('group.com.company.shared')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.app_group('register', 'com.company.shared')
        end
      end

      context 'when app group already exists' do
        before do
          cli.options = {}
          allow(client).to receive(:post)
            .and_raise(Mysigner::ClientError.new('already exists'))
        end

        it 'shows already registered message' do
          output = capture_stdout { cli.app_group('register', 'group.com.existing.shared') }
          expect(output).to include('App Group already registered')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.app_group('register', 'group.com.existing.shared')
        end
      end

      context 'when API fails' do
        before do
          cli.options = {}
          allow(client).to receive(:post)
            .and_raise(Mysigner::ClientError.new('API error'))
        end

        it 'shows error message' do
          output = capture_stdout { cli.app_group('register', 'group.com.company.shared') }
          expect(output).to include('Failed to register App Group')
          expect(output).to include('API error')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.app_group('register', 'group.com.company.shared')
        end
      end
    end

    describe 'app-group delete' do
      context 'when app group exists' do
        let(:list_response) {
          {
            data: {
              'app_groups' => [
                { 'id' => '42', 'identifier' => 'group.com.company.shared' }
              ]
            }
          }
        }

        before do
          cli.options = {}
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { q: 'group.com.company.shared' })
            .and_return(list_response)
          allow(client).to receive(:delete)
            .with("/api/v1/organizations/#{org_id}/app_groups/42")
            .and_return({ data: {} })
        end

        it 'shows removing message' do
          output = capture_stdout { cli.app_group('delete', 'group.com.company.shared') }
          expect(output).to include('Removing App Group')
        end

        it 'looks up app group by identifier' do
          expect(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { q: 'group.com.company.shared' })
          cli.app_group('delete', 'group.com.company.shared')
        end

        it 'deletes the app group by ID' do
          expect(client).to receive(:delete)
            .with("/api/v1/organizations/#{org_id}/app_groups/42")
          cli.app_group('delete', 'group.com.company.shared')
        end

        it 'shows success message' do
          output = capture_stdout { cli.app_group('delete', 'group.com.company.shared') }
          expect(output).to include('App Group removed from My Signer')
        end

        it 'shows Apple Developer Portal note' do
          output = capture_stdout { cli.app_group('delete', 'group.com.company.shared') }
          expect(output).to include('still exists in Apple Developer Portal')
        end
      end

      context 'when app group not found' do
        let(:empty_response) {
          { data: { 'app_groups' => [] } }
        }

        before do
          cli.options = {}
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { q: 'group.com.nonexistent' })
            .and_return(empty_response)
        end

        it 'shows not found error' do
          output = capture_stdout { cli.app_group('delete', 'group.com.nonexistent') }
          expect(output).to include('App Group not found')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.app_group('delete', 'group.com.nonexistent')
        end
      end

      context 'when identifier is missing' do
        before do
          cli.options = {}
        end

        it 'shows usage error' do
          output = capture_stdout { cli.app_group('delete') }
          expect(output).to include('Usage: mysigner app-group delete IDENTIFIER')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.app_group('delete')
        end
      end

      context 'when delete fails' do
        let(:list_response) {
          {
            data: {
              'app_groups' => [
                { 'id' => '42', 'identifier' => 'group.com.company.shared' }
              ]
            }
          }
        }

        before do
          cli.options = {}
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/app_groups", params: { q: 'group.com.company.shared' })
            .and_return(list_response)
          allow(client).to receive(:delete)
            .and_raise(Mysigner::ClientError.new('Delete failed'))
        end

        it 'shows error message' do
          output = capture_stdout { cli.app_group('delete', 'group.com.company.shared') }
          expect(output).to include('Failed to remove App Group')
          expect(output).to include('Delete failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.app_group('delete', 'group.com.company.shared')
        end
      end
    end

    describe 'unknown action' do
      before do
        cli.options = {}
      end

      it 'shows error for unknown action' do
        output = capture_stdout { cli.app_group('unknown') }
        expect(output).to include('Unknown action')
      end

      it 'shows available actions' do
        output = capture_stdout { cli.app_group('unknown') }
        expect(output).to include('app-group register')
        expect(output).to include('app-group delete')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.app_group('unknown')
      end
    end
  end

  describe 'help text' do
    it 'has description for app-groups' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'app-groups']) }
      expect(help_output).to include('App Group')
    end

    it 'has description for app-group' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'app-group']) }
      expect(help_output).to include('App Group')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['app-groups']) }
      expect(output).to include('Not logged in')
    end
  end
end
