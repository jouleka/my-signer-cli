# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'mysigner/build/android_parser'
require 'mysigner/build/android_executor'
require 'mysigner/signing/keystore_manager'
require 'mysigner/upload/play_store_uploader'

RSpec.describe 'mysigner ship android', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }

  # Helper to capture stdout
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
    allow(cli).to receive(:exit) # Stub exit
  end

  describe 'PartialUploadError handling' do
    let(:project_info) do
      {
        path: '/path/to/android',
        type: :gradle,
        framework: :react_native,
        build_gradle: '/path/to/android/app/build.gradle'
      }
    end
    let(:parser) { instance_double(Mysigner::Build::AndroidParser) }
    let(:executor) { instance_double(Mysigner::Build::AndroidExecutor) }
    let(:keystore_manager) { instance_double(Mysigner::Signing::KeystoreManager) }
    let(:uploader) { instance_double(Mysigner::Upload::PlayStoreUploader) }
    let(:aab_path) { '/path/to/app-release.aab' }

    let(:org_response) do
      {
        data: {
          'google_play_configured' => true,
          'google_play_service_account' => '{"type":"service_account"}'
        }
      }
    end

    let(:apps_response) do
      {
        data: {
          'android_apps' => [
            { 'id' => 1, 'package_name' => 'com.example.app', 'highest_version_code' => 5 }
          ]
        }
      }
    end

    # mysigner-49: the server list/active payload no longer carries the
    # plaintext passwords. The CLI fetches them through #fetch_secrets, so
    # this fixture mirrors the real (secret-free) shape and the matching
    # stub returns the secrets separately.
    let(:keystore_data) do
      {
        'id' => 1,
        'name' => 'test-keystore',
        'key_alias' => 'key0'
      }
    end
    let(:keystore_secrets) do
      {
        'keystore_password' => 'password123',
        'key_password' => 'password123',
        'key_alias' => 'key0'
      }
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return(nil)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')

      cli.options = { platform: 'android', verbose: false }

      # Mock project detection
      allow(Mysigner::Build::Detector).to receive(:detect_android).and_return(project_info)

      # Mock parser
      allow(Mysigner::Build::AndroidParser).to receive(:new).and_return(parser)
      allow(parser).to receive(:application_id).and_return('com.example.app')
      allow(parser).to receive(:version_code).and_return(6)
      allow(parser).to receive(:version_name).and_return('1.0.0')

      # Mock keystore manager. fetch_secrets is the dedicated /secrets
      # endpoint call introduced by mysigner-49.
      allow(Mysigner::Signing::KeystoreManager).to receive(:new).and_return(keystore_manager)
      allow(keystore_manager).to receive(:active_keystore).and_return(keystore_data)
      allow(keystore_manager).to receive(:fetch_secrets).with(keystore_data['id']).and_return(keystore_secrets)
      allow(keystore_manager).to receive(:get_or_download).and_return({ path: '/tmp/keystore.jks' })

      # Mock executor
      allow(Mysigner::Build::AndroidExecutor).to receive(:new).and_return(executor)
      allow(executor).to receive(:build_aab!).and_return(aab_path)

      # Mock file operations
      allow(File).to receive(:exist?).with(aab_path).and_return(true)
      allow(File).to receive(:size).with(aab_path).and_return(50_000_000)
      allow(Dir).to receive(:pwd).and_return('/path/to/project')

      # Mock API calls
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}").and_return(org_response)
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/android_apps").and_return(apps_response)
      allow(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/android_releases",
        hash_including(:params)
      ).and_return({ data: { 'data' => [] } })
      allow(client).to receive(:post) # Generic post stub
      allow(client).to receive(:post).with(
        "/api/v1/organizations/#{org_id}/credentials/google_play/access_token"
      ).and_return({ data: { 'access_token' => 'ya29.fake_token' } })
    end

    context 'when upload succeeds completely' do
      before do
        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_return({
                                                          success: true,
                                                          version_code: 6,
                                                          track: 'internal',
                                                          package_name: 'com.example.app'
                                                        })
      end

      it 'saves build record to backend' do
        # The client.post is called for both keystore link and build record
        # We verify the build record post happens by checking the output
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('SUCCESS!')
      end

      it 'shows success message' do
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('SUCCESS!')
      end
    end

    context 'when track assignment fails (PartialUploadError)' do
      before do
        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_raise(
          Mysigner::Upload::PlayStoreUploader::PartialUploadError.new(
            'Google Play API error: Precondition check failed',
            version_code: 8
          )
        )
      end

      it 'still saves build record to prevent version conflicts' do
        # Verify the "Build recorded" message appears, which means save was attempted
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('Build v8 recorded')
      end

      it 'shows error message' do
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('Partial Upload - Track Assignment Failed')
        expect(output).to include('Precondition check failed')
      end

      it 'shows build recorded message' do
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('Build v8 recorded')
        expect(output).to include('prevents version conflicts')
      end

      it 'exits with code 1' do
        expect(cli).to receive(:exit).with(1)
        cli.ship('internal')
      end
    end

    context 'when upload fails completely (UploadError)' do
      before do
        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_raise(
          Mysigner::Upload::PlayStoreUploader::UploadError.new('Bundle upload failed')
        )
      end

      it 'does not save build record' do
        # When UploadError (not PartialUploadError), no build record message should appear
        output = capture_stdout { cli.ship('internal') }
        expect(output).not_to include('Build v')
        expect(output).not_to include('recorded')
      end

      it 'shows error message' do
        output = capture_stdout { cli.ship('internal') }
        expect(output).to include('Upload Failed')
        expect(output).to include('Bundle upload failed')
      end
    end
  end

  # mysigner-43 — local-only path. The contract these specs enforce mirrors
  # mysigner-42's ASC equivalent: when --local-only is in effect, the CLI
  # MUST NOT call the server's Google Play credential endpoint, MUST pass
  # local_only: true into the uploader, and MUST exit non-zero with a clean
  # message when credentials aren't stored locally.
  describe 'local-only mode' do
    let(:project_info) do
      {
        path: '/path/to/android',
        type: :gradle,
        framework: :react_native,
        build_gradle: '/path/to/android/app/build.gradle'
      }
    end
    let(:parser) { instance_double(Mysigner::Build::AndroidParser) }
    let(:executor) { instance_double(Mysigner::Build::AndroidExecutor) }
    let(:keystore_manager) { instance_double(Mysigner::Signing::KeystoreManager) }
    let(:uploader) { instance_double(Mysigner::Upload::PlayStoreUploader) }
    let(:aab_path) { '/path/to/app-release.aab' }
    let(:apps_response) do
      {
        data: {
          'android_apps' => [
            { 'id' => 1, 'package_name' => 'com.example.app', 'highest_version_code' => 5 }
          ]
        }
      }
    end
    let(:keystore_data) do
      {
        'id' => 1,
        'name' => 'test-keystore',
        'key_alias' => 'key0',
        'keystore_password' => 'password123',
        'key_password' => 'password123'
      }
    end
    let(:gp_token_url) do
      "/api/v1/organizations/#{org_id}/credentials/google_play/access_token"
    end

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')

      # mysigner-22 Phase 7 — in local-only mode the keystore is now also
      # resolved via the cascade (not the server). We pass the four pieces
      # via flags so the cascade resolves at tier 1 without touching disk
      # or keychain. Existing assertions on Play-cred handling remain.
      cli.options = {
        platform: 'android',
        verbose: false,
        local_only: true,
        keystore_path: '/tmp/keystore.jks',
        keystore_password: 'kspw',
        key_alias: 'key0',
        key_password: 'kspw'
      }
      allow(cli).to receive(:emit_local_only_banner) # suppress in tests

      allow(Mysigner::Build::Detector).to receive(:detect_android).and_return(project_info)
      allow(Mysigner::Build::AndroidParser).to receive(:new).and_return(parser)
      allow(parser).to receive(:application_id).and_return('com.example.app')
      allow(parser).to receive(:version_code).and_return(6)
      allow(parser).to receive(:version_name).and_return('1.0.0')

      # KeystoreManager is unused in local-only mode (Phase 7) — keep the
      # stub for symmetry but assert nothing on it; the resolver path
      # supersedes it.
      allow(Mysigner::Signing::KeystoreManager).to receive(:new).and_return(keystore_manager)
      allow(keystore_manager).to receive(:active_keystore).and_return(keystore_data)
      allow(keystore_manager).to receive(:get_or_download).and_return({ path: '/tmp/keystore.jks' })

      allow(Mysigner::Build::AndroidExecutor).to receive(:new).and_return(executor)
      allow(executor).to receive(:build_aab!).and_return(aab_path)

      # mysigner-22 Phase 5: the credential resolver calls File.exist? on
      # candidate config files during the cascade (Keychain index files, the
      # eas.json sniff). Don't trip the strict aab-only stub on those.
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(aab_path).and_return(true)
      # Pretend the keystore path the flag points at exists, so the cascade's
      # tier-1 flag layer accepts it without disk I/O.
      allow(File).to receive(:exist?).with('/tmp/keystore.jks').and_return(true)
      allow(File).to receive(:size).with(aab_path).and_return(50_000_000)
      allow(Dir).to receive(:pwd).and_return('/path/to/project')
      # Force the cascade to fail in the "no creds anywhere" case by emptying
      # the Keychain list — without this, a developer running these specs on
      # a machine with `mysigner onboard --local-only` already done could
      # have the resolver succeed and bypass the missing-creds branch.
      allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :google_play).and_return([])
      allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :android_keystore).and_return([])

      # Non-credential endpoints remain stubbed for vault-mode equivalence,
      # but mysigner-22 Phase 7 routes ALL Android server traffic away from
      # the wire in local-only mode (keystore download, build records,
      # release defaults, link_to_app, highest version code). Specs below
      # assert that.
      allow(client).to receive(:get).with("/api/v1/organizations/#{org_id}/android_apps").and_return(apps_response)
      allow(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/android_releases",
        hash_including(:params)
      ).and_return({ data: { 'data' => [] } })
      allow(client).to receive(:post) # generic post for non-credential calls (build record, link)
      allow(client).to receive(:post).with(gp_token_url).and_raise(
        RuntimeError, 'server credential endpoint must NOT be called in local-only mode'
      )
    end

    context 'with stored Google Play credentials' do
      before do
        # Override the default empty-Keychain stub so the resolver finds the
        # SA-JSON and the CLI proceeds to PlayStoreUploader.new construction.
        sa_email = 'ci@my-project.iam.gserviceaccount.com'
        sa_json = JSON.generate(
          'type' => 'service_account',
          'client_email' => sa_email,
          'private_key' => SpecCredentialFixtures.pem,
          'project_id' => 'p'
        )
        allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :google_play).and_return([sa_email])
        allow(Mysigner::LocalCredentials).to receive(:fetch).with(kind: :google_play, id: sa_email).and_return(sa_json)

        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_return({
                                                          success: true,
                                                          version_code: 6,
                                                          track: 'internal',
                                                          package_name: 'com.example.app'
                                                        })
      end

      it 'constructs PlayStoreUploader with local_only:true and access_token:nil' do
        expect(Mysigner::Upload::PlayStoreUploader).to receive(:new).with(
          hash_including(local_only: true, access_token: nil)
        ).and_return(uploader)

        capture_stdout { cli.ship('internal') }
      end

      it 'does NOT POST to the server credential endpoint' do
        # The before-block stubs the credential POST to raise; if the CLI
        # called it, the test would crash. Reinforce the assertion so a
        # regression that ADDS a stub doesn't silence it.
        capture_stdout { cli.ship('internal') }
        expect(client).not_to have_received(:post).with(gp_token_url)
      end

      it 'emits the local-only banner' do
        expect(cli).to receive(:emit_local_only_banner)
        capture_stdout { cli.ship('internal') }
      end
    end

    context 'when local credentials are missing' do
      before do
        # The uploader is constructed (which is what triggers the lookup)
        # and immediately raises before upload! is reached. We let the real
        # error propagate from the uploader rather than stubbing — that
        # catches a regression where the rescue is removed from the CLI.
        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_raise(
          Mysigner::Upload::PlayStoreUploader::MissingLocalCredentialsError.new(
            'No local Google Play credentials found. Store them with `mysigner onboard --local-only`.'
          )
        )
      end

      it 'shows a clean error message (no stack trace) and exits 1' do
        # Make exit actually stop execution so we can capture exactly the
        # final state — matches the testflight not-logged-in idiom.
        allow(cli).to receive(:exit) { throw :system_exit }
        expect(cli).to receive(:exit).with(1) { throw :system_exit }

        output = capture_stdout do
          catch(:system_exit) { cli.ship('internal') }
        end
        expect(output).to include('No local Google Play credentials found')
        expect(output).to include('mysigner onboard --local-only')
      end

      it 'does NOT silently fall back to the server credential endpoint' do
        allow(cli).to receive(:exit) { throw :system_exit }
        catch(:system_exit) { cli.ship('internal') }
        expect(client).not_to have_received(:post).with(gp_token_url)
      end
    end

    # mysigner-22 Phase 7 — the binding contract for `ship play --local-only`:
    # NO MySigner server endpoint for keystore download, build records,
    # release defaults, link-to-app, or highest-version-code may be called.
    # A regression here re-introduces the original bug where the user's
    # keystore was fetched from the MySigner server even in local-only mode.
    context 'NO MySigner Android server endpoints are hit' do
      before do
        sa_email = 'ci@my-project.iam.gserviceaccount.com'
        sa_json = JSON.generate(
          'type' => 'service_account',
          'client_email' => sa_email,
          'private_key' => SpecCredentialFixtures.pem,
          'project_id' => 'p'
        )
        allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :google_play).and_return([sa_email])
        allow(Mysigner::LocalCredentials).to receive(:fetch)
          .with(kind: :google_play, id: sa_email).and_return(sa_json)

        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_return(success: true, version_code: 6, track: 'internal',
                                                        package_name: 'com.example.app')
      end

      it 'does NOT call the server keystore / build-record / release-defaults / link / version-code endpoints' do
        capture_stdout { cli.ship('internal') }

        expect(client).not_to have_received(:get).with(a_string_matching(%r{/android_keystores}), anything)
        expect(client).not_to have_received(:post).with(
          a_string_matching(%r{/android_keystores/\d+/(secrets|link_to_app|download)}), anything
        )
        expect(client).not_to have_received(:post).with(
          a_string_matching(%r{/android_apps/\d+/android_builds}), anything
        )
        expect(client).not_to have_received(:get).with(a_string_matching(%r{/android_releases}), anything)
        expect(client).not_to have_received(:get).with(a_string_matching(%r{/android_apps$}))
      end

      it 'does NOT instantiate KeystoreManager in local-only mode' do
        # KeystoreManager is the gateway to all server keystore traffic;
        # asserting it's never constructed catches the regression before
        # the endpoint mocks would.
        expect(Mysigner::Signing::KeystoreManager).not_to receive(:new)
        capture_stdout { cli.ship('internal') }
      end

      it 'pre-resolves the keystore via CredentialResolver.resolve_android_keystore' do
        # The CLI MUST funnel through the resolver — anything that talks
        # to LocalCredentials.fetch directly or KeystoreManager directly
        # would bypass the cascade contract.
        expect(Mysigner::CredentialResolver).to receive(:resolve_android_keystore)
          .with(hash_including(options: hash_including(local_only: true)))
          .and_call_original
        capture_stdout { cli.ship('internal') }
      end
    end

    # mysigner-22 follow-up — versionCode pre-check via Google Play.
    # In local-only mode the CLI mints an OAuth2 token from local SA-JSON
    # and asks Google "what's the highest versionCode already on the app?"
    # via PlayStoreUploader.fetch_highest_version_code. If the project's
    # versionCode is too low, fail fast with a clear "bump versionCode"
    # hint rather than burning 3 minutes on a doomed upload. The brief is
    # explicit that we DO NOT auto-bump the AAB — that's the user's
    # project state.
    context 'versionCode pre-check' do
      let(:sa_email) { 'ci@my-project.iam.gserviceaccount.com' }
      let(:sa_json) do
        JSON.generate(
          'type' => 'service_account',
          'client_email' => sa_email,
          'private_key' => SpecCredentialFixtures.pem,
          'project_id' => 'p'
        )
      end

      before do
        # Make the cascade succeed for Play creds so the pre-check actually
        # runs (otherwise the resolver path exits 1 before we get to the
        # check itself).
        allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :google_play).and_return([sa_email])
        allow(Mysigner::LocalCredentials).to receive(:fetch)
          .with(kind: :google_play, id: sa_email).and_return(sa_json)
      end

      it 'exits 1 with a "bump versionCode" hint when the project versionCode is ≤ Google\'s latest' do
        # Stub the lookup directly so we don't drive googleauth in the unit
        # path; PlayStoreUploader.fetch_highest_version_code is unit-tested
        # in its own spec.
        allow(Mysigner::Upload::PlayStoreUploader).to receive(:fetch_highest_version_code)
          .and_return(15)
        allow(parser).to receive(:version_code).and_return(10)
        # The minter itself is also stubbed so the helper doesn't fall into
        # its best-effort rescue. We're verifying the warn-and-exit branch,
        # not the minter integration.
        token_double = 'TOKEN'
        allow(Mysigner::Auth::GoogleOauthMinter).to receive(:new)
          .and_return(instance_double(Mysigner::Auth::GoogleOauthMinter, mint: token_double))

        allow(cli).to receive(:exit) { throw :system_exit }
        expect(cli).to receive(:exit).with(1) { throw :system_exit }

        output = capture_stdout { catch(:system_exit) { cli.ship('internal') } }

        expect(output).to match(/versionCode \(10\).*Google.*latest \(15\)/m)
        expect(output).to match(/Bump versionCode to 16 or higher/)
      end

      it 'does NOT auto-bump the AAB (warn-only is the explicit contract in local-only)' do
        allow(Mysigner::Upload::PlayStoreUploader).to receive(:fetch_highest_version_code)
          .and_return(15)
        allow(parser).to receive(:version_code).and_return(10)
        allow(Mysigner::Auth::GoogleOauthMinter).to receive(:new)
          .and_return(instance_double(Mysigner::Auth::GoogleOauthMinter, mint: 'TOKEN'))
        allow(cli).to receive(:exit) { throw :system_exit }

        catch(:system_exit) { cli.ship('internal') }

        # The build_aab! method takes a version_code_override kwarg — in
        # vault mode that's how Phase 7 implements the auto-bump. Local-only
        # must never reach the build (we exit first), so the executor is
        # never even called.
        expect(executor).not_to have_received(:build_aab!)
      end

      it 'is best-effort: a minter failure does NOT abort the ship' do
        # Pre-check is UX, not a correctness gate. A transient mint failure
        # (network, expired key, etc.) must not block the user — Google will
        # still reject at upload time with a clear message.
        allow(Mysigner::Auth::GoogleOauthMinter).to receive(:new)
          .and_raise(ArgumentError.new('service_account_json is missing required keys'))

        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_return(success: true, version_code: 6, track: 'internal',
                                                        package_name: 'com.example.app')

        expect { capture_stdout { cli.ship('internal') } }.not_to raise_error
      end
    end

    # mysigner-22 Phase 5 — --play-credentials flag passthrough. The
    # CredentialResolver is the ONLY place that interprets the flag, so the
    # assertion here is that the CLI passes options[:play_credentials] into
    # the resolver. That guarantee is what makes the per-command override
    # documented in the README actually work end-to-end.
    context 'when --play-credentials PATH flag is set, the resolver receives it' do
      it 'calls resolve_play with options containing the flag value' do
        sa_path = '/tmp/flag-sa.json'
        sa_email = 'flag@my-project.iam.gserviceaccount.com'
        sa_json = JSON.generate(
          'type' => 'service_account', 'client_email' => sa_email,
          'private_key' => SpecCredentialFixtures.pem,
          'project_id' => 'p'
        )
        # Pretend the flag-pointed file exists with valid SA JSON; the real
        # resolver will read it via the flag tier.
        allow(File).to receive(:exist?).with(sa_path).and_return(true)
        allow(File).to receive(:read).with(sa_path).and_return(sa_json)
        cli.options = cli.options.merge(play_credentials: sa_path)

        allow(Mysigner::Upload::PlayStoreUploader).to receive(:new).and_return(uploader)
        allow(uploader).to receive(:upload!).and_return(success: true, version_code: 6, track: 'internal',
                                                        package_name: 'com.example.app')

        # The resolver's :flag tier returns AscCreds when all three flags
        # match — for Play, just the path is needed. We assert the resolver
        # is called with our options. (Called twice in current code: once
        # for the versionCode pre-check, once for the upload itself; both
        # MUST carry the flag.)
        expect(Mysigner::CredentialResolver).to receive(:resolve_play)
          .with(hash_including(options: hash_including(play_credentials: sa_path)))
          .and_call_original.at_least(:once)

        capture_stdout { cli.ship('internal') }
      end
    end
  end

  describe 'generate_app_name_from_package helper' do
    # Access the private method for testing via the CLI instance
    it 'extracts meaningful name from package' do
      expect(cli.send(:generate_app_name_from_package, 'com.oopsfee.app')).to eq('Oopsfee')
    end

    it 'skips common prefixes' do
      expect(cli.send(:generate_app_name_from_package, 'com.example.myapp')).to eq('Example')
    end

    it 'handles io prefix' do
      expect(cli.send(:generate_app_name_from_package, 'io.mysigner.app')).to eq('Mysigner')
    end

    it 'handles org prefix' do
      expect(cli.send(:generate_app_name_from_package, 'org.apache.cordova')).to eq('Apache')
    end

    it 'falls back to last segment' do
      expect(cli.send(:generate_app_name_from_package, 'com.app')).to eq('App')
    end

    it 'capitalizes the name' do
      expect(cli.send(:generate_app_name_from_package, 'com.mycompany.coolapp')).to eq('Mycompany')
    end
  end
end
