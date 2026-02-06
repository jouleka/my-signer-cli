# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner bundleid', type: :cli do
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
      allow(client).to receive(:get).and_return({ data: { 'bundle_ids' => [] } })
      allow(client).to receive(:post).and_return({ data: {} })
    end

    it 'shows error message for list' do
      output = capture_stdout { cli.bundleid('list') }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.bundleid('list') }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.bundleid('list')
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

    describe 'bundleid list' do
      context 'when bundle IDs exist' do
        let(:bundle_ids_response) {
          {
            data: {
              'bundle_ids' => [
                { 'identifier' => 'com.example.app', 'name' => 'Example App' },
                { 'identifier' => 'com.example.widget', 'name' => 'Example Widget' }
              ]
            }
          }
        }

        before do
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/bundle_ids")
            .and_return(bundle_ids_response)
        end

        it 'shows header' do
          output = capture_stdout { cli.bundleid('list') }
          expect(output).to include('Registered Bundle IDs')
        end

        it 'fetches bundle IDs from API' do
          expect(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/bundle_ids")
          cli.bundleid('list')
        end

        it 'shows bundle ID names' do
          output = capture_stdout { cli.bundleid('list') }
          expect(output).to include('Example App')
          expect(output).to include('Example Widget')
        end

        it 'shows bundle ID identifiers' do
          output = capture_stdout { cli.bundleid('list') }
          expect(output).to include('com.example.app')
          expect(output).to include('com.example.widget')
        end
      end

      context 'when no bundle IDs found' do
        let(:empty_response) {
          { data: { 'bundle_ids' => [] } }
        }

        before do
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/bundle_ids")
            .and_return(empty_response)
        end

        it 'shows no bundle IDs message' do
          output = capture_stdout { cli.bundleid('list') }
          expect(output).to include('No Bundle IDs found')
        end

        it 'shows helpful tip' do
          output = capture_stdout { cli.bundleid('list') }
          expect(output).to include('mysigner bundleid register')
        end
      end

      context 'when API fails' do
        before do
          allow(client).to receive(:get)
            .with("/api/v1/organizations/#{org_id}/bundle_ids")
            .and_raise(Mysigner::ClientError.new('Connection failed'))
        end

        it 'shows error message' do
          output = capture_stdout { cli.bundleid('list') }
          expect(output).to include('Failed to list Bundle IDs')
          expect(output).to include('Connection failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.bundleid('list')
        end
      end
    end

    describe 'bundleid register' do
      context 'with valid identifier' do
        let(:success_response) {
          {
            data: {
              'bundle_id' => {
                'identifier' => 'com.company.newapp',
                'name' => 'Newapp'
              }
            }
          }
        }

        before do
          allow(client).to receive(:post).and_return(success_response)
        end

        it 'shows registering message' do
          output = capture_stdout { cli.bundleid('register', 'com.company.newapp') }
          expect(output).to include('Registering Bundle ID')
        end

        it 'shows the identifier' do
          output = capture_stdout { cli.bundleid('register', 'com.company.newapp') }
          expect(output).to include('com.company.newapp')
        end

        it 'sends POST request to API' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/bundle_ids",
            body: hash_including(identifier: 'com.company.newapp', platform: 'IOS')
          )
          cli.bundleid('register', 'com.company.newapp')
        end

        it 'shows success message' do
          output = capture_stdout { cli.bundleid('register', 'com.company.newapp') }
          expect(output).to include('Bundle ID registered successfully')
        end

        it 'shows next steps' do
          output = capture_stdout { cli.bundleid('register', 'com.company.newapp') }
          expect(output).to include('mysigner sync ios')
        end
      end

      context 'with custom name' do
        let(:success_response) {
          {
            data: {
              'bundle_id' => {
                'identifier' => 'com.company.app',
                'name' => 'Custom App Name'
              }
            }
          }
        }

        before do
          allow(client).to receive(:post).and_return(success_response)
        end

        it 'uses the provided name' do
          expect(client).to receive(:post).with(
            "/api/v1/organizations/#{org_id}/bundle_ids",
            body: hash_including(name: 'Custom App Name')
          )
          cli.bundleid('register', 'com.company.app', 'Custom App Name')
        end

        it 'shows the custom name' do
          output = capture_stdout { cli.bundleid('register', 'com.company.app', 'Custom App Name') }
          expect(output).to include('Custom App Name')
        end
      end

      context 'when identifier is missing' do
        it 'shows usage error' do
          output = capture_stdout { cli.bundleid('register') }
          expect(output).to include('Usage: mysigner bundleid register IDENTIFIER')
        end

        it 'shows example' do
          output = capture_stdout { cli.bundleid('register') }
          expect(output).to include('mysigner bundleid register com.company.myapp')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.bundleid('register')
        end
      end

      context 'with invalid identifier format' do
        it 'shows error for no dots' do
          output = capture_stdout { cli.bundleid('register', 'invalidbundleid') }
          expect(output).to include('Invalid Bundle ID format')
        end

        it 'shows error for starting with number' do
          output = capture_stdout { cli.bundleid('register', '123.com.app') }
          expect(output).to include('Invalid Bundle ID format')
        end

        it 'shows format requirements' do
          output = capture_stdout { cli.bundleid('register', 'invalid') }
          expect(output).to include('Start with a letter')
          expect(output).to include('reverse domain notation')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.bundleid('register', 'invalid')
        end
      end

      context 'when bundle ID already exists' do
        before do
          allow(client).to receive(:post)
            .and_raise(Mysigner::ClientError.new('ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE'))
        end

        it 'shows already exists message' do
          output = capture_stdout { cli.bundleid('register', 'com.existing.app') }
          expect(output).to include('Bundle ID already registered')
        end

        it 'suggests sync command' do
          output = capture_stdout { cli.bundleid('register', 'com.existing.app') }
          expect(output).to include('mysigner sync ios')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.bundleid('register', 'com.existing.app')
        end
      end

      context 'when validation fails' do
        before do
          error = Mysigner::ValidationError.new('Validation failed')
          allow(error).to receive(:details).and_return({ 'identifier' => ['is invalid'] })
          allow(client).to receive(:post).and_raise(error)
        end

        it 'shows validation error' do
          output = capture_stdout { cli.bundleid('register', 'com.company.app') }
          expect(output).to include('Validation failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.bundleid('register', 'com.company.app')
        end
      end

      context 'when API fails' do
        before do
          allow(client).to receive(:post)
            .and_raise(Mysigner::ClientError.new('API error'))
        end

        it 'shows error message' do
          output = capture_stdout { cli.bundleid('register', 'com.company.app') }
          expect(output).to include('Failed to register Bundle ID')
        end

        it 'shows common issues' do
          output = capture_stdout { cli.bundleid('register', 'com.company.app') }
          expect(output).to include('Common issues')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.bundleid('register', 'com.company.app')
        end
      end
    end

    describe 'unknown action' do
      it 'shows error for unknown action' do
        output = capture_stdout { cli.bundleid('unknown') }
        expect(output).to include('Unknown action')
      end

      it 'shows available actions' do
        output = capture_stdout { cli.bundleid('unknown') }
        expect(output).to include('mysigner bundleid register')
        expect(output).to include('mysigner bundleid list')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.bundleid('unknown')
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'bundleid']) }
      expect(help_output).to include('Bundle ID')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['bundleid', 'list']) }
      expect(output).to include('Not logged in')
    end
  end
end
