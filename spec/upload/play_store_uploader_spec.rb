# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'google/apis/androidpublisher_v3'
require 'mysigner/upload/play_store_uploader'

RSpec.describe Mysigner::Upload::PlayStoreUploader do
  let(:aab_path) { '/tmp/fixtures/app-release.aab' }
  let(:package_name) { 'com.example.app' }
  let(:access_token) { 'ya29.FAKE_TOKEN_FOR_TESTS' }
  let(:service) do
    instance_double(
      Google::Apis::AndroidpublisherV3::AndroidPublisherService,
      :authorization= => nil,
      :client_options => instance_double('ClientOptions', :open_timeout_sec= => nil, :read_timeout_sec= => nil),
      :request_options => instance_double('RequestOptions', :retries= => nil)
    )
  end

  before do
    # The resolver's project-sniff tier calls File.exist? on candidate
    # config files (eas.json / service-account.json / parents). The pinned
    # AAB stub mustn't make those calls explode — let the real method run
    # for any path other than the AAB.
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(aab_path).and_return(true)
    allow(File).to receive(:size).with(aab_path).and_return(50_000_000)
    allow(Google::Apis::AndroidpublisherV3::AndroidPublisherService).to receive(:new).and_return(service)
  end

  describe '#initialize' do
    it 'assigns the bare access_token string to service.authorization' do
      expect(service).to receive(:authorization=).with(access_token)

      described_class.new(
        aab_path: aab_path,
        access_token: access_token,
        package_name: package_name
      )
    end

    it 'raises CredentialsError when access_token is nil' do
      expect do
        described_class.new(
          aab_path: aab_path,
          access_token: nil,
          package_name: package_name
        )
      end.to raise_error(Mysigner::Upload::PlayStoreUploader::CredentialsError, /access_token is required/i)
    end

    it 'raises CredentialsError when access_token is an empty string' do
      expect do
        described_class.new(
          aab_path: aab_path,
          access_token: '',
          package_name: package_name
        )
      end.to raise_error(Mysigner::Upload::PlayStoreUploader::CredentialsError, /access_token is required/i)
    end

    it 'does not accept legacy service_account_json keyword' do
      expect do
        described_class.new(
          aab_path: aab_path,
          service_account_json: '{"type":"service_account"}',
          package_name: package_name
        )
      end.to raise_error(ArgumentError)
    end
  end

  # mysigner-43 — local-only path. The contract these specs enforce is the
  # whole point of the local-only mode: when `local_only: true`, the uploader
  # MUST mint its OAuth2 token from Keychain-backed SA-JSON and MUST NOT
  # contact the MySigner server for credential transport. Each spec below
  # would silently break a different leg of that contract if regressed.
  describe 'local-only mode' do
    let(:sa_email) { 'svc@my-project.iam.gserviceaccount.com' }
    let(:sa_json) do
      JSON.generate(
        'type' => 'service_account',
        'client_email' => sa_email,
        'private_key' => "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n",
        'project_id' => 'my-project'
      )
    end
    let(:minted_token) { 'ya29.LOCALLY_MINTED_TOKEN' }

    before do
      require 'mysigner/local_credentials'
      require 'mysigner/auth/google_oauth_minter'

      allow(Mysigner::LocalCredentials).to receive(:list)
        .with(kind: :google_play).and_return([sa_email])
      allow(Mysigner::LocalCredentials).to receive(:fetch)
        .with(kind: :google_play, id: sa_email).and_return(sa_json)

      # Stub the minter so we don't drive Google's auth library in unit tests.
      # The minter is exercised end-to-end by its own spec.
      minter = instance_double(Mysigner::Auth::GoogleOauthMinter, mint: minted_token)
      allow(Mysigner::Auth::GoogleOauthMinter).to receive(:new).with(sa_json).and_return(minter)
    end

    it 'mints the access_token locally and sets it as the bearer authorization' do
      # The contract is: when local_only:true the uploader fetches the
      # SA-JSON from LocalCredentials, mints via GoogleOauthMinter with the
      # Play Publishing scope, and uses that token as the bearer.
      expect(service).to receive(:authorization=).with(minted_token)

      described_class.new(
        aab_path: aab_path,
        package_name: package_name,
        local_only: true
      )

      expect(Mysigner::Auth::GoogleOauthMinter).to have_received(:new).with(sa_json)
    end

    it 'does NOT require an access_token kwarg when local_only is true' do
      # Without local_only, omitting access_token raises CredentialsError.
      # With local_only, it MUST be allowed — otherwise the user would have
      # to pass an empty string just to satisfy the kwarg.
      expect do
        described_class.new(
          aab_path: aab_path,
          package_name: package_name,
          local_only: true
        )
      end.not_to raise_error
    end

    it 'does NOT hit the MySigner server during construction (no credential POST)' do
      # WebMock would have failed the run if the uploader hit any HTTP
      # endpoint — but make the contract explicit so a regression that
      # ADDS a server stub doesn't accidentally silence the assertion.
      described_class.new(
        aab_path: aab_path,
        package_name: package_name,
        local_only: true
      )

      expect(WebMock).not_to have_requested(:any, /mysigner/)
    end

    it 'fails loud (without falling back to server) when no local credentials are stored' do
      allow(Mysigner::LocalCredentials).to receive(:list)
        .with(kind: :google_play).and_return([])

      expect do
        described_class.new(
          aab_path: aab_path,
          package_name: package_name,
          local_only: true
        )
      end.to raise_error(
        described_class::MissingLocalCredentialsError,
        /No local Google Play credentials found.*onboard --local-only/m
      )

      # Critical: we did not silently fall back to the server.
      expect(WebMock).not_to have_requested(:any, /mysigner/)
    end

    it 'fails loud when the index lists an id but the secret is missing (corrupted store)' do
      allow(Mysigner::LocalCredentials).to receive(:fetch)
        .with(kind: :google_play, id: sa_email).and_return(nil)

      expect do
        described_class.new(
          aab_path: aab_path,
          package_name: package_name,
          local_only: true
        )
      end.to raise_error(
        described_class::MissingLocalCredentialsError,
        /secret is missing.*Re-store/m
      )
    end
  end

  # mysigner-22 follow-up — fetch_highest_version_code is the local-only
  # equivalent of the MySigner server's highest_version_code lookup. The
  # whole point is to warn the user BEFORE the build runs that their
  # versionCode will be rejected, rather than after a 3-minute upload.
  describe '.fetch_highest_version_code' do
    let(:lookup_service) do
      instance_double(
        Google::Apis::AndroidpublisherV3::AndroidPublisherService,
        :authorization= => nil
      )
    end
    let(:edit) { Google::Apis::AndroidpublisherV3::AppEdit.new(id: 'EDIT_ID') }

    before do
      allow(Google::Apis::AndroidpublisherV3::AndroidPublisherService).to receive(:new).and_return(lookup_service)
      allow(lookup_service).to receive(:insert_edit).and_return(edit)
      # The edit is best-effort cleanup; always allow it but don't require
      # exact arguments in every spec (specs that care assert it directly).
      allow(lookup_service).to receive(:delete_edit)
    end

    it 'returns the max versionCode across all bundles on the app' do
      # Three bundles: 10, 15, 12 — should pick 15. WHY enumerate: a
      # `.first.version_code` regression would silently return 10 and let
      # the user upload a duplicate, which is the exact bug this guards.
      bundles_response = Google::Apis::AndroidpublisherV3::BundlesListResponse.new(
        bundles: [
          Google::Apis::AndroidpublisherV3::Bundle.new(version_code: 10),
          Google::Apis::AndroidpublisherV3::Bundle.new(version_code: 15),
          Google::Apis::AndroidpublisherV3::Bundle.new(version_code: 12)
        ]
      )
      expect(lookup_service).to receive(:list_edit_bundles)
        .with('com.example.app', 'EDIT_ID').and_return(bundles_response)

      result = described_class.fetch_highest_version_code(
        package_name: 'com.example.app',
        access_token: 'tok'
      )

      expect(result).to eq(15)
    end

    it 'returns nil when the app has no bundles yet (first-ever upload)' do
      # WHY: the contract has to distinguish "I checked, nothing yet" from
      # "I couldn't check" so the caller knows whether to suppress the
      # warning. nil for "nothing yet" lines up with the empty-array case.
      bundles_response = Google::Apis::AndroidpublisherV3::BundlesListResponse.new(bundles: [])
      allow(lookup_service).to receive(:list_edit_bundles).and_return(bundles_response)

      expect(
        described_class.fetch_highest_version_code(package_name: 'com.example.app', access_token: 'tok')
      ).to be_nil
    end

    it 'discards the edit even on the happy path so we never accumulate stale edits' do
      bundles_response = Google::Apis::AndroidpublisherV3::BundlesListResponse.new(
        bundles: [Google::Apis::AndroidpublisherV3::Bundle.new(version_code: 7)]
      )
      allow(lookup_service).to receive(:list_edit_bundles).and_return(bundles_response)
      expect(lookup_service).to receive(:delete_edit).with('com.example.app', 'EDIT_ID')

      described_class.fetch_highest_version_code(package_name: 'com.example.app', access_token: 'tok')
    end

    it 'returns nil on Google::Apis::ClientError so the pre-check is best-effort and never fatal' do
      # WHY: this pre-check is a UX improvement, not a correctness gate.
      # Google will still reject at upload time with a clear message. Don't
      # fail the ship just because the lookup itself had a transient issue.
      allow(lookup_service).to receive(:list_edit_bundles)
        .and_raise(Google::Apis::ClientError.new('not found', status_code: 404))

      expect(
        described_class.fetch_highest_version_code(package_name: 'com.example.app', access_token: 'tok')
      ).to be_nil
    end
  end
end
