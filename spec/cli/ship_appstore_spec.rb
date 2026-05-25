# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'mysigner/cli'
require 'mysigner/upload/app_store_submission'
require 'mysigner/upload/app_store_automation'

RSpec.describe 'App Store Distribution', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) do
    double('Config',
           api_token: 'test_token',
           organization_id: 'org-123',
           current_organization_id: 'org-123',
           user_email: 'test@example.com')
  end
  let(:client) { double('Client') }

  before do
    allow(cli).to receive(:config).and_return(config)
    allow(cli).to receive(:load_config).and_return(config)
    allow(cli).to receive(:create_client).and_return(client)
    allow(cli).to receive(:say)
    allow(cli).to receive(:error)
    allow(cli).to receive(:exit)
    # Force legacy altool upload path (default is ASC REST uploader now)
    ENV['MYSIGNER_USE_LEGACY_ASC'] = '1'
    # Prevent real sleep in polling loops (product calls global sleep, not cli.sleep)
    allow_any_instance_of(Object).to receive(:sleep)
    allow(client).to receive(:post).with(
      "/api/v1/organizations/#{config.current_organization_id}/sync",
      body: { force: true }
    ).and_return({ data: {} })
    # Stubs for step 2.5 (fetching current latest build) and step 4 (polling for new build)
    # Return build 2 in both — step 2.5 sets latest_build_before_upload = 2,
    # step 4 loop compares to new builds. We make the loop break by returning
    # build with higher number (3) on subsequent calls; simplest: make first call
    # return empty so latest_build_before_upload stays nil → any build wins.
    # Simpler: return a build in step 2.5 AND a build with same number in step 4;
    # since 2 > 2 is false, loop never breaks. Use build_number 0 in step 2.5,
    # build_number 1 in step 4.
    @builds_calls = 0
    allow(client).to receive(:get).with(
      "/api/v1/organizations/#{config.current_organization_id}/apple_apps",
      params: anything
    ).and_return({ data: { 'data' => { 'apps' => [{ 'id' => 'app-1' }] } } })
    allow(client).to receive(:get).with(
      "/api/v1/organizations/#{config.current_organization_id}/builds",
      params: anything
    ) do
      @builds_calls += 1
      build_num = @builds_calls == 1 ? '0' : '99'
      { data: { 'data' => { 'builds' => [{ 'build_number' => build_num, 'processing_state' => 'PROCESSING_COMPLETE' }] } } }
    end
  end

  after do
    ENV.delete('MYSIGNER_USE_LEGACY_ASC')
  end

  describe 'mysigner ship appstore' do
    it 'shows help for ship command' do
      expect { cli.help(:ship) }.to output(/appstore/).to_stdout
    end

    it 'includes appstore in valid targets' do
      expect { cli.help(:ship) }.to output(/testflight.*appstore/m).to_stdout
    end

    it 'shows --release-type option' do
      expect { cli.help(:ship) }.to output(/--release-type/).to_stdout
    end

    it 'accepts appstore as valid target' do
      cli.options = {}

      # Mock all the steps
      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
                                                                        path: '/path/to/project.xcodeproj',
                                                                        type: :project,
                                                                        directory: '/path/to',
                                                                        framework: :native
                                                                      })

      parser = double('Parser')
      allow(parser).to receive(:main_target).and_return(double(name: 'MyApp'))
      allow(parser).to receive(:bundle_id).and_return('com.example.app')
      allow(parser).to receive(:team_id).and_return('ABCD123456')
      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:code_sign_style).and_return('Automatic')
      allow(parser).to receive(:build_settings).and_return({
                                                             'MARKETING_VERSION' => '1.0.0',
                                                             'CURRENT_PROJECT_VERSION' => '1'
                                                           })
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)

      validator = double('Validator')
      allow(validator).to receive(:validate!)
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)

      executor = double('Executor')
      allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)

      exporter = double('Exporter')
      allow(exporter).to receive(:export!).and_return('/path/to/app.ipa')
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)

      # Mock API responses
      allow(client).to receive(:get).with('/api/v1/organizations/org-123').and_return({
                                                                                        data: {
                                                                                          'app_store_connect_configured' => true,
                                                                                          'app_store_connect_key_id' => 'KEY123',
                                                                                          'app_store_connect_issuer_id' => 'ISSUER123',
                                                                                          'app_store_connect_private_key' => 'PRIVATE_KEY',
                                                                                          'app_store_connect_team_id' => 'TEAM123'
                                                                                        }
                                                                                      })

      uploader = double('Uploader')
      allow(uploader).to receive(:upload!)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)

      # Stub submission flow (always runs for appstore)
      submission = double('Submission', submit_for_review!: {
                            success: true, metadata: {}, automation: { wait: {}, submitted: false }
                          })
      allow(Mysigner::Upload::AppStoreSubmission).to receive(:new).and_return(submission)
      automation = double('Automation')
      allow(Mysigner::Upload::AppStoreAutomation).to receive(:new).and_return(automation)

      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:size).and_return(10_000_000)

      # Should not raise error
      expect { cli.ship('appstore') }.not_to raise_error
    end

    it 'rejects invalid targets' do
      cli.options = {}

      expect(cli).to receive(:error).with(/Invalid target/)
      expect(cli).to receive(:exit).with(1)

      cli.ship('invalid')
    end
  end

  describe 'submission flow' do
    let(:parser) do
      double('Parser',
             main_target: double(name: 'MyApp'),
             bundle_id: 'com.example.app',
             team_id: 'ABCD123456',
             product_type: :app,
             has_extensions?: false,
             code_sign_style: 'Automatic',
             build_settings: {
               'MARKETING_VERSION' => '1.0.0',
               'CURRENT_PROJECT_VERSION' => '1'
             })
    end

    before do
      cli.options = { submit_for_review: true }

      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
                                                                        path: '/path/to/project.xcodeproj',
                                                                        type: :project,
                                                                        directory: '/path/to',
                                                                        framework: :native
                                                                      })

      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)

      validator = double('Validator')
      allow(validator).to receive(:validate!)
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)

      executor = double('Executor')
      allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)

      exporter = double('Exporter')
      allow(exporter).to receive(:export!).and_return('/path/to/app.ipa')
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)

      allow(client).to receive(:get).with('/api/v1/organizations/org-123').and_return({
                                                                                        data: {
                                                                                          'app_store_connect_configured' => true,
                                                                                          'app_store_connect_key_id' => 'KEY123',
                                                                                          'app_store_connect_issuer_id' => 'ISSUER123',
                                                                                          'app_store_connect_private_key' => 'PRIVATE_KEY',
                                                                                          'app_store_connect_team_id' => 'TEAM123'
                                                                                        }
                                                                                      })

      uploader = double('Uploader')
      allow(uploader).to receive(:upload!)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)

      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:size).and_return(10_000_000)
    end

    it 'calls submission when --submit-for-review is passed' do
      submission = instance_double(Mysigner::Upload::AppStoreSubmission)
      automation = instance_double(Mysigner::Upload::AppStoreAutomation)

      expect(Mysigner::Upload::AppStoreAutomation).to receive(:new).and_return(automation)
      expect(submission).to receive(:submit_for_review!).with(automation: automation).and_return({ success: true,
                                                                                                   metadata: {}, automation: { wait: {}, submitted: false } })
      expect(Mysigner::Upload::AppStoreSubmission).to receive(:new).and_return(submission)

      cli.ship('appstore')
    end

    it 'passes correct build info to submission and reports automation outcome' do
      cli.options = { submit_for_review: true, auto_submit: true }
      automation = instance_double(Mysigner::Upload::AppStoreAutomation)
      allow(Mysigner::Upload::AppStoreAutomation).to receive(:new).and_return(automation)

      expect(Mysigner::Upload::AppStoreSubmission).to receive(:new).with(
        client,
        'org-123',
        hash_including(
          bundle_id: 'com.example.app',
          build_number: '99'
        ),
        metadata_overrides: hash_including('auto_submit' => true),
        override_sources: array_including(hash_including(type: :inline))
      ).and_return(double('Submission', submit_for_review!: {
                            success: true,
                            metadata: {},
                            automation: {
                              wait: {
                                enabled: true,
                                poll_seconds: 15,
                                timeout_seconds: 900,
                                timed_out: false,
                                elapsed_seconds: 10,
                                last_state: 'PROCESSING_COMPLETE'
                              },
                              submitted: true,
                              submission_source: 'Dashboard configuration'
                            }
                          }))

      cli.ship('appstore')
    end

    it 'always submits for App Store target (product no longer supports skipping)' do
      # NOTE: product refactor — ship appstore always submits; --submit-for-review
      # option no longer exists. Verify submission IS called even without options.
      cli.options = {}

      submission = double('Submission', submit_for_review!: {
                            success: true, metadata: {}, automation: { wait: {}, submitted: true }
                          })
      expect(Mysigner::Upload::AppStoreAutomation).to receive(:new)
      expect(Mysigner::Upload::AppStoreSubmission).to receive(:new).and_return(submission)

      cli.ship('appstore')
    end
  end

  describe 'metadata overrides' do
    let(:parser) do
      double('Parser',
             main_target: double(name: 'MyApp'),
             bundle_id: 'com.example.app',
             team_id: 'ABCD123456',
             product_type: :app,
             has_extensions?: false,
             code_sign_style: 'Automatic',
             build_settings: {
               'MARKETING_VERSION' => '1.0.0',
               'CURRENT_PROJECT_VERSION' => '1'
             })
    end

    before do
      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
                                                                        path: '/path/to/project.xcodeproj',
                                                                        type: :project,
                                                                        directory: '/path/to',
                                                                        framework: :native
                                                                      })

      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)

      validator = double('Validator', validate!: true)
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)

      executor = double('Executor', build!: '/path/to/archive.xcarchive')
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)

      exporter = double('Exporter', export!: '/path/to/app.ipa')
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)

      allow(client).to receive(:get).with('/api/v1/organizations/org-123').and_return({
                                                                                        data: {
                                                                                          'app_store_connect_configured' => true,
                                                                                          'app_store_connect_key_id' => 'KEY123',
                                                                                          'app_store_connect_issuer_id' => 'ISSUER123',
                                                                                          'app_store_connect_private_key' => 'PRIVATE_KEY',
                                                                                          'app_store_connect_team_id' => 'TEAM123'
                                                                                        }
                                                                                      })

      uploader = double('Uploader', upload!: true)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)

      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:size).and_return(10_000_000)
    end

    it 'passes release notes override to the submission' do
      cli.options = { release_notes: 'CLI release notes' }

      automation = instance_double(Mysigner::Upload::AppStoreAutomation)
      allow(Mysigner::Upload::AppStoreAutomation).to receive(:new).and_return(automation)

      expect(Mysigner::Upload::AppStoreSubmission).to receive(:new).with(
        client,
        'org-123',
        hash_including(
          bundle_id: 'com.example.app',
          build_number: '99'
        ),
        metadata_overrides: hash_including('whats_new' => 'CLI release notes'),
        override_sources: array_including(hash_including(type: :inline))
      ).and_return(double('Submission', submit_for_review!: { success: true, metadata: {}, automation: { wait: {} } }))

      cli.ship('appstore')
    end

    it 'passes metadata file overrides to the submission' do
      Tempfile.create(['metadata', '.json']) do |file|
        file.write({ support_url: 'https://example.com/support', phased_release: true }.to_json)
        file.flush

        cli.options = { metadata_file: file.path }

        automation = instance_double(Mysigner::Upload::AppStoreAutomation)
        allow(Mysigner::Upload::AppStoreAutomation).to receive(:new).and_return(automation)

        expect(Mysigner::Upload::AppStoreSubmission).to receive(:new).with(
          client,
          'org-123',
          hash_including(
            bundle_id: 'com.example.app',
            build_number: '99'
          ),
          metadata_overrides: hash_including(
            'support_url' => 'https://example.com/support',
            'phased_release' => true
          ),
          override_sources: array_including(hash_including(type: :file, path: file.path))
        ).and_return(double('Submission',
                            submit_for_review!: { success: true, metadata: {}, automation: { wait: {} } }))

        cli.ship('appstore')
      end
    end

    it 'fails fast when metadata file is missing' do
      missing_path = File.join(Dir.tmpdir, 'missing_metadata.json')
      cli.options = { submit_for_review: true, metadata_file: missing_path }

      expect(Mysigner::Upload::AppStoreSubmission).not_to receive(:new)
      expect(cli).to receive(:say).with("Error: Metadata file not found: #{File.expand_path(missing_path)}", :red)
      expect(cli).to receive(:exit).with(1)

      cli.ship('appstore')
    end
  end

  describe 'App Store messages' do
    before do
      cli.options = {}

      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
                                                                        path: '/path/to/project.xcodeproj',
                                                                        type: :project,
                                                                        directory: '/path/to',
                                                                        framework: :native
                                                                      })

      parser = double('Parser')
      allow(parser).to receive(:main_target).and_return(double(name: 'MyApp'))
      allow(parser).to receive(:bundle_id).and_return('com.example.app')
      allow(parser).to receive(:team_id).and_return('ABCD123456')
      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:code_sign_style).and_return('Automatic')
      allow(parser).to receive(:build_settings).and_return({})
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)

      validator = double('Validator')
      allow(validator).to receive(:validate!)
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)

      executor = double('Executor')
      allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)

      exporter = double('Exporter')
      allow(exporter).to receive(:export!).and_return('/path/to/app.ipa')
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)

      allow(client).to receive(:get).with('/api/v1/organizations/org-123').and_return({
                                                                                        data: {
                                                                                          'app_store_connect_configured' => true,
                                                                                          'app_store_connect_key_id' => 'KEY123',
                                                                                          'app_store_connect_issuer_id' => 'ISSUER123',
                                                                                          'app_store_connect_private_key' => 'PRIVATE_KEY'
                                                                                        }
                                                                                      })

      uploader = double('Uploader')
      allow(uploader).to receive(:upload!)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)

      # Stub submission flow (always runs for appstore)
      submission = double('Submission', submit_for_review!: {
                            success: true, metadata: {}, automation: { wait: {}, submitted: true }
                          })
      allow(Mysigner::Upload::AppStoreSubmission).to receive(:new).and_return(submission)
      automation = double('Automation')
      allow(Mysigner::Upload::AppStoreAutomation).to receive(:new).and_return(automation)

      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:size).and_return(10_000_000)
    end

    it 'shows App Store-specific messages' do
      expect(cli).to receive(:say).with(/Ship to App Store/, :cyan).at_least(:once)

      cli.ship('appstore')
    end

    it 'shows different next steps for App Store vs TestFlight' do
      expect(cli).to receive(:say).with(/submitted for App Store review/, anything).at_least(:once)

      cli.ship('appstore')
    end
  end

  # mysigner-22 Phase 5 — ship registers the new local-only credential
  # auto-discovery override flags. They are no-ops in vault mode (the resolver
  # is only invoked when local_only? is true) but must always be PARSEABLE so
  # users can put them in shell scripts without conditionally constructing the
  # command line. This is a Thor schema assertion, not a behavior assertion.
  describe '--asc-key-path / --asc-key-id / --asc-issuer-id / --play-credentials flag registration' do
    let(:command) { Mysigner::CLI.commands['ship'] }

    it 'registers --asc-key-path as a string option on `ship`' do
      expect(command.options).to have_key(:asc_key_path)
      expect(command.options[:asc_key_path].type).to eq(:string)
    end

    it 'registers --asc-key-id as a string option on `ship`' do
      expect(command.options).to have_key(:asc_key_id)
      expect(command.options[:asc_key_id].type).to eq(:string)
    end

    it 'registers --asc-issuer-id as a string option on `ship`' do
      expect(command.options).to have_key(:asc_issuer_id)
      expect(command.options[:asc_issuer_id].type).to eq(:string)
    end

    it 'registers --play-credentials as a string option on `ship`' do
      expect(command.options).to have_key(:play_credentials)
      expect(command.options[:play_credentials].type).to eq(:string)
    end

    it 'shows the new flags in `mysigner help ship`' do
      expect { cli.help(:ship) }.to output(/--asc-key-path.*--play-credentials/m).to_stdout
    end
  end

  # mysigner-22 Phase 5 — the CLI passes the Thor options hash to the
  # resolver. This is the load-bearing assertion for the entire override
  # contract (--asc-key-path / --asc-key-id / --asc-issuer-id): if the
  # helper drops the options on the floor, the flags would silently lose
  # to env / Keychain / disk in the cascade. We test the helper directly
  # rather than driving full `ship appstore` orchestration end-to-end.
  describe 'resolve_local_asc_creds_or_exit passes Thor options into the resolver' do
    let(:cli_with_options) do
      Mysigner::CLI.new.tap do |c|
        c.options = { asc_key_path: '/some/AuthKey_X.p8', asc_key_id: 'X',
                      asc_issuer_id: 'iss-uuid', local_only: true }
      end
    end

    it 'forwards options[:asc_key_path] / [:asc_key_id] / [:asc_issuer_id] to CredentialResolver.resolve_asc' do
      stub_creds = Mysigner::CredentialResolver::AscCreds.new(
        key_id: 'X', issuer_id: 'iss-uuid', p8_pem: 'pem', source: :flag
      )
      expect(Mysigner::CredentialResolver).to receive(:resolve_asc)
        .with(options: hash_including(asc_key_path: '/some/AuthKey_X.p8',
                                      asc_key_id: 'X',
                                      asc_issuer_id: 'iss-uuid'))
        .and_return(stub_creds)

      result = cli_with_options.resolve_local_asc_creds_or_exit
      expect(result.source).to eq(:flag)
    end
  end

  # mysigner-22 — the load-bearing contract for `ship appstore --local-only`
  # on a fresh machine with NO MySigner config at all (no ~/.mysigner/config.yml,
  # no env vars, no API token, no login). Every MySigner-server call the
  # vault-mode flow made (sync, /apple_apps, /builds, /app_store_releases,
  # /organizations/<id>) must be bypassed; only Apple is contacted.
  #
  # The single load-bearing assertion is:
  #   expect(WebMock).not_to have_requested(:any, /mysigner|ngrok/)
  # A regression that re-introduces ANY MySigner-shaped URL in the local-only
  # branch will flip that expectation.
  describe 'fully local-only (no MySigner config at all)' do
    require 'webmock/rspec'
    require 'openssl'
    require 'mysigner/credential_resolver'

    let(:cli_local) { Mysigner::CLI.new }
    let(:p8_pem) { OpenSSL::PKey::EC.generate('prime256v1').to_pem }
    let(:asc_creds) do
      Mysigner::CredentialResolver::AscCreds.new(
        key_id: 'KEY123', issuer_id: 'iss-uuid', p8_pem: p8_pem, source: :flag
      )
    end

    before do
      # No `--local-only` flag at the CLI level here because we set it via
      # options on the instance; the bug was that load_config didn't honor
      # local-only at all.
      cli_local.options = {
        local_only: true,
        team: 'TEAM12345',
        asc_key_path: '/fake/AuthKey_KEY123.p8',
        asc_key_id: 'KEY123',
        asc_issuer_id: 'iss-uuid'
      }
      allow(cli_local).to receive(:say)
      allow(cli_local).to receive(:exit) { |code| raise SystemExit, code.to_s }

      # Make sure no MySigner ENV slips in.
      ENV.delete('MYSIGNER_API_TOKEN')
      ENV.delete('MYSIGNER_ORG_ID')
      ENV.delete('MYSIGNER_API_URL')
      ENV.delete('MYSIGNER_LOCAL_ONLY')

      # No real sleep in poll loops.
      allow_any_instance_of(Object).to receive(:sleep)

      # Force the new REST path (the legacy altool path is server-mediated).
      ENV.delete('MYSIGNER_USE_LEGACY_ASC')

      # CredentialResolver — short-circuit the cascade with a static struct so
      # the test doesn't touch Keychain / disk / prompt. Verifying the
      # resolver itself is covered by credential_resolver_spec.
      allow(Mysigner::CredentialResolver).to receive(:resolve_asc).and_return(asc_creds)

      # Build / export pipeline — same stubs as the vault-mode tests above.
      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
                                                                        path: '/path/to/project.xcodeproj',
                                                                        type: :project,
                                                                        directory: '/path/to',
                                                                        framework: :native
                                                                      })

      parser = double('Parser')
      allow(parser).to receive(:main_target).and_return(double(name: 'MyApp'))
      allow(parser).to receive(:bundle_id).and_return('com.example.app')
      allow(parser).to receive(:team_id).and_return('TEAM12345')
      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:code_sign_style).and_return('Automatic')
      allow(parser).to receive(:build_settings).and_return({})
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)

      validator = double('Validator')
      allow(validator).to receive(:validate!)
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)

      executor = double('Executor')
      allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)

      exporter = double('Exporter')
      allow(exporter).to receive(:export!).and_return('/path/to/app.ipa')
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)

      # IPA introspection — short-circuit the unzip/plutil shell-out.
      allow(Mysigner::Upload::Uploader).to receive(:extract_ipa_info)
        .with('/path/to/app.ipa')
        .and_return(cf_bundle_version: '42', cf_bundle_short_version_string: '1.2', bundle_id: 'com.example.app')

      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:size).and_return(10_000_000)
      allow(File).to receive(:open).and_yield(StringIO.new('hello'))
      allow(Digest::MD5).to receive(:file).and_return(double(hexdigest: 'md5-fake'))
      allow(Digest::SHA256).to receive(:file).and_return(double(hexdigest: 'sha-fake'))

      # Apple endpoints we still hit directly: the /v1/apps lookup for
      # bundle-id → apple_app_id disambiguation. The upload itself now
      # delegates to altool (stubbed below) rather than raw REST, so we
      # no longer stub /v1/buildUploads.
      stub_request(:get, %r{https://api\.appstoreconnect\.apple\.com/v1/apps\?filter})
        .to_return(
          status: 200,
          body: { data: [{ 'id' => '999111222', 'type' => 'apps' }] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      # mysigner-46 — local-only ship delegates the upload to `xcrun altool
      # --upload-app`. We stub Open3.capture2e to keep tests hermetic (no
      # real shell-out, no real network to Apple). The altool path writes
      # the .p8 into ~/.appstoreconnect/private_keys/ as part of its
      # invocation; we stub the FS calls so the test doesn't touch the
      # user's real keychain dir.
      canonical_p8 = File.expand_path('~/.appstoreconnect/private_keys/AuthKey_KEY123.p8')
      canonical_dir = File.expand_path('~/.appstoreconnect/private_keys')
      allow(FileUtils).to receive(:mkdir_p).with(canonical_dir, anything)
      allow(File).to receive(:write).with(canonical_p8, anything)
      allow(File).to receive(:chmod).with(0o600, canonical_p8)
      # The broad `allow(File).to receive(:exist?).and_return(true)` above
      # this block would otherwise short-circuit ensure_p8_in_apple_dir!
      # into the read-and-compare branch; force false here so the write
      # branch runs and we exercise the canonical-path codepath.
      allow(File).to receive(:exist?).with(canonical_p8).and_return(false)

      allow(Open3).to receive(:capture2e)
        .and_return(['{"tool-version":"4.0"}', instance_double('Process::Status', success?: true)])

      # mysigner-22 follow-up — local-only auto-submit (default true) drives
      # Apple's REST API directly. The submitter is unit-tested in its own
      # spec; these CLI tests stub it so we exercise the wiring without
      # hitting Apple. Tests asserting the auto-submit wiring itself are
      # below in the explicit "auto-submit" context.
      require 'mysigner/upload/asc_submitter'
      submitter_double = instance_double(Mysigner::Upload::AscSubmitter, submit!: 'SUB_ID')
      allow(Mysigner::Upload::AscSubmitter).to receive(:new).and_return(submitter_double)
    end

    it 'does not call load_config in a way that requires a MySigner login (no "Not logged in" exit)' do
      # The most direct verification of the helpers bug fix: load_config returns
      # a Config sentinel without exiting, and create_client returns nil.
      expect { cli_local.load_config }.not_to raise_error
      expect(cli_local.create_client(cli_local.load_config)).to be_nil
    end

    it 'completes ship appstore end-to-end without ever calling a MySigner-shaped URL' do
      WebMock.reset_executed_requests!
      captured_argv = nil
      allow(Open3).to receive(:capture2e) do |*argv|
        captured_argv = argv
        ['{"tool-version":"4.0"}', instance_double('Process::Status', success?: true)]
      end

      cli_local.ship('appstore')

      # Load-bearing assertion: a regression that re-adds any /api/v1/...
      # MySigner call inside the local-only ship branch will flip this.
      expect(WebMock).not_to have_requested(:any, /mysigner|ngrok/)

      # Confidence-positive: Apple WAS contacted for the /v1/apps lookup,
      # and the upload was delegated to altool (no raw /v1/buildUploads
      # POST anymore — mysigner-46).
      expect(WebMock).to have_requested(:get,
                                        %r{https://api\.appstoreconnect\.apple\.com/v1/apps}).at_least_once
      expect(captured_argv).to start_with('xcrun', 'altool', '--upload-app')
    end

    it 'honors --apple-id and skips the bundleId lookup against Apple entirely' do
      cli_local.options = cli_local.options.merge(apple_id: '555444333')
      WebMock.reset_executed_requests!
      captured_argv = nil
      allow(Open3).to receive(:capture2e) do |*argv|
        captured_argv = argv
        ['{"tool-version":"4.0"}', instance_double('Process::Status', success?: true)]
      end

      cli_local.ship('appstore')

      # Override means we don't even ask Apple to disambiguate.
      expect(WebMock).not_to have_requested(:get,
                                            %r{https://api\.appstoreconnect\.apple\.com/v1/apps\?filter})
      # And the upload still went through via altool — verify altool was
      # invoked with the IPA path we expect. The apple_app_id override is
      # only used for the /v1/apps lookup skip; altool's --upload-app
      # discovers the app from the IPA's bundle id internally.
      expect(captured_argv).to start_with('xcrun', 'altool', '--upload-app')
      expect(captured_argv).to include('--file', '/path/to/app.ipa')
    end

    it 'exits 1 with a clear --apple-id hint when Apple returns zero matches for the bundleId' do
      stub_request(:get, %r{https://api\.appstoreconnect\.apple\.com/v1/apps\?filter})
        .to_return(
          status: 200, body: { data: [] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect(cli_local).to receive(:say).with(/No App Store Connect app found/, :red).at_least(:once)
      expect(cli_local).to receive(:say).with(/--apple-id/, :yellow).at_least(:once)
      expect { cli_local.ship('appstore') }.to raise_error(SystemExit)
    end

    # mysigner-22 follow-up — auto-submit (default true) drives Apple's
    # REST submission flow via AscSubmitter, replacing the old "submit-for-
    # review is not automated" banner. These specs pin the wiring contract
    # so a regression that drops the call or flips the default surfaces here.
    describe 'auto-submit' do
      it 'invokes AscSubmitter.submit! by default (auto-submit defaults to true)' do
        # The before-block stub already covers AscSubmitter.new — assert
        # the call was actually made with the right args here.
        expect(Mysigner::Upload::AscSubmitter).to receive(:new).with(
          hash_including(
            apple_app_id: '999111222',
            cf_bundle_version: '42',
            cf_bundle_short_version_string: '1.2'
          )
        ).and_return(instance_double(Mysigner::Upload::AscSubmitter, submit!: 'SUB_ID'))

        cli_local.ship('appstore')
      end

      it 'skips AscSubmitter.submit! when --no-auto-submit is passed' do
        cli_local.options = cli_local.options.merge(auto_submit: false)

        # No call to .new — confirms the opt-out path runs.
        expect(Mysigner::Upload::AscSubmitter).not_to receive(:new)

        cli_local.ship('appstore')
      end

      it 'exits 1 with a build-still-processing hint on BuildProcessingTimeoutError' do
        timeout_err = Mysigner::Upload::AscSubmitter::BuildProcessingTimeoutError.new(
          'Apple did not finish processing build 42 within 30 minutes.'
        )
        timed_out = instance_double(Mysigner::Upload::AscSubmitter)
        allow(timed_out).to receive(:submit!).and_raise(timeout_err)
        allow(Mysigner::Upload::AscSubmitter).to receive(:new).and_return(timed_out)

        expect { cli_local.ship('appstore') }.to raise_error(SystemExit)
      end

      it 'exits 1 carrying Apple\'s verbatim rejection on SubmissionRejectedError (missing metadata case)' do
        # Mirrors the asc_submitter_spec contract: the rejection class
        # message is what we surface to the user. The CLI rescue must NOT
        # mangle it — the user needs the literal Apple body to act.
        rejection = Mysigner::Upload::AscSubmitter::SubmissionRejectedError.new(
          "Apple POST /v1/appStoreVersionSubmissions returned 409: missing 'whatsNew'"
        )
        rejected = instance_double(Mysigner::Upload::AscSubmitter)
        allow(rejected).to receive(:submit!).and_raise(rejection)
        allow(Mysigner::Upload::AscSubmitter).to receive(:new).and_return(rejected)

        expect(cli_local).to receive(:say).with(/whatsNew/, :red).at_least(:once)
        expect { cli_local.ship('appstore') }.to raise_error(SystemExit)
      end
    end
  end
end
