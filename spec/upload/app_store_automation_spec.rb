# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/upload/app_store_automation'

RSpec.describe Mysigner::Upload::AppStoreAutomation do
  let(:client) { instance_double(Mysigner::Client) }
  let(:organization_id) { 'org-123' }
  let(:now) { Time.parse('2025-10-13 12:00:00 UTC') }
  let(:clock) { -> { @fake_now } }
  let(:build_info) do
    {
      bundle_id: 'com.example.app',
      version: '1.2.0',
      build_number: '123'
    }
  end
  let(:metadata) do
    {
      'whats_new' => 'Bug fixes',
      'auto_submit' => true
    }
  end
  let(:automation) do
    described_class.new(
      client: client,
      organization_id: organization_id,
      opts: {
        wait: wait,
        poll_interval: poll_interval,
        timeout: timeout,
        no_submit: no_submit,
        now: clock
      }
    )
  end
  let(:wait) { true }
  let(:poll_interval) { 5 }
  let(:timeout) { 60 }
  let(:no_submit) { false }

  before do
    @fake_now = now
  end

  def advance(seconds)
    @fake_now += seconds
  end

  describe '#perform!' do
    let(:app) { { 'id' => 'app-1', 'bundle_identifier' => 'com.example.app' } }
    let(:build_ready) do
      {
        'id' => 'build-1',
        'processing_state' => 'VALID'
      }
    end
    let(:version) { { 'id' => 'ver-1', 'versionString' => '1.2.0' } }

    before do
      # Mock apple_apps endpoint
      allow(client).to receive(:get).with(
        "/api/v1/organizations/#{organization_id}/apple_apps",
        params: { bundle_id: build_info[:bundle_id] }
      ).and_return({ data: { 'data' => { 'apps' => [app] } } })

      # Mock app_store_versions POST (create version)
      allow(client).to receive(:post).with(
        "/api/v1/organizations/#{organization_id}/app_store_versions",
        hash_including(:body)
      ).and_return({ data: { 'data' => version } })

      # Mock attaching build to version
      allow(client).to receive(:post).with(
        "/api/v1/organizations/#{organization_id}/app_store_versions/#{version['id']}/build",
        body: { build_id: build_ready['id'] }
      )

      # Mock submit endpoint (now receives body with payload)
      allow(client).to receive(:post).with(
        "/api/v1/organizations/#{organization_id}/app_store_versions/#{version['id']}/submit",
        hash_including(:body)
      )

      allow(client).to receive(:patch)
    end

    context 'when interrupted (Ctrl-C) during the wait' do
      before do
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{organization_id}/builds", anything
        ).and_return({ data: { 'data' => { 'builds' => [{ 'id' => 'b', 'processing_state' => 'PROCESSING' }] } } })
        allow(automation).to receive(:sleep).and_raise(Interrupt)
      end

      it 'exits with the SIGINT code (130)' do
        allow(automation).to receive(:puts) # swallow the hint
        expect { automation.send(:wait_for_build, app['id'], build_info) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(130) }
      end

      it 'prints a resume hint instead of leaving a half-drawn line' do
        expect do
          automation.send(:wait_for_build, app['id'], build_info)
        rescue SystemExit
          nil
        end.to output(/Stopped waiting.*Re-run/m).to_stdout
      end
    end

    context 'when wait is enabled and build processes before timeout' do
      before do
        calls = 0
        # When wait is enabled, processed_only is false
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{organization_id}/builds",
          params: {
            app_id: app['id'],
            processed_only: false,
            version: build_info[:version],
            build_number: build_info[:build_number]
          }
        ) do
          calls += 1
          advance(poll_interval)
          if calls < 3
            { data: { 'data' => { 'builds' => [{ 'id' => 'build-1', 'processing_state' => 'PROCESSING' }] } } }
          else
            { data: { 'data' => { 'builds' => [build_ready] } } }
          end
        end

        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{organization_id}/app_store_versions",
          params: { app_id: app['id'], editable: true }
        ).and_return({ data: { 'data' => { 'versions' => [] } } })
      end

      it 'waits for the build, creates version, attaches build, and submits with telemetry' do
        expect(client).to receive(:post).with(
          "/api/v1/organizations/#{organization_id}/app_store_versions",
          body: hash_including(app_store_version: hash_including(app_id: app['id']))
        )

        expect(client).to receive(:post).with(
          "/api/v1/organizations/#{organization_id}/app_store_versions/#{version['id']}/submit",
          hash_including(:body)
        )

        result = automation.perform!(metadata: metadata, build_info: build_info, metadata_overrides: {})

        expect(result[:wait]).to include(
          enabled: true,
          poll_seconds: poll_interval,
          timeout_seconds: timeout,
          timed_out: false
        )
        expect(result[:submitted]).to be true
        expect(result[:submission_source]).to eq('Dashboard configuration')
      end
    end

    context 'when build never processes before timeout' do
      let(:timeout) { 10 }

      before do
        # When wait is enabled, processed_only is false
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{organization_id}/builds",
          params: {
            app_id: app['id'],
            processed_only: false,
            version: build_info[:version],
            build_number: build_info[:build_number]
          }
        ) do
          advance(poll_interval)
          { data: { 'data' => { 'builds' => [{ 'id' => 'build-1', 'processing_state' => 'PROCESSING' }] } } }
        end
      end

      it 'raises an error after timing out and sets timeout indicator' do
        expect do
          automation.perform!(metadata: metadata, build_info: build_info, metadata_overrides: {})
        end.to raise_error(Mysigner::Upload::AppStoreAutomation::AutomationError, /still processing/)
      end
    end

    context 'when wait is disabled' do
      let(:wait) { false }

      before do
        # When wait is disabled, processed_only is true
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{organization_id}/builds",
          params: {
            app_id: app['id'],
            processed_only: true,
            version: build_info[:version],
            build_number: build_info[:build_number]
          }
        ).and_return({ data: { 'data' => { 'builds' => [build_ready] } } })

        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{organization_id}/app_store_versions",
          params: { app_id: app['id'], editable: true }
        ).and_return({ data: { 'data' => { 'versions' => [] } } })
      end

      it 'performs automation without polling' do
        expect do
          automation.perform!(metadata: metadata, build_info: build_info, metadata_overrides: {})
        end.not_to raise_error
      end
    end

    context 'when auto submit is disabled' do
      let(:no_submit) { true }

      before do
        # When wait is enabled, processed_only is false
        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{organization_id}/builds",
          params: {
            app_id: app['id'],
            processed_only: false,
            version: build_info[:version],
            build_number: build_info[:build_number]
          }
        ).and_return({ data: { 'data' => { 'builds' => [build_ready] } } })

        allow(client).to receive(:get).with(
          "/api/v1/organizations/#{organization_id}/app_store_versions",
          params: { app_id: app['id'], editable: true }
        ).and_return({ data: { 'data' => { 'versions' => [] } } })
      end

      it 'skips submission step' do
        expect(client).not_to receive(:post).with(
          "/api/v1/organizations/#{organization_id}/app_store_versions/#{version['id']}/submit",
          anything
        )

        automation.perform!(metadata: metadata, build_info: build_info, metadata_overrides: {})
      end
    end
  end
end
