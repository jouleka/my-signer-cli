# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/config'
require 'mysigner/cli'
require 'mysigner/credential_resolver'
require 'mysigner/local_credentials'
require 'open3'
require 'stringio'
require 'tmpdir'

# mysigner-38 — these specs encode the contract every later sub-ticket of
# Epic mysigner-22 will consume:
#   * Config.local_only? cascades ENV → ~/.mysigner/config.yml's local_only: key.
#   * Helpers#local_only? priority-chains the flag (when non-nil) → Config.local_only?
#     (env then file), so --no-local-only correctly overrides the env / file setting.
#   * Banner is opt-in user-facing UX: TTY-only, exactly once per process.
# A regression in any of these silently breaks the local-only mode the
# whole epic depends on, so the assertions are intentionally tight.
RSpec.describe 'mysigner --local-only' do
  before do
    ENV.delete('MYSIGNER_LOCAL_ONLY')
    # 0.3.1 — every spec in this file exercises Config.local_only? at some
    # depth. Stub the file source to false by default so the tests stay
    # hermetic against the dev machine's own ~/.mysigner/config.yml (which
    # may legitimately have local_only: true for personal use). Individual
    # examples that want to test the file source override this stub.
    allow(Mysigner::Config).to receive(:local_only_from_file?).and_return(false)
  end

  after do
    ENV.delete('MYSIGNER_LOCAL_ONLY')
  end

  describe 'Mysigner::Config.local_only?' do
    it 'returns false when MYSIGNER_LOCAL_ONLY is unset' do
      expect(Mysigner::Config.local_only?).to be false
    end

    {
      '1' => true,
      'true' => true,
      'TRUE' => true,
      'True' => true,
      'yes' => true,
      'YES' => true,
      '0' => false,
      'no' => false,
      'false' => false,
      'maybe' => false,
      '' => false,
      '   ' => false
    }.each do |value, expected|
      it "returns #{expected} for ENV value #{value.inspect}" do
        ENV['MYSIGNER_LOCAL_ONLY'] = value
        expect(Mysigner::Config.local_only?).to be expected
      end
    end
  end

  describe 'Helpers#local_only?' do
    let(:cli) { Mysigner::CLI.new }

    it 'returns true when --local-only flag is set even with ENV unset' do
      # Simulate Thor passing the parsed option through. We touch options
      # directly rather than driving Thor end-to-end so the unit covers
      # the predicate logic, not Thor's parser.
      allow(cli).to receive(:options).and_return({ local_only: true })
      expect(cli.local_only?).to be true
    end

    it 'returns true when ENV is truthy and no --local-only flag is passed' do
      # Flag not passed at all (nil) → fall through to env var.
      # (When --no-local-only IS passed, options[:local_only] is false and
      # overrides the env — that contract is covered by the precedence block below.)
      ENV['MYSIGNER_LOCAL_ONLY'] = '1'
      allow(cli).to receive(:options).and_return({})
      expect(cli.local_only?).to be true
    end

    it 'returns false when neither flag nor ENV is set' do
      allow(cli).to receive(:options).and_return({ local_only: false })
      expect(cli.local_only?).to be false
    end
  end

  describe 'Helpers#emit_local_only_banner' do
    let(:cli) { Mysigner::CLI.new }
    let(:banner) do
      '[mysigner] local-only mode active — signing credentials stay on this machine ' \
        '(other MySigner APIs may still be used; see docs).'
    end

    before do
      # Reset the module-level once-per-invocation guard so each example
      # starts clean. The guard is intentionally process-scoped in real
      # use; we reach in to reset it only because RSpec runs many
      # "invocations" inside one process.
      Mysigner::CLI::Concerns::Helpers.reset_banner!
    end

    # We stub $stderr.tty? to gate the banner and stub `warn` on the CLI
    # instance to capture what would be written. Stubbing the method
    # (rather than rebinding $stderr) sidesteps Kernel#warn's C-level
    # use of the original stderr handle.
    it 'writes the banner to stderr when stderr is a TTY' do
      allow($stderr).to receive(:tty?).and_return(true)
      expect(cli).to receive(:warn).with(banner).once
      cli.emit_local_only_banner
    end

    it 'does NOT write the banner when stderr is not a TTY' do
      allow($stderr).to receive(:tty?).and_return(false)
      expect(cli).not_to receive(:warn)
      cli.emit_local_only_banner
    end

    it 'emits the banner only once per CLI invocation' do
      allow($stderr).to receive(:tty?).and_return(true)
      expect(cli).to receive(:warn).with(banner).once
      cli.emit_local_only_banner
      cli.emit_local_only_banner
    end
  end

  describe 'CLI integration' do
    let(:exe_path) { File.expand_path('../../exe/mysigner', __dir__) }

    it 'accepts --local-only as a global flag without erroring' do
      # Smoke test: the flag is wired into Thor and a no-side-effect
      # command (help) still exits clean. Catches regressions where
      # the class_option is removed or mis-typed.
      _stdout, _stderr, status = Open3.capture3('bundle', 'exec', 'mysigner', '--local-only', 'help')
      expect(status.exitstatus).to eq(0)
    end

    # mysigner-22 Phase 6 ship-test regression: a `--local-only` flag written
    # BEFORE the subcommand was being eaten by Thor's command-name lookup
    # (which only considers the first non-flag arg). The CLI silently
    # dispatched to `help`, producing
    # `"mysigner help" was called with arguments ["ship", "appstore", ...]`.
    # The entry-point hoist in exe/mysigner moves leading class_options to
    # AFTER the subcommand so Thor can find it. The assertion targets that
    # exact failure mode — we don't care whether ship succeeds (it can't
    # without a real project), only that we routed to ship and not to help.
    it 'routes `--local-only ship appstore [...]` to ship, not help' do
      Dir.mktmpdir do |tmp|
        env = {
          'MYSIGNER_API_TOKEN' => nil,
          'MYSIGNER_ORG_ID' => nil,
          'MYSIGNER_API_URL' => nil,
          'MYSIGNER_LOCAL_ONLY' => nil
        }
        stdout, stderr, _status = Open3.capture3(
          env,
          'bundle', 'exec', 'mysigner', '--local-only', 'ship', 'appstore',
          '--asc-key-path=/nonexistent.p8',
          '--asc-key-id=ABC',
          '--asc-issuer-id=UUID',
          '--apple-id=12345',
          chdir: tmp
        )
        combined = "#{stdout}#{stderr}"
        expect(combined).not_to include('"mysigner help" was called'),
                                "Expected Thor to dispatch ship, not help. Got:\n#{combined}"
      end
    end
  end

  # mysigner-22 — the auth-bootstrap helpers must short-circuit in local-only
  # mode so the CLI runs on a fresh machine with NO MySigner login at all
  # (no ~/.mysigner/config.yml, no API token). Regressions in either of these
  # would re-introduce the original bug ("ship appstore --local-only" exited 1
  # with `Not logged in. Run 'mysigner login' first.`).
  describe 'Helpers#load_config / #create_client in local-only mode' do
    let(:cli) { Mysigner::CLI.new }

    before do
      ENV.delete('MYSIGNER_API_TOKEN')
      ENV.delete('MYSIGNER_ORG_ID')
      ENV.delete('MYSIGNER_API_URL')
      allow(cli).to receive(:options).and_return({ local_only: true })
    end

    it 'returns a blank Config sentinel without requiring a login or touching disk' do
      # WHY: the bug was that load_config exit(1)'d before any local-only
      # code could run, even though we never intend to talk to MySigner.
      # The sentinel returns nil for every field a server-mode caller would
      # consume (api_url, api_token, current_organization_id) — proving
      # we did not silently fall back to reading the on-disk config.
      expect(cli).not_to receive(:exit)
      expect(cli).not_to receive(:error)

      # Config.new MUST NOT be invoked — that ctor auto-loads
      # ~/.mysigner/config.yml when it exists, which is exactly the broken-
      # decryption path the bug report came from.
      expect(Mysigner::Config).not_to receive(:new)

      config = cli.load_config

      expect(config).to be_a(Mysigner::Config)
      expect(config.api_url).to be_nil
      expect(config.api_token).to be_nil
      expect(config.current_organization_id).to be_nil
    end

    it 'create_client returns nil so accidental client.* calls fail loud' do
      # WHY: every MySigner endpoint touched in `ship appstore` (sync,
      # /apple_apps, /builds, /app_store_releases) is supposed to be skipped
      # in local-only. Returning a real Client here would silently re-enable
      # them when the call-site guard is forgotten. nil produces a clear
      # NoMethodError on any leftover `client.get(...)` instead.
      expect(cli.create_client(cli.load_config)).to be_nil
    end
  end

  # mysigner-22 — vault path must be byte-identical: a regression in the
  # local-only short-circuit must not change how a normal `mysigner ship`
  # invocation discovers credentials.
  describe 'Helpers#load_config in vault mode still fails loud on missing login' do
    let(:cli) { Mysigner::CLI.new }

    before do
      ENV.delete('MYSIGNER_API_TOKEN')
      ENV.delete('MYSIGNER_ORG_ID')
      ENV.delete('MYSIGNER_API_URL')
      allow(cli).to receive(:options).and_return({ local_only: false })
      allow(cli).to receive(:say)
      allow(cli).to receive(:error)
    end

    it 'still exits 1 with the historical "Not logged in" message when no config exists' do
      # Force "no config on disk" without actually mutating the user's
      # ~/.mysigner. We stub the predicate the helper uses.
      allow_any_instance_of(Mysigner::Config).to receive(:exists?).and_return(false)

      expect(cli).to receive(:error).with(/Not logged in/)
      expect(cli).to receive(:exit).with(1)

      cli.load_config
    end

    # Discoverability fix — the historical "Not logged in" tip only mentioned
    # CI/CD env vars. A first-time user who doesn't want a MySigner account
    # at all had no way to discover `--local-only` from this error path.
    # The new tip surfaces it on equal footing with the CI/CD tip. Regression
    # here means we re-introduce the "users think MySigner login is mandatory"
    # support bug.
    it 'surfaces the --local-only tip alongside the CI/CD tip' do
      allow_any_instance_of(Mysigner::Config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:exit).with(1)

      tips = []
      allow(cli).to receive(:say) { |msg, *| tips << msg.to_s }

      cli.load_config

      combined = tips.join("\n")
      expect(combined).to match(/--local-only/)
      expect(combined).to match(/mysigner --local-only ship appstore/)
      expect(combined).to match(/Local-only mode.*README/i)
    end
  end

  describe 'Helpers#local_only? precedence (flag > env > file > false)' do
    let(:cli) { Mysigner::CLI.new }

    before { ENV.delete('MYSIGNER_LOCAL_ONLY') }
    after  { ENV.delete('MYSIGNER_LOCAL_ONLY') }

    it 'returns false when nothing is set' do
      allow(cli).to receive(:options).and_return({})
      expect(cli.local_only?).to be false
    end

    it 'returns true when --local-only flag is passed' do
      allow(cli).to receive(:options).and_return({ local_only: true })
      expect(cli.local_only?).to be true
    end

    it '--no-local-only flag overrides MYSIGNER_LOCAL_ONLY=1' do
      ENV['MYSIGNER_LOCAL_ONLY'] = '1'
      allow(cli).to receive(:options).and_return({ local_only: false })
      expect(cli.local_only?).to be false
    end

    it 'env var alone enables local-only' do
      ENV['MYSIGNER_LOCAL_ONLY'] = '1'
      allow(cli).to receive(:options).and_return({})
      expect(cli.local_only?).to be true
    end
  end

  describe 'Mysigner::Config.local_only_from_file?' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:config_file) { File.join(tmp_dir, 'config.yml') }

    before do
      stub_const('Mysigner::Config::CONFIG_FILE', config_file)
      # Override the outer-block stub — this block tests the real method.
      allow(Mysigner::Config).to receive(:local_only_from_file?).and_call_original
    end
    after { FileUtils.rm_rf(tmp_dir) }

    it 'returns false when the file does not exist' do
      expect(Mysigner::Config.local_only_from_file?).to be false
    end

    it 'returns true when YAML has local_only: true' do
      File.write(config_file, { 'local_only' => true }.to_yaml)
      expect(Mysigner::Config.local_only_from_file?).to be true
    end

    it 'returns false when YAML has local_only: false' do
      File.write(config_file, { 'local_only' => false }.to_yaml)
      expect(Mysigner::Config.local_only_from_file?).to be false
    end

    it 'returns false when YAML omits the key' do
      File.write(config_file, { 'api_url' => 'x' }.to_yaml)
      expect(Mysigner::Config.local_only_from_file?).to be false
    end

    it 'returns false on malformed YAML (no raise)' do
      File.write(config_file, 'not: valid: yaml: at: all')
      expect { Mysigner::Config.local_only_from_file? }.not_to raise_error
      expect(Mysigner::Config.local_only_from_file?).to be false
    end
  end

  # 0.3.1 — public mirror of local_only_from_file? for symmetric source
  # attribution in `mysigner status`. Uses the same truthy parser as the
  # cascade, so MYSIGNER_LOCAL_ONLY=0 reads false (not "set therefore on").
  describe 'Mysigner::Config.local_only_from_env?' do
    before { ENV.delete('MYSIGNER_LOCAL_ONLY') }
    after  { ENV.delete('MYSIGNER_LOCAL_ONLY') }

    it 'returns false when the env var is unset' do
      expect(Mysigner::Config.local_only_from_env?).to be false
    end

    it 'returns true when the env var is truthy (1)' do
      ENV['MYSIGNER_LOCAL_ONLY'] = '1'
      expect(Mysigner::Config.local_only_from_env?).to be true
    end

    it 'returns false when the env var is "0" (was the source-attribution bug)' do
      ENV['MYSIGNER_LOCAL_ONLY'] = '0'
      expect(Mysigner::Config.local_only_from_env?).to be false
    end

    it 'returns false when the env var is "false"' do
      ENV['MYSIGNER_LOCAL_ONLY'] = 'false'
      expect(Mysigner::Config.local_only_from_env?).to be false
    end

    it 'returns false when the env var is an empty string' do
      ENV['MYSIGNER_LOCAL_ONLY'] = ''
      expect(Mysigner::Config.local_only_from_env?).to be false
    end
  end

  describe 'Mysigner::Config.local_only? cascade (env → file)' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:config_file) { File.join(tmp_dir, 'config.yml') }

    before do
      ENV.delete('MYSIGNER_LOCAL_ONLY')
      stub_const('Mysigner::Config::CONFIG_FILE', config_file)
      # Override the outer-block stub — this block tests the real cascade.
      allow(Mysigner::Config).to receive(:local_only_from_file?).and_call_original
    end
    after do
      ENV.delete('MYSIGNER_LOCAL_ONLY')
      FileUtils.rm_rf(tmp_dir)
    end

    it 'returns false when neither env nor file is set' do
      expect(Mysigner::Config.local_only?).to be false
    end

    it 'env true alone enables it' do
      ENV['MYSIGNER_LOCAL_ONLY'] = '1'
      expect(Mysigner::Config.local_only?).to be true
    end

    it 'file true alone enables it' do
      File.write(config_file, { 'local_only' => true }.to_yaml)
      expect(Mysigner::Config.local_only?).to be true
    end
  end

  # mysigner-22 Task 5 — server-only command guard. When local-only mode is
  # active, commands that manage MySigner-side resources (apps, orgs, sync,
  # certificates, etc.) must exit 2 with a clear explanation rather than
  # falling through to the "Not logged in" path. Exit 2 (not 1) distinguishes
  # "wrong mode" from "missing credential" so CI scripts can branch on it.
  describe 'Helpers#exit_unless_local_supported!' do
    let(:cli) { Mysigner::CLI.new }

    before do
      ENV.delete('MYSIGNER_LOCAL_ONLY')
      allow(cli).to receive(:options).and_return({})
    end
    after { ENV.delete('MYSIGNER_LOCAL_ONLY') }

    it 'is a no-op when local-only is OFF' do
      expect do
        cli.send(:exit_unless_local_supported!, 'apps')
      end.not_to raise_error
    end

    it 'exits 2 with explanation when local-only is ON (via flag)' do
      allow(cli).to receive(:options).and_return({ local_only: true })

      out = StringIO.new
      $stdout = out

      expect do
        cli.send(:exit_unless_local_supported!, 'apps')
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }

      output = out.string
      expect(output).to include('`apps` manages MySigner-side resources')
      expect(output).to include("isn't available in local-only mode.")
      expect(output).to include('mysigner config set local-only false')
      expect(output).to include('mysigner --no-local-only apps')
    ensure
      $stdout = STDOUT
    end

    it 'exits 2 when local-only is ON (via env)' do
      ENV['MYSIGNER_LOCAL_ONLY'] = '1'

      expect do
        cli.send(:exit_unless_local_supported!, 'sync')
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
    end
  end

  describe 'Helpers#resolve_local_android_keystore_or_exit' do
    let(:cli) { Mysigner::CLI.new }

    before do
      # Make the cascade fully knowable without touching the dev's machine.
      stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR', '/tmp/__phase7_helper_apple_not_present__')
      allow(Mysigner::LocalCredentials).to receive(:list).and_return([])
    end

    it 'returns the AndroidKeystoreCreds struct on a successful cascade' do
      creds = Mysigner::CredentialResolver::AndroidKeystoreCreds.new(
        keystore_path: '/tmp/ks.jks', keystore_password: 'p', key_alias: 'a',
        key_password: 'p', source: :flag, tmpfile: nil
      )
      allow(Mysigner::CredentialResolver).to receive(:resolve_android_keystore).and_return(creds)
      allow(cli).to receive(:options).and_return({})

      result = cli.resolve_local_android_keystore_or_exit
      expect(result).to be(creds)
    end

    it 'forwards options.to_h into the resolver so flags propagate' do
      allow(cli).to receive(:options).and_return({
                                                   keystore_path: '/p.jks',
                                                   keystore_password: 'pw',
                                                   key_alias: 'k',
                                                   key_password: 'kp'
                                                 })
      creds = Mysigner::CredentialResolver::AndroidKeystoreCreds.new(
        keystore_path: '/p.jks', keystore_password: 'pw', key_alias: 'k',
        key_password: 'kp', source: :flag, tmpfile: nil
      )

      expect(Mysigner::CredentialResolver).to receive(:resolve_android_keystore)
        .with(options: hash_including(keystore_path: '/p.jks', key_alias: 'k'))
        .and_return(creds)

      cli.resolve_local_android_keystore_or_exit
    end

    it 'prints a clean error and exits 1 on CredentialNotFoundError (Rule 12, fail loud)' do
      allow(cli).to receive(:options).and_return({})
      allow(Mysigner::CredentialResolver).to receive(:resolve_android_keystore)
        .and_raise(Mysigner::CredentialResolver::CredentialNotFoundError.new('no creds anywhere'))

      expect(cli).to receive(:say).with(/No local Android keystore found.*no creds anywhere/m, :red)
      expect(cli).to receive(:exit).with(1)

      cli.resolve_local_android_keystore_or_exit
    end

    it 'prints a clean error and exits 1 on AmbiguousCredentialsError' do
      allow(cli).to receive(:options).and_return({})
      allow(Mysigner::CredentialResolver).to receive(:resolve_android_keystore)
        .and_raise(Mysigner::CredentialResolver::AmbiguousCredentialsError.new('multiple, pass --key-alias'))

      expect(cli).to receive(:say).with(/No local Android keystore found.*multiple, pass --key-alias/m, :red)
      expect(cli).to receive(:exit).with(1)

      cli.resolve_local_android_keystore_or_exit
    end
  end
end
