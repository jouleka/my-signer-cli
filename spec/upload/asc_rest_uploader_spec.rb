# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'digest'
require 'json'
require 'tempfile'
require 'tmpdir'
require 'fileutils'
require 'mysigner/upload/asc_rest_uploader'

RSpec.describe Mysigner::Upload::AscRestUploader do
  let(:client) do
    instance_double('Mysigner::Client').tap do |c|
      allow(c).to receive(:post).and_return({ data: {
                                              'build_upload_id' => 1,
                                              'upload_operations' => [
                                                { 'method' => 'PUT', 'url' => 'https://s3.example/chunk1',
                                                  'offset' => 0, 'length' => 5, 'requestHeaders' => [] }
                                              ]
                                            } })
      allow(c).to receive(:patch).and_return({ data: { 'state' => 'uploaded', 'apple_state' => 'PROCESSING' } })
      allow(c).to receive(:get).and_return({ data: { 'apple_state' => 'COMPLETE' } })
    end
  end

  let(:ipa) do
    Tempfile.new(['test', '.ipa']).tap do |f|
      f.write('hello')
      f.close
    end
  end

  describe '#compute_file_digests (private)' do
    it 'computes MD5 + SHA-256 in one pass, matching Digest::*.file' do
      file = Tempfile.new(['digest', '.bin'])
      file.binmode
      file.write('a' * ((3 * 1024 * 1024) + 7)) # spans multiple read chunks
      file.close

      uploader = described_class.new(
        client: instance_double('Mysigner::Client'), organization_id: 1, ipa_path: file.path,
        apple_app_id: 1, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0'
      )

      md5, sha = uploader.send(:compute_file_digests, file.path)

      expect(md5).to eq(Digest::MD5.file(file.path).hexdigest)
      expect(sha).to eq(Digest::SHA256.file(file.path).hexdigest)
    ensure
      file.unlink
    end
  end

  it 'drives the full vault-mode upload flow and reports COMPLETE' do
    stub_request(:put, 'https://s3.example/chunk1').to_return(status: 200)
    uploader = described_class.new(
      client: client, organization_id: 1, ipa_path: ipa.path,
      apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
      platform: 'IOS'
    )
    result = uploader.call
    expect(result[:final_state]).to eq('COMPLETE')
    expect(a_request(:put, 'https://s3.example/chunk1').with(body: 'hello')).to have_been_made.once
  end

  # mysigner-46 — local-only path delegates to `xcrun altool --upload-app`.
  # altool is Apple's canonical CLI for App Store uploads; trying to
  # reimplement Apple's multi-step REST flow via Faraday (the previous
  # mysigner-42 attempt) shipped a broken payload that Apple rejected with
  # ENTITY_ERROR.ATTRIBUTE.UNKNOWN on `fileName` / `fileSize`. These specs
  # pin the altool contract: argv shape, .p8 placement, and error mapping.
  describe 'local-only mode' do
    let(:local_client) do
      # In local-only mode the client should not be touched for credential
      # transport. We still pass an instance_double so that any accidental
      # call surfaces loudly (instance_double raises on undefined methods).
      instance_double('Mysigner::Client')
    end

    let(:p8_pem) { "-----BEGIN PRIVATE KEY-----\nFAKE_PEM_BYTES\n-----END PRIVATE KEY-----\n" }

    before do
      require 'mysigner/local_credentials'

      # Stub the keychain leg of the cascade so resolve_asc returns a
      # deterministic AscCreds without touching the real Keychain.
      allow(Mysigner::LocalCredentials).to receive(:list)
        .with(kind: :asc).and_return(['KEY123'])
      allow(Mysigner::LocalCredentials).to receive(:fetch)
        .with(kind: :asc, id: 'KEY123')
        .and_return(JSON.generate('issuer_id' => 'ISSUER-UUID', 'p8_pem' => p8_pem))

      # Don't touch the user's real ~/.appstoreconnect/private_keys when
      # the tests run. WHY use partial doubles with `.with(canonical_p8)`
      # rather than blanket stubs: other code paths (e.g. resolve_asc
      # scanning) call File.exist? on unrelated paths, and we don't want
      # to override their answers — only the canonical altool path.
      @canonical_p8 = File.expand_path('~/.appstoreconnect/private_keys/AuthKey_KEY123.p8')
      @canonical_dir = File.expand_path('~/.appstoreconnect/private_keys')
      allow(FileUtils).to receive(:mkdir_p).with(@canonical_dir, anything)
      allow(File).to receive(:write).with(@canonical_p8, anything)
      allow(File).to receive(:chmod).with(0o600, @canonical_p8)
      # exist? returns false by default → uploader takes the write branch.
      # The "skips the write when …" spec overrides this to true.
      allow(File).to receive(:exist?).with(@canonical_p8).and_return(false)
      # The uploader now deletes the .p8 it materialized after altool runs;
      # keep that off the real FS during tests.
      allow(FileUtils).to receive(:rm_f).with(@canonical_p8)
    end

    it 'deletes the .p8 it materialized once altool finishes (no plaintext key left on disk)' do
      # The fresh-write branch (exist? == false) means WE created the key,
      # so it must be removed afterwards rather than left lying around at
      # Apple's well-known discovery path.
      expect(FileUtils).to receive(:rm_f).with(@canonical_p8)

      allow(Open3).to receive(:capture2e)
        .and_return(['', instance_double('Process::Status', success?: true)])

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      uploader.call
    end

    it 'still deletes the materialized .p8 when altool fails (ensure cleanup)' do
      expect(FileUtils).to receive(:rm_f).with(@canonical_p8)

      allow(Open3).to receive(:capture2e)
        .and_return(['{"product-errors":[{"message":"boom"}]}',
                     instance_double('Process::Status', success?: false)])

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      expect { uploader.call }.to raise_error(described_class::AltoolUploadError)
    end

    it 'still deletes the freshly-written .p8 when chmod fails after the write (no leak on partial write)' do
      # The key bytes hit disk at File.write; if the subsequent chmod raises,
      # the ensure cleanup must STILL remove the plaintext key.
      allow(File).to receive(:chmod).with(0o600, @canonical_p8).and_raise(Errno::EPERM)
      expect(FileUtils).to receive(:rm_f).with(@canonical_p8)

      allow(Open3).to receive(:capture2e)
        .and_return(['', instance_double('Process::Status', success?: true)])

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      expect { uploader.call }.to raise_error(Errno::EPERM)
    end

    it 'does NOT delete a pre-existing user .p8 it did not create' do
      # A key the user placed at the canonical path themselves (same PEM)
      # must be left intact — we only clean up what we wrote this run.
      allow(File).to receive(:exist?).with(@canonical_p8).and_return(true)
      allow(File).to receive(:read).with(@canonical_p8).and_return(p8_pem)

      expect(FileUtils).not_to receive(:rm_f).with(@canonical_p8)

      allow(Open3).to receive(:capture2e)
        .and_return(['', instance_double('Process::Status', success?: true)])

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      uploader.call
    end

    it 'shells out to xcrun altool --upload-app with the resolved credentials' do
      # altool exits 0 on success. We capture the argv to verify the
      # invocation shape — Apple's altool only accepts this exact form, so
      # any drift here breaks production uploads silently.
      captured_argv = nil
      expect(Open3).to receive(:capture2e) do |*argv|
        captured_argv = argv
        ['{"tool-version":"x"}', instance_double('Process::Status', success?: true)]
      end

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      result = uploader.call

      # Contract: altool succeeded → upload is COMPLETE. altool already
      # polls Apple's transporter to completion, so we don't poll again.
      expect(result[:final_state]).to eq('COMPLETE')
      # altool doesn't surface a buildUploads id; nil is fine because
      # callers only use the id in vault mode (which doesn't run altool).
      expect(result[:build_upload_id]).to be_nil

      # argv contract — Apple's altool only accepts this exact form.
      expect(captured_argv).to start_with('xcrun', 'altool', '--upload-app')
      expect(captured_argv).to include('--file', ipa.path)
      expect(captured_argv).to include('--type', 'ios')
      expect(captured_argv).to include('--apiKey', 'KEY123')
      expect(captured_argv).to include('--apiIssuer', 'ISSUER-UUID')
      expect(captured_argv).to include('--output-format', 'json')

      # Never went to the MySigner server (local-only contract) and never
      # spoke raw REST to Apple (altool owns that conversation now).
      expect(WebMock).not_to have_requested(:any, /mysigner/)
      expect(WebMock).not_to have_requested(:any, /appstoreconnect/)
    end

    it 'writes the .p8 to the canonical Apple location before invoking altool' do
      # altool's --apiKey KEY_ID flag has no path override — it ONLY looks
      # in ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8. If we
      # don't place the key there altool fails with an opaque "couldn't
      # find key" error. AscCreds carries the PEM bytes (not the source
      # path), so we write rather than symlink.
      expected_path = File.expand_path('~/.appstoreconnect/private_keys/AuthKey_KEY123.p8')

      expect(FileUtils).to receive(:mkdir_p)
        .with(File.expand_path('~/.appstoreconnect/private_keys'), mode: 0o700)
      expect(File).to receive(:write).with(expected_path, p8_pem)
      expect(File).to receive(:chmod).with(0o600, expected_path)

      allow(Open3).to receive(:capture2e)
        .and_return(['', instance_double('Process::Status', success?: true)])

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      uploader.call
    end

    it 'skips the write when the canonical .p8 already contains the same PEM' do
      # Idempotent: re-running the same ship twice in a row should not
      # re-write the secret file. Avoids unnecessary FS churn and means a
      # user-managed key file (placed there manually) is left alone when
      # it already matches.
      expected_path = File.expand_path('~/.appstoreconnect/private_keys/AuthKey_KEY123.p8')

      allow(File).to receive(:exist?).with(expected_path).and_return(true)
      allow(File).to receive(:read).with(expected_path).and_return(p8_pem)

      expect(File).not_to receive(:write).with(expected_path, anything)
      # We still chmod 0600 because a previous run might have left it
      # world-readable; this is cheap insurance.
      expect(File).to receive(:chmod).with(0o600, expected_path)

      allow(Open3).to receive(:capture2e)
        .and_return(['', instance_double('Process::Status', success?: true)])

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      uploader.call
    end

    it 'maps altool ITMS-90 "build version already exists" to BuildVersionConflictError' do
      # Intent: the user-facing error for a duplicate CFBundleVersion is the
      # same regardless of whether we went through the server or altool. A
      # regression here would surface as an opaque AltoolUploadError for
      # local-only users and they'd lose the "bump CFBundleVersion" hint.
      itms_msg = 'ERROR ITMS-90062: "This bundle is invalid. The new build version 1 must be ' \
                 'greater than the previous build version. The build version already exists."'
      altool_err = {
        'tool-version' => '4.0.0',
        'product-errors' => [
          { 'code' => 90_062, 'message' => itms_msg }
        ]
      }.to_json
      allow(Open3).to receive(:capture2e)
        .and_return([altool_err, instance_double('Process::Status', success?: false)])

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      expect { uploader.call }.to raise_error(
        described_class::BuildVersionConflictError,
        /CFBundleVersion must be unique/
      )
    end

    it 'maps any other altool failure to AltoolUploadError carrying the real error' do
      # WHY: the previous implementation blanket-mapped every 409 to
      # BuildVersionConflictError, silently hiding signature rejections,
      # expired tokens, and attribute-shape mismatches. AltoolUploadError
      # must carry altool's verbatim code + message so the user can act.
      altool_err = {
        'tool-version' => '4.0.0',
        'product-errors' => [
          { 'code' => -22_421, 'message' => 'Unable to authenticate with App Store Connect.' }
        ]
      }.to_json
      allow(Open3).to receive(:capture2e)
        .and_return([altool_err, instance_double('Process::Status', success?: false)])

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      expect { uploader.call }.to raise_error(
        described_class::AltoolUploadError,
        /-22421.*Unable to authenticate/
      )
    end

    it 'surfaces non-JSON altool output verbatim instead of swallowing it' do
      # Defensive: altool occasionally prints raw shell errors (e.g. when
      # xcrun itself isn't installed) before any JSON. Don't pretend the
      # upload worked just because we couldn't parse the output.
      allow(Open3).to receive(:capture2e)
        .and_return(['xcrun: error: unable to find utility "altool"', instance_double('Process::Status', success?: false)])

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      expect { uploader.call }.to raise_error(
        described_class::AltoolUploadError,
        /unable to find utility "altool"/
      )
    end

    it 'fails loud (without falling back to server) when no local credentials are stored' do
      # Override the LocalCredentials stubs to simulate an empty store.
      allow(Mysigner::LocalCredentials).to receive(:list)
        .with(kind: :asc).and_return([])
      # Also pin the disk-scan tier to an empty dir — otherwise a developer
      # who has a real AuthKey_*.p8 in ~/.appstoreconnect/private_keys/ (from
      # an actual local-only ship) makes the resolver succeed via the disk
      # tier instead of raising MissingLocalCredentialsError. The spec's
      # whole point is "what happens when nothing is discoverable anywhere".
      stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR',
                 File.join(Dir.tmpdir, 'mysigner-test-empty-asc-dir'))

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      expect { uploader.call }.to raise_error(
        described_class::MissingLocalCredentialsError,
        /No local ASC credentials found.*onboard --local-only/m
      )
      # Critical: we did not silently fall back to the server.
      expect(WebMock).not_to have_requested(:any, /mysigner/)
      expect(WebMock).not_to have_requested(:any, /appstoreconnect/)
    end

    it 'fails loud when the index lists an id but the secret is missing (corrupted store)' do
      allow(Mysigner::LocalCredentials).to receive(:fetch)
        .with(kind: :asc, id: 'KEY123').and_return(nil)

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      expect { uploader.call }.to raise_error(
        described_class::MissingLocalCredentialsError,
        /secret is missing.*Re-store/m
      )
    end

    it 'fails loud when the stored envelope is not valid JSON (malformed store)' do
      # WHY: a legacy plain-PEM write, a truncated `security` output, or a
      # text-encoding accident leaves a non-JSON secret in the Keychain. The
      # contract is "always JSON {issuer_id, p8_pem}"; if we let bare
      # JSON::ParserError bubble up, the user sees a Ruby trace instead of
      # the onboarding hint and the CLI rescue can't catch it cleanly.
      allow(Mysigner::LocalCredentials).to receive(:fetch)
        .with(kind: :asc, id: 'KEY123').and_return("-----BEGIN EC PRIVATE KEY-----\nlegacy plain pem\n-----END EC PRIVATE KEY-----")

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      expect { uploader.call }.to raise_error(
        described_class::MissingLocalCredentialsError,
        /not valid JSON.*Re-store/m
      )
    end

    it 'fails loud when the stored envelope is JSON but missing required fields' do
      # WHY: storing {p8_pem: "..."} without issuer_id (or vice versa) used to
      # raise KeyError mid-mint, with the same opaque-stack-trace failure
      # mode as the malformed-JSON case. Same defensive rescue.
      allow(Mysigner::LocalCredentials).to receive(:fetch)
        .with(kind: :asc, id: 'KEY123').and_return('{"p8_pem": "data only"}')

      uploader = described_class.new(
        client: local_client, organization_id: 1, ipa_path: ipa.path,
        apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
        platform: 'IOS', local_only: true
      )

      expect { uploader.call }.to raise_error(
        described_class::MissingLocalCredentialsError,
        /missing required field.*Re-store/m
      )
    end
  end
end
