# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'mysigner/upload/app_store_automation'
require 'mysigner/upload/app_store_submission'

RSpec.describe 'mysigner submit', type: :cli do
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
      # Stub client and build detection to prevent execution from continuing past auth check
      allow(client).to receive(:get).and_return({ data: {} })
      allow(Mysigner::Build::Detector).to receive(:detect).and_raise(StandardError.new('No project'))
    end

    it 'shows error message' do
      output = capture_stdout { cli.submit }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.submit }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.submit
    end
  end

  describe 'when logged in' do
    let(:detector) { class_double(Mysigner::Build::Detector) }
    let(:parser) { instance_double(Mysigner::Build::Parser) }
    let(:main_target) { double('MainTarget', name: 'MyApp') }
    let(:automation) { instance_double(Mysigner::Upload::AppStoreAutomation) }
    let(:submission) { instance_double(Mysigner::Upload::AppStoreSubmission) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')
    end

    describe 'iOS submission' do
      before do
        allow(Mysigner::Build::Detector).to receive(:detect).and_return({ path: '/project', type: :xcode })
        allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
        allow(parser).to receive(:main_target).and_return(main_target)
        allow(parser).to receive(:bundle_id).and_return('com.example.app')
        allow(parser).to receive(:build_settings).and_return({ 'MARKETING_VERSION' => '1.0.0' })
        allow(Mysigner::Upload::AppStoreAutomation).to receive(:new).and_return(automation)
        allow(Mysigner::Upload::AppStoreSubmission).to receive(:new).and_return(submission)
        allow(submission).to receive(:submit_for_review!).and_return({
                                                                       automation: { submitted: true }
                                                                     })
      end

      context 'with bundle ID auto-detect' do
        it 'shows submit header' do
          output = capture_stdout { cli.submit }
          expect(output).to include('Submit for App Store Review')
        end

        it 'detects bundle ID from project' do
          expect(Mysigner::Build::Detector).to receive(:detect)
          cli.submit
        end

        it 'shows detected bundle ID' do
          output = capture_stdout { cli.submit }
          expect(output).to include('Detected bundle ID')
          expect(output).to include('com.example.app')
        end

        it 'shows success message when submitted' do
          output = capture_stdout { cli.submit }
          expect(output).to include('Submission Complete')
          expect(output).to include('submitted for App Store review')
        end
      end

      context 'with explicit --bundle-id' do
        before do
          cli.options = { bundle_id: 'com.explicit.app' }
        end

        it 'uses the provided bundle ID' do
          expect(Mysigner::Upload::AppStoreSubmission).to receive(:new) do |_client, _org, build_info, **_opts|
            expect(build_info[:bundle_id]).to eq('com.explicit.app')
            submission
          end
          cli.submit
        end
      end

      context 'with --version and --build-number' do
        before do
          cli.options = { version: '2.0.0', build_number: '42' }
        end

        it 'uses the provided version' do
          expect(Mysigner::Upload::AppStoreSubmission).to receive(:new) do |_client, _org, build_info, **_opts|
            expect(build_info[:version]).to eq('2.0.0')
            expect(build_info[:build_number]).to eq('42')
            submission
          end
          cli.submit
        end
      end

      context 'with --release-type AFTER_APPROVAL' do
        before do
          cli.options = { release_type: 'AFTER_APPROVAL' }
        end

        it 'sets release type in metadata' do
          expect(Mysigner::Upload::AppStoreSubmission).to receive(:new) do |_client, _org, _build_info, **opts|
            expect(opts[:metadata_overrides]['release_type']).to eq('AFTER_APPROVAL')
            submission
          end
          cli.submit
        end
      end

      context 'with --release-type MANUAL' do
        before do
          cli.options = { release_type: 'MANUAL' }
        end

        it 'sets release type to MANUAL' do
          expect(Mysigner::Upload::AppStoreSubmission).to receive(:new) do |_client, _org, _build_info, **opts|
            expect(opts[:metadata_overrides]['release_type']).to eq('MANUAL')
            submission
          end
          cli.submit
        end
      end

      context 'with --release-type SCHEDULED' do
        context 'without --scheduled-date' do
          before do
            cli.options = { release_type: 'SCHEDULED' }
          end

          it 'shows error about missing date' do
            output = capture_stdout { cli.submit }
            expect(output).to include('Scheduled release date is required')
            expect(output).to include('--release-type=SCHEDULED')
          end

          it 'exits with code 1' do
            expect(cli).to receive(:exit).with(1)
            cli.submit
          end
        end

        context 'with valid --scheduled-date' do
          before do
            future_date = (Time.now + (86_400 * 7)).utc.iso8601 # 7 days from now
            cli.options = { release_type: 'SCHEDULED', scheduled_date: future_date }
          end

          it 'sets scheduled release date' do
            expect(Mysigner::Upload::AppStoreSubmission).to receive(:new) do |_client, _org, _build_info, **opts|
              expect(opts[:metadata_overrides]['release_type']).to eq('SCHEDULED')
              expect(opts[:metadata_overrides]['earliest_release_date']).not_to be_nil
              submission
            end
            cli.submit
          end
        end
      end

      context 'with --scheduled-date in the past' do
        before do
          past_date = (Time.now - 86_400).utc.iso8601 # 1 day ago
          cli.options = { scheduled_date: past_date }
        end

        it 'shows error about past date' do
          output = capture_stdout { cli.submit }
          expect(output).to include('at least 1 hour in the future')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.submit
        end
      end

      context 'with --scheduled-date less than 1 hour in future' do
        before do
          near_future = (Time.now + 1800).utc.iso8601 # 30 minutes from now
          cli.options = { scheduled_date: near_future }
        end

        it 'shows error about minimum time' do
          output = capture_stdout { cli.submit }
          expect(output).to include('at least 1 hour in the future')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.submit
        end
      end

      context 'with invalid --scheduled-date format' do
        before do
          cli.options = { scheduled_date: 'not-a-date' }
        end

        it 'shows invalid format error' do
          output = capture_stdout { cli.submit }
          expect(output).to include('Invalid date format')
          expect(output).to include('ISO 8601')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.submit
        end
      end

      context 'with invalid --release-type' do
        before do
          cli.options = { release_type: 'INVALID' }
        end

        it 'shows error for invalid release type' do
          output = capture_stdout { cli.submit }
          expect(output).to include('Invalid release type')
        end

        it 'shows valid options' do
          output = capture_stdout { cli.submit }
          expect(output).to include('AFTER_APPROVAL')
          expect(output).to include('MANUAL')
          expect(output).to include('SCHEDULED')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.submit
        end
      end

      context 'when bundle ID detection fails' do
        before do
          allow(Mysigner::Build::Detector).to receive(:detect).and_raise(StandardError.new('No project'))
          cli.options = {}
        end

        it 'shows error message' do
          output = capture_stdout { cli.submit }
          expect(output).to include('Could not detect bundle ID')
        end

        it 'suggests manual bundle ID' do
          output = capture_stdout { cli.submit }
          expect(output).to include('--bundle-id')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.submit
        end
      end

      context 'with --whats-new override' do
        before do
          cli.options = { whats_new: 'New features and bug fixes' }
        end

        it 'includes whats_new in metadata' do
          expect(Mysigner::Upload::AppStoreSubmission).to receive(:new) do |_client, _org, _build_info, **opts|
            expect(opts[:metadata_overrides]['whats_new']).to eq('New features and bug fixes')
            submission
          end
          cli.submit
        end
      end

      context 'with --support-url override' do
        before do
          cli.options = { support_url: 'https://support.example.com' }
        end

        it 'includes support_url in metadata' do
          expect(Mysigner::Upload::AppStoreSubmission).to receive(:new) do |_client, _org, _build_info, **opts|
            expect(opts[:metadata_overrides]['support_url']).to eq('https://support.example.com')
            submission
          end
          cli.submit
        end
      end

      context 'when submission is skipped' do
        before do
          allow(submission).to receive(:submit_for_review!).and_return({
                                                                         automation: { submitted: false,
                                                                                       skip_reason: 'No eligible build found' }
                                                                       })
        end

        it 'shows skip message' do
          output = capture_stdout { cli.submit }
          expect(output).to include('Submission skipped')
          expect(output).to include('No eligible build found')
        end
      end

      context 'when submission fails with generic error' do
        before do
          allow(submission).to receive(:submit_for_review!).and_raise(
            StandardError.new('Unexpected error during submission')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.submit }
          expect(output).to include('Submission Failed').or include('Unexpected error')
        end
      end

      context 'when API client error occurs' do
        before do
          allow(submission).to receive(:submit_for_review!).and_raise(
            Mysigner::ClientError.new('API error')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.submit }
          expect(output).to include('API Error').or include('Submission Failed').or include('API error')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.submit
        end
      end
    end

    describe 'Android submission routing' do
      before do
        cli.options = { platform: 'android' }
        allow(cli).to receive(:submit_android)
      end

      it 'routes to Android submit' do
        expect(cli).to receive(:submit_android).with('production')
        cli.submit
      end

      it 'uses provided track for Android' do
        expect(cli).to receive(:submit_android).with('internal')
        cli.submit('internal')
      end
    end

    describe 'auto-detect Android from track' do
      before do
        allow(cli).to receive(:submit_android)
      end

      %w[internal alpha beta production].each do |track|
        it "routes to Android for #{track} track" do
          cli.options = {}
          expect(cli).to receive(:submit_android).with(track)
          cli.submit(track)
        end
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help submit]) }
      expect(help_output).to include('Submit')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['submit']) }
      expect(output).to include('Not logged in')
    end
  end
end
