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
end
