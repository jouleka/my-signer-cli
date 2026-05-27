# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner validate', type: :cli do
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
    cli.options = {}
    # Prevent auto-detection from picking up files
    allow(Dir).to receive(:glob).with('**/*.pbxproj').and_return([])
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
      # Stub post to prevent errors when stubbed exit doesn't halt execution
      allow(client).to receive(:post).and_return({
                                                   data: { 'valid' => true, 'checks' => {}, 'suggestions' => [] }
                                                 })
    end

    it 'shows error message' do
      cli.options = { bundle_id: 'com.example.app', type: 'development' }
      output = capture_stdout { cli.validate }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      cli.options = { bundle_id: 'com.example.app', type: 'development' }
      output = capture_stdout { cli.validate }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      cli.options = { bundle_id: 'com.example.app', type: 'development' }
      expect(cli).to receive(:exit).with(1)
      cli.validate
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

    describe 'when all checks pass' do
      let(:valid_response) do
        {
          data: {
            'valid' => true,
            'checks' => {
              'bundle_id' => { 'status' => 'pass', 'message' => 'Bundle ID registered' },
              'certificate' => { 'status' => 'pass', 'message' => 'Valid certificate found' },
              'profile' => { 'status' => 'pass', 'message' => 'Provisioning profile valid' }
            },
            'suggestions' => []
          }
        }
      end

      before do
        cli.options = { bundle_id: 'com.example.app', type: 'development' }
        allow(client).to receive(:post).and_return(valid_response)
      end

      it 'shows validating message' do
        output = capture_stdout { cli.validate }
        expect(output).to include('Validating signing configuration')
      end

      it 'shows bundle ID and type' do
        output = capture_stdout { cli.validate }
        expect(output).to include('Bundle ID: com.example.app')
        expect(output).to include('Type:      development')
      end

      it 'calls validate API' do
        expect(client).to receive(:post).with(
          "/api/v1/organizations/#{org_id}/validate",
          body: { bundle_id: 'com.example.app', type: 'development' }
        )
        cli.validate
      end

      it 'shows pass for bundle_id check' do
        output = capture_stdout { cli.validate }
        expect(output).to include('✓ Bundle id: Bundle ID registered')
      end

      it 'shows pass for certificate check' do
        output = capture_stdout { cli.validate }
        expect(output).to include('✓ Certificate: Valid certificate found')
      end

      it 'shows pass for profile check' do
        output = capture_stdout { cli.validate }
        expect(output).to include('✓ Profile: Provisioning profile valid')
      end

      it 'shows overall success message' do
        output = capture_stdout { cli.validate }
        expect(output).to include('All checks passed')
      end

      it 'does not exit with error' do
        expect(cli).not_to receive(:exit).with(1)
        cli.validate
      end
    end

    describe 'when checks fail' do
      let(:invalid_response) do
        {
          data: {
            'valid' => false,
            'checks' => {
              'bundle_id' => { 'status' => 'pass', 'message' => 'Bundle ID registered' },
              'certificate' => { 'status' => 'fail', 'message' => 'Certificate expired' },
              'profile' => { 'status' => 'fail', 'message' => 'No matching profile' }
            },
            'suggestions' => [
              'Renew your certificate in Apple Developer Portal',
              'Run mysigner sync ios to regenerate profiles'
            ]
          }
        }
      end

      before do
        cli.options = { bundle_id: 'com.example.app', type: 'appstore' }
        allow(client).to receive(:post).and_return(invalid_response)
      end

      it 'shows pass for bundle_id' do
        output = capture_stdout { cli.validate }
        expect(output).to include('✓ Bundle id: Bundle ID registered')
      end

      it 'shows fail for certificate' do
        output = capture_stdout { cli.validate }
        expect(output).to include('✗ Certificate: Certificate expired')
      end

      it 'shows fail for profile' do
        output = capture_stdout { cli.validate }
        expect(output).to include('✗ Profile: No matching profile')
      end

      it 'shows overall failure message' do
        output = capture_stdout { cli.validate }
        expect(output).to include('Validation failed')
      end

      it 'shows suggestions' do
        output = capture_stdout { cli.validate }
        expect(output).to include('Suggestions')
        expect(output).to include('Renew your certificate')
        expect(output).to include('mysigner sync ios')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.validate
      end
    end

    describe 'with auto-detected bundle ID' do
      let(:valid_response) do
        {
          data: {
            'valid' => true,
            'checks' => {
              'bundle_id' => { 'status' => 'pass', 'message' => 'OK' },
              'certificate' => { 'status' => 'pass', 'message' => 'OK' },
              'profile' => { 'status' => 'pass', 'message' => 'OK' }
            },
            'suggestions' => []
          }
        }
      end

      before do
        cli.options = { type: 'development' }
        allow(Dir).to receive(:glob).with('**/*.pbxproj').and_return(['MyApp.xcodeproj/project.pbxproj'])
        allow(File).to receive(:read).with('MyApp.xcodeproj/project.pbxproj').and_return(
          'PRODUCT_BUNDLE_IDENTIFIER = "com.detected.app";'
        )
        allow(client).to receive(:post).and_return(valid_response)
      end

      it 'detects bundle ID from project' do
        expect(client).to receive(:post).with(
          "/api/v1/organizations/#{org_id}/validate",
          body: { bundle_id: 'com.detected.app', type: 'development' }
        )
        cli.validate
      end

      it 'shows detected bundle ID' do
        output = capture_stdout { cli.validate }
        expect(output).to include('Bundle ID: com.detected.app')
      end
    end

    describe 'when missing required params' do
      context 'when bundle_id is missing and cannot be detected' do
        before do
          cli.options = { type: 'development' }
          # Stub post to prevent errors when stubbed exit doesn't halt execution
          allow(client).to receive(:post).and_return({
                                                       data: { 'valid' => true, 'checks' => {}, 'suggestions' => [] }
                                                     })
        end

        it 'shows error message' do
          output = capture_stdout { cli.validate }
          expect(output).to include('Bundle ID is required')
        end

        it 'shows example' do
          output = capture_stdout { cli.validate }
          expect(output).to include('mysigner validate --bundle-id')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.validate
        end
      end

      context 'when type is missing' do
        before do
          cli.options = { bundle_id: 'com.example.app' }
          # Stub post to prevent errors when stubbed exit doesn't halt execution
          allow(client).to receive(:post).and_return({
                                                       data: { 'valid' => true, 'checks' => {}, 'suggestions' => [] }
                                                     })
        end

        it 'shows error message' do
          output = capture_stdout { cli.validate }
          expect(output).to include('Signing type is required')
        end

        it 'shows valid types' do
          output = capture_stdout { cli.validate }
          expect(output).to include('development, appstore, adhoc, inhouse')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.validate
        end
      end

      context 'when type is invalid' do
        before do
          cli.options = { bundle_id: 'com.example.app', type: 'invalid' }
          # Stub post to prevent errors when stubbed exit doesn't halt execution
          allow(client).to receive(:post).and_return({
                                                       data: { 'valid' => true, 'checks' => {}, 'suggestions' => [] }
                                                     })
        end

        it 'shows error message' do
          output = capture_stdout { cli.validate }
          expect(output).to include('Invalid signing type')
        end

        it 'shows valid types' do
          output = capture_stdout { cli.validate }
          expect(output).to include('development, appstore, adhoc, inhouse')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.validate
        end
      end
    end

    describe 'API error handling' do
      before do
        cli.options = { bundle_id: 'com.example.app', type: 'development' }
      end

      context 'when resource not found (404)' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::NotFoundError.new('Bundle ID not found')
          )
        end

        it 'shows not found error' do
          output = capture_stdout { cli.validate }
          expect(output).to include('Not found')
        end

        it 'shows sync suggestion' do
          output = capture_stdout { cli.validate }
          expect(output).to include('mysigner sync ios')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.validate
        end
      end

      context 'when validation error (422)' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::ValidationError.new('Invalid params', { 'type' => ['is not valid'] })
          )
        end

        it 'shows validation error' do
          output = capture_stdout { cli.validate }
          expect(output).to include('Validation error')
        end

        it 'shows field errors' do
          output = capture_stdout { cli.validate }
          expect(output).to include('type')
          expect(output).to include('is not valid')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.validate
        end
      end

      context 'when network error' do
        before do
          allow(client).to receive(:post).and_raise(
            Mysigner::ClientError.new('Connection refused')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.validate }
          expect(output).to include('Validation request failed')
          expect(output).to include('Connection refused')
        end

        it 'shows troubleshooting tips' do
          output = capture_stdout { cli.validate }
          expect(output).to include('Check your network connection')
          expect(output).to include('mysigner status')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.validate
        end
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help validate]) }
      expect(help_output).to include('validate')
    end

    it 'shows bundle-id option' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help validate]) }
      expect(help_output).to include('--bundle-id')
    end

    it 'shows type option' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help validate]) }
      expect(help_output).to include('--type')
    end
  end

  describe 'integration tests', :integration do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['validate', '--bundle-id', 'com.example.app', '--type', 'development']) }
      expect(output).to include('Not logged in')
    end
  end

  describe 'mysigner validate --local-only' do
    let(:cli) { Mysigner::CLI.new }
    let(:project_info) { { path: '/tmp/fake.xcodeproj', framework: :native } }
    let(:parser) { instance_double(Mysigner::Build::Parser) }
    let(:validator) { instance_double(Mysigner::Signing::Validator) }

    before do
      ENV.delete('MYSIGNER_LOCAL_ONLY')
      allow(cli).to receive(:options).and_return({ local_only: true })
      allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
      allow(Mysigner::Build::Parser).to receive(:new).with(project_info).and_return(parser)
      allow(parser).to receive(:main_target).and_return(double(name: 'App'))
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      allow(validator).to receive(:validate!)
    end
    after { ENV.delete('MYSIGNER_LOCAL_ONLY') }

    it 'uses the local Signing::Validator and does not POST to the server' do
      expect(validator).to receive(:validate!)
      expect(cli).not_to receive(:create_client)

      output = capture_stdout { cli.validate }

      expect(output).to include('Local-only validation')
    end

    it 'exits 1 with a clean error message when Signing::Validator raises' do
      # Resolve the actual error class name from the Validator class
      error_class = if Mysigner::Signing::Validator.const_defined?(:ValidationError)
                      Mysigner::Signing::Validator::ValidationError
                    else
                      StandardError
                    end
      allow(validator).to receive(:validate!).and_raise(error_class, 'no team set')
      allow(cli).to receive(:exit).and_call_original

      output = capture_stdout do
        expect { cli.validate }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(output).to include('no team set')
    end
  end
end
