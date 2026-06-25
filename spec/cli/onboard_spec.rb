# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'mysigner/config'
require 'mysigner/client'
require 'open3'
require 'stringio'

RSpec.describe 'mysigner onboard' do
  let(:cli) { Mysigner::CLI.new }
  let(:exe_path) { File.expand_path('../../exe/mysigner', __dir__) }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'http://test.example.com' }
  let(:api_token) { 'test_token_123' }
  let(:user_email) { 'test@example.com' }
  let(:org_id) { 1 }
  let(:org_data) do
    {
      'id' => org_id,
      'name' => 'Test Org',
      'app_store_connect_configured' => false
    }
  end

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(Mysigner::Client).to receive(:new).and_return(client)
    allow(config).to receive(:save)
    # No prior session by default
    allow(config).to receive(:exists?).and_return(false)
    allow(config).to receive(:api_token).and_return(nil)
    allow(config).to receive(:current_organization_id).and_return(nil)
  end

  describe 'successful setup - user has everything' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      # User has account (1), has organization (1), skip App Store Connect setup (2)
      allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '1', '2')
      # User has token (yes_with_default? calls ask)
      allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(true)
      # Provide email and token
      allow(cli).to receive(:prompt_for_email).and_return(user_email)
      allow(cli).to receive(:ask).with('Paste your API Token:', echo: false).and_return(api_token)
      # Success responses
      allow(client).to receive(:test_connection).and_return({ success: true })
      allow(client).to receive(:get).with('/api/v1/organizations').and_return({
                                                                                data: { 'organizations' => [{
                                                                                  'id' => org_id, 'name' => 'Test Org'
                                                                                }] }
                                                                              })
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return({
                                                                                          data: org_data
                                                                                        })
      allow(config).to receive(:api_url=)
      allow(config).to receive(:user_email=)
      allow(config).to receive(:current_organization_id=)
      allow(config).to receive(:save_token_for_org)
    end

    it 'shows welcome message' do
      expect { cli.onboard }.to output(/Welcome/).to_stdout
    end

    it 'asks about account' do
      expect { cli.onboard }.to output(/Do you have a My Signer account/).to_stdout
    end

    it 'asks about organization' do
      expect { cli.onboard }.to output(/Do you have an organization/).to_stdout
    end

    it 'shows token generation step' do
      output = capture_stdout { cli.onboard }
      expect(output).to include('Generate API Token')
      expect(output).to include('Create Token')
    end

    it 'tests connection' do
      expect(client).to receive(:test_connection)
      cli.onboard
    end

    it 'fetches organizations' do
      expect(client).to receive(:get).with('/api/v1/organizations').and_return({
                                                                                 data: { 'organizations' => [{
                                                                                   'id' => org_id, 'name' => 'Test Org'
                                                                                 }] }
                                                                               })
      cli.onboard
    end

    it 'saves configuration with multi-org token' do
      expect(config).to receive(:api_url=).with(api_url)
      expect(config).to receive(:user_email=).with(user_email)
      expect(config).to receive(:current_organization_id=).with(org_id)
      expect(config).to receive(:save_token_for_org).with(org_id, 'Test Org', api_token)
      expect(config).to receive(:save)
      cli.onboard
    end

    it 'shows success message' do
      expect { cli.onboard }.to output(/Setup Complete/).to_stdout
    end

    it 'shows organization name' do
      expect { cli.onboard }.to output(/Test Org/).to_stdout
    end

    it 'shows next steps' do
      expect { cli.onboard }.to output(/mysigner ship testflight/).to_stdout
    end
  end

  describe 'user needs to create account' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
    end

    context 'user confirms account created' do
      before do
        # User needs account (2), has organization (1), skip App Store Connect (2)
        allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('2', '1', '2')
        # Confirms account created
        allow(cli).to receive(:yes_with_default?).with(/Have you created your account/, anything).and_return(true)
        # Has token
        allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(true)
        allow(cli).to receive(:prompt_for_email).and_return(user_email)
        allow(cli).to receive(:ask).with('Paste your API Token:', echo: false).and_return(api_token)
        allow(client).to receive(:test_connection).and_return({ success: true })
        allow(client).to receive(:get).with('/api/v1/organizations').and_return({
                                                                                  data: { 'organizations' => [{
                                                                                    'id' => org_id, 'name' => 'Test Org'
                                                                                  }] }
                                                                                })
        allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return({
                                                                                            data: org_data
                                                                                          })
        allow(config).to receive(:api_url=)
        allow(config).to receive(:user_email=)
        allow(config).to receive(:current_organization_id=)
        allow(config).to receive(:save_token_for_org)
      end

      it 'shows signup guidance' do
        expect { cli.onboard }.to output(/Let's create your account/).to_stdout
      end

      it 'shows signup steps' do
        expect { cli.onboard }.to output(/Click 'Sign Up'/).to_stdout
      end

      it 'continues to next step' do
        expect { cli.onboard }.to output(/Organization Setup/).to_stdout
      end
    end

    context 'user has not created account' do
      before do
        # User needs account
        allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('2')
        allow(cli).to receive(:yes_with_default?).with(/Have you created your account/, anything).and_return(false)
      end

      it 'shows signup guidance' do
        expect { cli.onboard }.to output(/Let's create your account/).to_stdout
      end

      it 'exits early' do
        expect { cli.onboard }.to output(/Come back and run/).to_stdout
      end

      it 'does not save config' do
        expect(config).not_to receive(:save)
        cli.onboard
      end
    end
  end

  describe 'user needs to create organization' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
    end

    context 'user confirms organization created' do
      before do
        # Has account (1), needs org (2), skip App Store Connect (2)
        allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '2', '2')
        allow(cli).to receive(:yes_with_default?).with(/Have you created your organization/, anything).and_return(true)
        # Has token
        allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(true)
        allow(cli).to receive(:prompt_for_email).and_return(user_email)
        allow(cli).to receive(:ask).with('Paste your API Token:', echo: false).and_return(api_token)
        allow(client).to receive(:test_connection).and_return({ success: true })
        allow(client).to receive(:get).with('/api/v1/organizations').and_return({
                                                                                  data: { 'organizations' => [{
                                                                                    'id' => org_id, 'name' => 'Test Org'
                                                                                  }] }
                                                                                })
        allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return({
                                                                                            data: org_data
                                                                                          })
        allow(config).to receive(:api_url=)
        allow(config).to receive(:user_email=)
        allow(config).to receive(:current_organization_id=)
        allow(config).to receive(:save_token_for_org)
      end

      it 'shows organization guidance' do
        expect { cli.onboard }.to output(/Let's create your organization/).to_stdout
      end

      it 'shows organization steps' do
        expect { cli.onboard }.to output(/Click 'Create Organization'/).to_stdout
      end

      it 'continues to next step' do
        expect { cli.onboard }.to output(/Generate API Token/).to_stdout
      end
    end

    context 'user has not created organization' do
      before do
        # Has account, needs org
        allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '2')
        allow(cli).to receive(:yes_with_default?).with(/Have you created your organization/, anything).and_return(false)
      end

      it 'shows organization guidance' do
        expect { cli.onboard }.to output(/Let's create your organization/).to_stdout
      end

      it 'exits early' do
        expect { cli.onboard }.to output(/Come back and run/).to_stdout
      end

      it 'does not save config' do
        expect(config).not_to receive(:save)
        cli.onboard
      end
    end
  end

  describe 'user does not have token yet' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      # Has account and org
      allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '1')
      # No token yet
      allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(false)
    end

    it 'shows token generation guidance' do
      expect { cli.onboard }.to output(/Generate API Token/).to_stdout
      expect { cli.onboard }.to output(/Click 'Create Token'/).to_stdout
    end

    it 'exits early' do
      expect { cli.onboard }.to output(/Come back and run/).to_stdout
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'error handling - empty token' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '1')
      allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(true)
      allow(cli).to receive(:prompt_for_email).and_return(user_email)
      allow(cli).to receive(:ask).with('Paste your API Token:', echo: false).and_return('')
      allow(cli).to receive(:error)
    end

    it 'shows error message' do
      expect(cli).to receive(:error).with('Token cannot be empty')
      cli.onboard
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end

    it 'suggests running setup again' do
      expect { cli.onboard }.to output(/Run 'mysigner onboard' again/).to_stdout
    end
  end

  describe 'error handling - invalid token' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '1')
      allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(true)
      allow(cli).to receive(:prompt_for_email).and_return(user_email)
      allow(cli).to receive(:ask).with('Paste your API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_raise(Mysigner::UnauthorizedError.new('Invalid token'))
      allow(cli).to receive(:error)
    end

    it 'shows invalid token error' do
      expect(cli).to receive(:error).with('Authentication failed')
      cli.onboard
    end

    it 'shows helpful guidance' do
      expect { cli.onboard }.to output(/The token you entered is invalid/).to_stdout
      expect { cli.onboard }.to output(/Make sure the token hasn't been revoked/).to_stdout
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'error handling - connection test fails' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '1')
      allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(true)
      allow(cli).to receive(:prompt_for_email).and_return(user_email)
      allow(cli).to receive(:ask).with('Paste your API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_return({ success: false })
      allow(cli).to receive(:error)
    end

    it 'shows connection error' do
      expect(cli).to receive(:error).with('Connection test failed')
      cli.onboard
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'error handling - no organizations' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '1')
      allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(true)
      allow(cli).to receive(:prompt_for_email).and_return(user_email)
      allow(cli).to receive(:ask).with('Paste your API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_return({ success: true })
      allow(client).to receive(:get).with('/api/v1/organizations').and_return({
                                                                                data: { 'organizations' => [] }
                                                                              })
      allow(cli).to receive(:error)
    end

    it 'shows no organizations error' do
      expect(cli).to receive(:error).with('No organizations found')
      cli.onboard
    end

    it 'shows helpful guidance' do
      expect { cli.onboard }.to output(/check that your token is associated/).to_stdout
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'error handling - unexpected error' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '1')
      allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(true)
      allow(cli).to receive(:prompt_for_email).and_return(user_email)
      allow(cli).to receive(:ask).with('Paste your API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_raise(StandardError, 'Network error')
      allow(cli).to receive(:error)
    end

    it 'shows setup failed error' do
      expect(cli).to receive(:error).with(/Setup failed/)
      cli.onboard
    end

    it 'suggests running setup again' do
      expect { cli.onboard }.to output(/Run 'mysigner onboard' to try again/).to_stdout
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'help text' do
    it 'has description' do
      command = Mysigner::CLI.commands['onboard']
      expect(command.description).to include('START HERE')
    end

    it 'has long description' do
      command = Mysigner::CLI.commands['onboard']
      long_desc = command.long_description
      expect(long_desc).to include('Step-by-step')
      expect(long_desc).to include('organization')
      expect(long_desc).to include('API token')
    end
  end

  describe 'integration tests', :integration do
    it 'shows help for onboard command' do
      stdout, _, status = Open3.capture3("#{exe_path} help onboard 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner onboard')
    end
  end

  # mysigner-44 — local-only branch. These specs encode the invariants the
  # whole local-only mode rests on: never POST credentials, always store
  # them via LocalCredentials, raise loud on bad input. A regression in any
  # of these silently breaks the offline path the epic depends on, so the
  # assertions are intentionally tight.
  describe 'local-only mode' do
    let(:ec_key)    { OpenSSL::PKey::EC.generate('prime256v1') }
    let(:p8_pem)    { ec_key.to_pem }
    let(:key_id)    { 'ABC123DEFG' }
    let(:issuer_id) { '69a6de70-1234-47e3-e053-5b8c7c11a4d1' }
    let(:sa_email)  { 'svc@my-project.iam.gserviceaccount.com' }
    let(:sa_json) do
      JSON.generate(
        'type' => 'service_account',
        'client_email' => sa_email,
        'private_key' => "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n",
        'project_id' => 'my-project'
      )
    end
    let(:p8_path)   { '/tmp/AuthKey_ABC123DEFG.p8' }
    let(:json_path) { '/tmp/sa.json' }

    before do
      # Force local-only on without touching ENV (Helpers#local_only? OR-s
      # flag and ENV — stubbing options is the cleanest path).
      allow(cli).to receive(:options).and_return({ local_only: true })
      # Suppress the banner in tests — its own contract lives in
      # local_only_spec.rb; here we don't care.
      allow(cli).to receive(:emit_local_only_banner)
      # File reads — point to in-memory PEM/JSON regardless of which path
      # the prompt returned.
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(p8_path).and_return(true)
      allow(File).to receive(:exist?).with(json_path).and_return(true)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(p8_path).and_return(p8_pem)
      allow(File).to receive(:read).with(json_path).and_return(sa_json)
      # Stub the store so we can assert on it AND avoid touching the
      # Keychain in CI.
      allow(Mysigner::LocalCredentials).to receive(:store).and_return(true)
      # The local-only path never reaches Mysigner::Client, but we install
      # a spy so the `not_to have_received(:post)` assertion is meaningful
      # rather than a no-op against `nil`.
      allow(Mysigner::Client).to receive(:new).and_return(client)
      allow(client).to receive(:post)
      allow(client).to receive(:get)
    end

    context 'user supplies both ASC and Google Play credentials' do
      before do
        # Both setup prompts: yes
        allow(cli).to receive(:yes_with_default?).and_return(true)
        # ASC prompts — Key ID auto-detects from filename, so only Issuer.
        allow(cli).to receive(:ask).with('Path to your .p8 private key:').and_return(p8_path)
        allow(cli).to receive(:ask).with('Enter your Issuer ID (UUID):').and_return(issuer_id)
        # Google Play prompt
        allow(cli).to receive(:ask).with('Path to your service-account JSON:').and_return(json_path)
      end

      it 'never POSTs credentials to the server' do
        cli.onboard
        expect(client).not_to have_received(:post)
      end

      it 'stores the ASC credential keyed by Key ID with a JSON envelope' do
        cli.onboard
        expect(Mysigner::LocalCredentials).to have_received(:store).with(
          kind: :asc,
          id: key_id,
          secret: satisfy { |s|
            payload = JSON.parse(s)
            payload['issuer_id'] == issuer_id && payload['p8_pem'] == p8_pem
          }
        )
      end

      it 'stores the Google Play credential keyed by client_email with raw SA-JSON' do
        cli.onboard
        expect(Mysigner::LocalCredentials).to have_received(:store).with(
          kind: :google_play,
          id: sa_email,
          secret: sa_json
        )
      end

      it 'prints the local-only completion summary' do
        expect { cli.onboard }.to output(/Local-only setup complete/).to_stdout
      end
    end

    context 'Android keystore collection (collect_local_keystore_credential)' do
      require 'base64'
      let(:ks_path) { '/tmp/mysigner_test_release.jks' }
      let(:ks_bytes) { "\x00KEYSTOREBYTES\xFF".b }

      before do
        allow(cli).to receive(:ask).with('Path to your keystore (.jks/.keystore):').and_return(ks_path)
        allow(cli).to receive(:ask).with('Keystore password:', echo: false).and_return('storepw')
        allow(cli).to receive(:ask).with('Key alias:').and_return('upload')
        allow(cli).to receive(:ask)
          .with('Key password (press Enter to reuse the keystore password):', echo: false).and_return('')
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(File.expand_path(ks_path)).and_return(true)
        allow(File).to receive(:binread).with(File.expand_path(ks_path)).and_return(ks_bytes)
      end

      it 'stores the keystore under :android_keystore in the resolver envelope shape' do
        cli.send(:collect_local_keystore_credential)
        expect(Mysigner::LocalCredentials).to have_received(:store).with(
          kind: :android_keystore,
          id: 'upload',
          secret: satisfy { |s|
            payload = JSON.parse(s)
            payload['keystore_b64'] == Base64.strict_encode64(ks_bytes) &&
              payload['keystore_password'] == 'storepw' &&
              payload['key_alias'] == 'upload' &&
              payload['key_password'] == 'storepw' # blank key pw reuses keystore pw
          }
        )
      end
    end

    context 'user skips both credentials' do
      before do
        allow(cli).to receive(:yes_with_default?).and_return(false)
      end

      it 'stores nothing and never POSTs' do
        cli.onboard
        expect(Mysigner::LocalCredentials).not_to have_received(:store)
        expect(client).not_to have_received(:post)
      end

      it 'tells the user nothing was stored' do
        expect { cli.onboard }.to output(/No credentials were stored/).to_stdout
      end
    end

    context 'invalid .p8 file' do
      before do
        # Only set up ASC; skip Play
        allow(cli).to receive(:yes_with_default?).with(/App Store Connect/, anything).and_return(true)
        allow(cli).to receive(:yes_with_default?).with(/Google Play/, anything).and_return(false)
        allow(cli).to receive(:ask).with('Path to your .p8 private key:').and_return(p8_path)
        # Replace the PEM with garbage — must raise loud, not silently store.
        allow(File).to receive(:read).with(p8_path).and_return('not a pem')
      end

      it 'fails cleanly (no raw backtrace) and stores nothing' do
        expect do
          expect { cli.onboard }.to raise_error(SystemExit)
        end.to output(/invalid \.p8/).to_stdout
        expect(Mysigner::LocalCredentials).not_to have_received(:store)
      end
    end

    context 'invalid service-account JSON' do
      before do
        allow(cli).to receive(:yes_with_default?).with(/App Store Connect/, anything).and_return(false)
        allow(cli).to receive(:yes_with_default?).with(/Google Play/, anything).and_return(true)
        allow(cli).to receive(:ask).with('Path to your service-account JSON:').and_return(json_path)
        # Missing required fields — must raise rather than write a broken
        # credential the minter will later choke on with a cryptic error.
        allow(File).to receive(:read).with(json_path).and_return(JSON.generate('type' => 'something_else'))
      end

      it 'fails cleanly (no raw backtrace) and stores nothing' do
        expect do
          expect { cli.onboard }.to raise_error(SystemExit)
        end.to output(/service-account JSON/).to_stdout
        expect(Mysigner::LocalCredentials).not_to have_received(:store)
      end
    end

    # mysigner-22 Phase 5 — when the user already has credentials reachable
    # by the auto-discovery cascade (env vars, ~/.appstoreconnect, project-
    # sniff, or Keychain) onboard MUST detect them and SKIP the interactive
    # prompt for that platform. WHY: the v1 onboard always prompted, which
    # was painful for users who already had Apple's standard layout set up.
    context 'when ASC creds already discoverable via env vars, skip the ASC prompt' do
      before do
        allow(cli).to receive(:yes_with_default?).and_return(false)
        # ASC discovery stub: pretend the resolver returns AscCreds from env.
        ec_pem = "-----BEGIN EC PRIVATE KEY-----\nfake\n-----END EC PRIVATE KEY-----\n"
        creds = Mysigner::CredentialResolver::AscCreds.new(
          key_id: 'PREEXISTING', issuer_id: 'iss', p8_pem: ec_pem, source: :env
        )
        allow(Mysigner::CredentialResolver).to receive(:resolve_asc).and_return(creds)
        # Play discovery still raises (nothing there) — falls through to the
        # original yes/no prompt for Google Play, which we said NO to above.
        allow(Mysigner::CredentialResolver).to receive(:resolve_play)
          .and_raise(Mysigner::CredentialResolver::CredentialNotFoundError, 'nope')
      end

      it 'tells the user we detected the credential and never prompts for ASC' do
        # The yes/no prompt for "Set up App Store Connect..." must be skipped
        # entirely when the resolver already finds a credential — i.e. we
        # must not pass that exact question to yes_with_default?.
        expect(cli).not_to receive(:yes_with_default?).with(/App Store Connect/, anything)
        # And we must not call the collector either.
        expect(cli).not_to receive(:collect_local_asc_credential)
        output = capture_stdout { cli.onboard }
        expect(output).to include('Detected App Store Connect credentials')
      end

      it 'still stores nothing for the skipped platform (no double-write)' do
        capture_stdout { cli.onboard }
        expect(Mysigner::LocalCredentials).not_to have_received(:store).with(hash_including(kind: :asc))
      end
    end

    context 'when local-only mode is OFF, the server-mediated path is unchanged' do
      # Sanity check: flipping the flag back to false must NOT short-circuit
      # into the local-only branch. We assert this by checking that the
      # legacy server prompt for an API token still appears.
      it 'falls through to the existing onboard flow' do
        allow(cli).to receive(:options).and_return({ local_only: false })
        allow(cli).to receive(:prompt_api_url).and_return(api_url)
        allow(cli).to receive(:ask).with('Select (1-2):', limited_to: %w[1 2]).and_return('1', '1', '2')
        allow(cli).to receive(:yes_with_default?).with(/Have you generated/, anything).and_return(true)
        allow(cli).to receive(:prompt_for_email).and_return(user_email)
        allow(cli).to receive(:ask).with('Paste your API Token:', echo: false).and_return(api_token)
        allow(client).to receive(:test_connection).and_return({ success: true })
        allow(client).to receive(:get).with('/api/v1/organizations').and_return(
          data: { 'organizations' => [{ 'id' => org_id, 'name' => 'Test Org' }] }
        )
        allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(data: org_data)
        allow(config).to receive(:api_url=)
        allow(config).to receive(:user_email=)
        allow(config).to receive(:current_organization_id=)
        allow(config).to receive(:save_token_for_org)

        expect { cli.onboard }.to output(/Setup Complete/).to_stdout
        # And the local store was never touched.
        expect(Mysigner::LocalCredentials).not_to have_received(:store)
      end
    end
  end

  # Helper method
  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end
end
