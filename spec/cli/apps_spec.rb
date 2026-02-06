# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner apps', type: :cli do
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
      allow(client).to receive(:get).and_return({
        data: { 'data' => { 'apps' => [] } }
      })
    end

    it 'shows error message' do
      output = capture_stdout { cli.apps }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.apps }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.apps
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
      cli.options = { page: 1, per_page: 50 }
    end

    describe 'list all apps (both platforms)' do
      let(:ios_apps_response) {
        {
          data: {
            'data' => {
              'apps' => [
                { 'name' => 'My iOS App', 'bundle_id' => 'com.example.ios' },
                { 'name' => 'Another iOS App', 'bundle_id' => 'com.example.another' }
              ]
            }
          }
        }
      }

      let(:android_apps_response) {
        {
          data: {
            'android_apps' => [
              { 'name' => 'My Android App', 'package_name' => 'com.example.android' }
            ]
          }
        }
      }

      before do
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/apple_apps", params: { page: 1, per_page: 50 })
          .and_return(ios_apps_response)
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/android_apps", params: { page: 1, per_page: 50 })
          .and_return(android_apps_response)
      end

      it 'shows iOS apps section header' do
        output = capture_stdout { cli.apps }
        expect(output).to include('iOS Apps')
      end

      it 'shows Android apps section header' do
        output = capture_stdout { cli.apps }
        expect(output).to include('Android Apps')
      end

      it 'shows iOS app names' do
        output = capture_stdout { cli.apps }
        expect(output).to include('My iOS App')
        expect(output).to include('Another iOS App')
      end

      it 'shows iOS app bundle IDs' do
        output = capture_stdout { cli.apps }
        expect(output).to include('com.example.ios')
        expect(output).to include('com.example.another')
      end

      it 'shows Android app names' do
        output = capture_stdout { cli.apps }
        expect(output).to include('My Android App')
      end

      it 'shows Android app package names' do
        output = capture_stdout { cli.apps }
        expect(output).to include('com.example.android')
      end
    end

    describe 'list iOS apps only' do
      let(:ios_apps_response) {
        {
          data: {
            'data' => {
              'apps' => [
                { 'name' => 'My iOS App', 'bundle_id' => 'com.example.ios' }
              ]
            }
          }
        }
      }

      before do
        cli.options = { page: 1, per_page: 50, platform: 'ios' }
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/apple_apps", params: { page: 1, per_page: 50 })
          .and_return(ios_apps_response)
      end

      it 'shows iOS apps section' do
        output = capture_stdout { cli.apps }
        expect(output).to include('iOS Apps')
      end

      it 'does not show Android section' do
        output = capture_stdout { cli.apps }
        expect(output).not_to include('Android Apps')
      end

      it 'fetches only iOS apps from API' do
        expect(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/apple_apps", params: { page: 1, per_page: 50 })
        expect(client).not_to receive(:get)
          .with("/api/v1/organizations/#{org_id}/android_apps", anything)
        cli.apps
      end
    end

    describe 'list Android apps only' do
      let(:android_apps_response) {
        {
          data: {
            'android_apps' => [
              { 'name' => 'My Android App', 'package_name' => 'com.example.android' }
            ]
          }
        }
      }

      before do
        cli.options = { page: 1, per_page: 50, platform: 'android' }
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/android_apps", params: { page: 1, per_page: 50 })
          .and_return(android_apps_response)
      end

      it 'shows Android apps section' do
        output = capture_stdout { cli.apps }
        expect(output).to include('Android Apps')
      end

      it 'does not show iOS section' do
        output = capture_stdout { cli.apps }
        expect(output).not_to include('iOS Apps')
      end

      it 'fetches only Android apps from API' do
        expect(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/android_apps", params: { page: 1, per_page: 50 })
        expect(client).not_to receive(:get)
          .with("/api/v1/organizations/#{org_id}/apple_apps", anything)
        cli.apps
      end
    end

    describe 'with search query' do
      let(:ios_apps_response) {
        {
          data: { 'data' => { 'apps' => [{ 'name' => 'Search Result', 'bundle_id' => 'com.example.search' }] } }
        }
      }
      let(:android_apps_response) {
        { data: { 'android_apps' => [] } }
      }

      before do
        cli.options = { page: 1, per_page: 50, search: 'myapp' }
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/apple_apps", params: { page: 1, per_page: 50, q: 'myapp' })
          .and_return(ios_apps_response)
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/android_apps", params: { page: 1, per_page: 50, q: 'myapp' })
          .and_return(android_apps_response)
      end

      it 'sends search query to iOS API' do
        expect(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/apple_apps", params: { page: 1, per_page: 50, q: 'myapp' })
        cli.apps
      end

      it 'sends search query to Android API' do
        expect(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/android_apps", params: { page: 1, per_page: 50, q: 'myapp' })
        cli.apps
      end

      it 'shows search results' do
        output = capture_stdout { cli.apps }
        expect(output).to include('Search Result')
      end
    end

    describe 'when no iOS apps found' do
      let(:ios_apps_response) {
        { data: { 'data' => { 'apps' => [] } } }
      }
      let(:android_apps_response) {
        { data: { 'android_apps' => [] } }
      }

      before do
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/apple_apps", params: { page: 1, per_page: 50 })
          .and_return(ios_apps_response)
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/android_apps", params: { page: 1, per_page: 50 })
          .and_return(android_apps_response)
      end

      it 'shows no iOS apps message' do
        output = capture_stdout { cli.apps }
        expect(output).to include('No iOS apps found')
      end

      it 'shows helpful tip for iOS' do
        output = capture_stdout { cli.apps }
        expect(output).to include('mysigner sync ios')
      end

      it 'shows no Android apps message' do
        output = capture_stdout { cli.apps }
        expect(output).to include('No Android apps found')
      end
    end

    describe 'when iOS API fails' do
      let(:android_apps_response) {
        { data: { 'android_apps' => [] } }
      }

      before do
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/apple_apps", params: { page: 1, per_page: 50 })
          .and_raise(Mysigner::ClientError.new('Connection failed'))
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/android_apps", params: { page: 1, per_page: 50 })
          .and_return(android_apps_response)
      end

      it 'shows iOS error message' do
        output = capture_stdout { cli.apps }
        expect(output).to include('Could not fetch iOS apps')
        expect(output).to include('Connection failed')
      end

      it 'still shows Android section' do
        output = capture_stdout { cli.apps }
        expect(output).to include('Android Apps')
      end
    end

    describe 'when Android API fails' do
      let(:ios_apps_response) {
        { data: { 'data' => { 'apps' => [] } } }
      }

      before do
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/apple_apps", params: { page: 1, per_page: 50 })
          .and_return(ios_apps_response)
        allow(client).to receive(:get)
          .with("/api/v1/organizations/#{org_id}/android_apps", params: { page: 1, per_page: 50 })
          .and_raise(Mysigner::ClientError.new('Connection failed'))
      end

      it 'shows Android error message' do
        output = capture_stdout { cli.apps }
        expect(output).to include('Could not fetch Android apps')
        expect(output).to include('Connection failed')
      end

      it 'still shows iOS section' do
        output = capture_stdout { cli.apps }
        expect(output).to include('iOS Apps')
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'apps']) }
      expect(help_output).to include('List apps')
    end

    it 'shows platform option' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'apps']) }
      expect(help_output).to include('--platform')
    end

    it 'shows search option' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'apps']) }
      expect(help_output).to include('--search')
    end

    it 'shows pagination options' do
      help_output = capture_stdout { Mysigner::CLI.start(['help', 'apps']) }
      expect(help_output).to include('--page')
      expect(help_output).to include('--per-page')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['apps']) }
      expect(output).to include('Not logged in')
    end
  end
end
