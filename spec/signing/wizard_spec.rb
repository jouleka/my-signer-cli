# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/signing/wizard'
require 'stringio'

RSpec.describe Mysigner::Signing::Wizard do
  let(:parser) { instance_double(Mysigner::Build::Parser) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:organization_id) { 'org-123' }
  let(:wizard) { described_class.new(parser, client, organization_id, check_org_match: false) }
  let(:project) { double('project') }
  let(:build_settings) { {} }
  let(:build_config) { double('build_config', name: 'Release', build_settings: build_settings) }
  let(:target) { double('target', name: 'TestApp', build_configurations: [build_config]) }
  let(:validator) { instance_double(Mysigner::Signing::Validator) }

  before do
    allow(parser).to receive(:project).and_return(project)
    allow(project).to receive(:save)
    allow(project).to receive(:targets).and_return([target])

    # Stub validator
    allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
    allow(validator).to receive(:validate).and_return({ valid: true, errors: [], warnings: [] })
  end

  def capture_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  def stub_stdin(*inputs)
    StringIO.new("#{inputs.join("\n")}\n")
    allow($stdin).to receive(:gets).and_return(*inputs.map { |i| "#{i}\n" })
  end

  describe '#run!' do
    context 'with single target' do
      before do
        allow(parser).to receive(:app_targets).and_return([target])
        allow(parser).to receive(:bundle_id).with('TestApp').and_return('com.test.app')
        allow(parser).to receive(:team_id).with('TestApp').and_return('TEAM123456')
        allow(parser).to receive(:code_sign_style).with('TestApp').and_return('Automatic')
        allow(parser).to receive(:signing_configured?).with('TestApp').and_return(false)

        # Stub profile fetching
        allow(client).to receive(:get).with('/api/v1/organizations/org-123/profiles',
                                            params: { bundle_id: 'com.test.app' })
                                      .and_return({
                                                    data: {
                                                      'profiles' => [
                                                        {
                                                          'id' => '1',
                                                          'name' => 'Test Profile',
                                                          'profile_type' => 'IOS_APP_DEVELOPMENT',
                                                          'status' => 'ACTIVE',
                                                          'expires_at' => '2025-12-31T00:00:00'
                                                        }
                                                      ]
                                                    }
                                                  })
      end

      it 'detects target automatically' do
        stub_stdin('1', '1') # Keep current team, select first profile

        output = capture_output { wizard.run! }

        expect(output).to include('Target: TestApp')
      end

      it 'shows current configuration' do
        stub_stdin('1', '1')

        output = capture_output { wizard.run! }

        expect(output).to include('Current Configuration')
        expect(output).to include('Bundle ID: com.test.app')
        expect(output).to include('Team: TEAM123456')
        expect(output).to include('Signing: Automatic')
      end

      it 'allows keeping current team' do
        stub_stdin('1', '1')

        output = capture_output { wizard.run! }

        expect(output).to include('Keep current team: TEAM123456')
        expect(output).to include('Using current team: TEAM123456')
      end

      it 'fetches team from API when selected' do
        stub_stdin('2', '1') # Fetch from API, select profile

        allow(client).to receive(:get).with('/api/v1/organizations/org-123')
                                      .and_return({ 'app_store_connect_team_id' => 'API_TEAM123' })

        output = capture_output { wizard.run! }

        expect(output).to include('Fetching team from My Signer')
        expect(output).to include('Found team: API_TEAM123')
      end

      it 'allows manual team entry' do
        stub_stdin('3', 'MANUAL1234', '1') # Enter manually, provide team, select profile

        output = capture_output { wizard.run! }

        expect(output).to include('Enter Team ID')
        expect(output).to include('Team ID: MANUAL1234')
      end

      it 'lists available provisioning profiles' do
        stub_stdin('1', '1')

        output = capture_output { wizard.run! }

        expect(output).to include('Available Profiles')
        expect(output).to include('Development Profiles')
        expect(output).to include('Test Profile')
      end

      it 'applies configuration to project' do
        stub_stdin('1', '1')

        capture_output { wizard.run! }

        expect(build_settings['CODE_SIGN_STYLE']).to eq('Manual')
        expect(build_settings['DEVELOPMENT_TEAM']).to eq('TEAM123456')
        expect(build_settings['PROVISIONING_PROFILE_SPECIFIER']).to eq('Test Profile')
        expect(build_settings['CODE_SIGN_IDENTITY']).to eq('Apple Development')
        expect(project).to have_received(:save)
      end

      it 'validates configuration after applying' do
        stub_stdin('1', '1')

        expect(validator).to receive(:validate)

        capture_output { wizard.run! }
      end

      it 'shows success message' do
        stub_stdin('1', '1')

        output = capture_output { wizard.run! }

        expect(output).to include('Signing configuration complete!')
        expect(output).to include('Next steps')
        expect(output).to include('mysigner build')
      end
    end

    context 'with multiple targets' do
      let(:target2) { double('target2', name: 'TestAppExtension') }

      before do
        allow(parser).to receive(:app_targets).and_return([target, target2])
        allow(parser).to receive(:bundle_id).with('TestApp').and_return('com.test.app')
        allow(parser).to receive(:team_id).with('TestApp').and_return(nil)
        allow(parser).to receive(:code_sign_style).with('TestApp').and_return(nil)
        allow(parser).to receive(:signing_configured?).with('TestApp').and_return(false)

        allow(client).to receive(:get).with('/api/v1/organizations/org-123')
                                      .and_return({ 'app_store_connect_team_id' => 'TEAM123456' })

        allow(client).to receive(:get).with('/api/v1/organizations/org-123/profiles',
                                            params: { bundle_id: 'com.test.app' })
                                      .and_return({
                                                    data: {
                                                      'profiles' => [
                                                        { 'id' => '1', 'name' => 'Profile 1', 'profile_type' => 'IOS_APP_DEVELOPMENT',
                                                          'status' => 'ACTIVE' }
                                                      ]
                                                    }
                                                  })
      end

      it 'prompts user to select target' do
        stub_stdin('1', '1', '1') # Select first target, fetch team, select profile

        output = capture_output { wizard.run! }

        expect(output).to include('Multiple app targets found')
        expect(output).to include('1. TestApp')
        expect(output).to include('2. TestAppExtension')
        expect(output).to include('Select target')
      end

      it 'proceeds with selected target' do
        stub_stdin('1', '1', '1')

        output = capture_output { wizard.run! }

        expect(output).to include('TestApp')
      end
    end

    context 'with no team set' do
      before do
        allow(parser).to receive(:app_targets).and_return([target])
        allow(parser).to receive(:bundle_id).with('TestApp').and_return('com.test.app')
        allow(parser).to receive(:team_id).with('TestApp').and_return(nil)
        allow(parser).to receive(:code_sign_style).with('TestApp').and_return(nil)
        allow(parser).to receive(:signing_configured?).with('TestApp').and_return(false)

        allow(client).to receive(:get).with('/api/v1/organizations/org-123')
                                      .and_return({ 'app_store_connect_team_id' => 'TEAM123456' })

        allow(client).to receive(:get).with('/api/v1/organizations/org-123/profiles',
                                            params: { bundle_id: 'com.test.app' })
                                      .and_return({
                                                    data: {
                                                      'profiles' => [
                                                        { 'id' => '1', 'name' => 'Profile', 'profile_type' => 'IOS_APP_DEVELOPMENT',
                                                          'status' => 'ACTIVE' }
                                                      ]
                                                    }
                                                  })
      end

      it 'offers to fetch from API as first option' do
        stub_stdin('1', '1') # Fetch from API, select profile

        output = capture_output { wizard.run! }

        expect(output).to include('1. Fetch from My Signer API')
        expect(output).to include('2. Enter team ID manually')
      end
    end

    context 'with distribution profile' do
      before do
        allow(parser).to receive(:app_targets).and_return([target])
        allow(parser).to receive(:bundle_id).with('TestApp').and_return('com.test.app')
        allow(parser).to receive(:team_id).with('TestApp').and_return('TEAM123456')
        allow(parser).to receive(:code_sign_style).with('TestApp').and_return('Automatic')
        allow(parser).to receive(:signing_configured?).with('TestApp').and_return(false)

        allow(client).to receive(:get).with('/api/v1/organizations/org-123/profiles',
                                            params: { bundle_id: 'com.test.app' })
                                      .and_return({
                                                    data: {
                                                      'profiles' => [
                                                        {
                                                          'id' => '1',
                                                          'name' => 'Distribution Profile',
                                                          'profile_type' => 'IOS_APP_STORE',
                                                          'status' => 'ACTIVE',
                                                          'expires_at' => '2025-12-31T00:00:00'
                                                        }
                                                      ]
                                                    }
                                                  })
      end

      it 'sets Apple Distribution code sign identity' do
        stub_stdin('1', '1')

        capture_output { wizard.run! }

        expect(build_settings['CODE_SIGN_STYLE']).to eq('Manual')
        expect(build_settings['DEVELOPMENT_TEAM']).to eq('TEAM123456')
        expect(build_settings['PROVISIONING_PROFILE_SPECIFIER']).to eq('Distribution Profile')
        expect(build_settings['CODE_SIGN_IDENTITY']).to eq('Apple Distribution')
      end
    end

    context 'when no profiles found' do
      before do
        allow(parser).to receive(:app_targets).and_return([target])
        allow(parser).to receive(:bundle_id).with('TestApp').and_return('com.test.app')
        allow(parser).to receive(:team_id).with('TestApp').and_return('TEAM123456')
        allow(parser).to receive(:code_sign_style).with('TestApp').and_return(nil)
        allow(parser).to receive(:signing_configured?).with('TestApp').and_return(false)

        allow(client).to receive(:get).with('/api/v1/organizations/org-123/profiles',
                                            params: { bundle_id: 'com.test.app' })
                                      .and_return({ data: { 'profiles' => [] } })
      end

      it 'shows error and provides guidance' do
        stub_stdin('1') # Keep current team

        output = capture_output { wizard.run! }

        expect(output).to include('No provisioning profiles found')
        expect(output).to include('Create a profile at')
        expect(output).to include('developer.apple.com')
      end
    end

    context 'when validation fails' do
      before do
        allow(parser).to receive(:app_targets).and_return([target])
        allow(parser).to receive(:bundle_id).with('TestApp').and_return('com.test.app')
        allow(parser).to receive(:team_id).with('TestApp').and_return('TEAM123456')
        allow(parser).to receive(:code_sign_style).with('TestApp').and_return(nil)
        allow(parser).to receive(:signing_configured?).with('TestApp').and_return(false)

        allow(client).to receive(:get).with('/api/v1/organizations/org-123/profiles',
                                            params: { bundle_id: 'com.test.app' })
                                      .and_return({
                                                    data: {
                                                      'profiles' => [
                                                        { 'id' => '1', 'name' => 'Profile', 'profile_type' => 'IOS_APP_DEVELOPMENT',
                                                          'status' => 'ACTIVE' }
                                                      ]
                                                    }
                                                  })

        allow(validator).to receive(:validate).and_return({
                                                            valid: false,
                                                            errors: ['Certificate not found'],
                                                            warnings: []
                                                          })
      end

      it 'shows validation errors' do
        stub_stdin('1', '1')

        expect do
          capture_output { wizard.run! }
        end.to raise_error(Mysigner::Signing::Wizard::WizardError, /Configuration validation failed/)
      end
    end

    context 'with invalid team ID format' do
      before do
        allow(parser).to receive(:app_targets).and_return([target])
        allow(parser).to receive(:bundle_id).with('TestApp').and_return('com.test.app')
        allow(parser).to receive(:team_id).with('TestApp').and_return(nil)
        allow(parser).to receive(:code_sign_style).with('TestApp').and_return(nil)
        allow(parser).to receive(:signing_configured?).with('TestApp').and_return(false)
      end

      it 'rejects invalid team ID' do
        stub_stdin('2', 'INVALID') # Enter manually, provide invalid team

        output = capture_output { wizard.run! }

        expect(output).to include('Invalid Team ID format')
      end
    end

    context 'when API team fetch fails' do
      before do
        allow(parser).to receive(:app_targets).and_return([target])
        allow(parser).to receive(:bundle_id).with('TestApp').and_return('com.test.app')
        allow(parser).to receive(:team_id).with('TestApp').and_return(nil)
        allow(parser).to receive(:code_sign_style).with('TestApp').and_return(nil)
        allow(parser).to receive(:signing_configured?).with('TestApp').and_return(false)

        allow(client).to receive(:get).with('/api/v1/organizations/org-123')
                                      .and_raise(StandardError.new('Network error'))
      end

      it 'shows error message' do
        stub_stdin('1') # Fetch from API

        output = capture_output { wizard.run! }

        expect(output).to include('Failed to fetch team')
        expect(output).to include('Network error')
      end
    end

    context 'when no app targets found' do
      before do
        allow(parser).to receive(:app_targets).and_return([])
      end

      it 'shows error and returns nil' do
        output = capture_output { wizard.run! }

        expect(output).to include('No app targets found')
      end
    end
  end
end
