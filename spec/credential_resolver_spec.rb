# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'stringio'
require 'tempfile'
require 'tmpdir'
require 'mysigner/credential_resolver'

# mysigner-22 Phase 5 — credential auto-discovery cascade.
# Every spec here pins ONE leg of the contract the resolver promises:
#   * priority order (flag > env > keychain > disk > prompt)
#   * partial-tier stitching (e.g. disk gives the .p8 path, env gives the issuer)
#   * non-TTY behavior (must raise, never block on read)
#   * `source` field is set correctly so the CLI can log audit info
#   * not-found message names every source tried + the override knob
# A regression in any of these silently breaks the local-only mode users now
# rely on for "no MySigner server needed" shipping.
RSpec.describe Mysigner::CredentialResolver do
  let(:tty_stdin)    { instance_double(IO, tty?: true,  gets: "from-prompt\n") }
  let(:no_tty_stdin) { instance_double(IO, tty?: false) }
  let(:stderr)       { StringIO.new }

  # Helper: stand in for ENV without polluting the test process.
  def env(**vars)
    vars.transform_keys(&:to_s)
  end

  # Apple-style filename so derive_key_id_from_filename picks it up.
  def write_p8(dir, key_id: 'ABCDE12345', content: "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n")
    path = File.join(dir, "AuthKey_#{key_id}.p8")
    File.write(path, content)
    path
  end

  def write_sa_json(path, client_email: 'svc@my-project.iam.gserviceaccount.com')
    payload = {
      'type' => 'service_account',
      'client_email' => client_email,
      'private_key' => "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n",
      'project_id' => 'my-project'
    }
    File.write(path, JSON.generate(payload))
    [JSON.generate(payload), client_email]
  end

  before do
    # Keychain is the noisiest tier — by default every test starts with an
    # empty store so behavior is purely a function of the other tiers. Tests
    # that exercise keychain explicitly override.
    require 'mysigner/local_credentials'
    allow(Mysigner::LocalCredentials).to receive(:list).and_return([])
    # Make the on-disk Apple location absent by default; tests that exercise
    # it stub specific dirs via stub_const.
    stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR', '/tmp/__resolver_apple_not_present__')
    # Force ~/.gradle/gradle.properties absent by default. The Android cascade
    # sniffs it as a per-user fallback (mysigner-22 Phase 7 follow-up), and
    # without this stub the spec would pick up the developer's REAL gradle
    # properties on machines that happen to have one — that's the kind of
    # environment-leak bug that passes locally and explodes in CI. Specs that
    # exercise this tier override the stub explicitly.
    @real_expand_path = File.method(:expand_path)
    allow(File).to receive(:expand_path) { |*args| @real_expand_path.call(*args) }
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(@real_expand_path.call('~/.gradle/gradle.properties')).and_return(false)
  end

  describe '.resolve_asc' do
    describe 'tier 1 — per-command flags' do
      it 'returns AscCreds from flags alone when all three are present, marking source :flag' do
        Dir.mktmpdir do |dir|
          path = write_p8(dir, key_id: 'XYZ')
          creds = described_class.resolve_asc(
            options: { asc_key_path: path, asc_key_id: 'XYZ', asc_issuer_id: 'ISSUER-UUID' },
            env: env, stdin: no_tty_stdin, stderr: stderr
          )

          expect(creds.key_id).to eq('XYZ')
          expect(creds.issuer_id).to eq('ISSUER-UUID')
          expect(creds.p8_pem).to include('BEGIN PRIVATE KEY')
          expect(creds.source).to eq(:flag)
        end
      end

      it 'raises CredentialNotFoundError when the flag points at a non-existent file' do
        expect do
          described_class.resolve_asc(
            options: { asc_key_path: '/tmp/__does_not_exist.p8', asc_key_id: 'XYZ', asc_issuer_id: 'I' },
            env: env, stdin: no_tty_stdin, stderr: stderr
          )
        end.to raise_error(described_class::CredentialNotFoundError, /file not found.*--asc-key-path/)
      end
    end

    describe 'tier 2 — env vars (fastlane convention)' do
      # WHY this spec populates both keychain AND a real on-disk Apple
      # private-keys dir: the "env wins" claim is only meaningful if the
      # lower tiers actually have something to lose to. An earlier version
      # of this spec stubbed the disk dir to a non-existent path, making
      # the disk side a no-op and the assertion tautological — the exact
      # gap that let a disk-scan ambiguity bug ship in Phase 5. The CLI
      # prints `[mysigner] ASC credentials source: <source>` for audit,
      # so source attribution is contract-level, not cosmetic.
      it 'wins over keychain and disk, marking source :env' do
        Dir.mktmpdir do |env_dir|
          Dir.mktmpdir do |disk_dir|
            # Disk tier: a real .p8 a lower-priority tier would otherwise pick.
            write_p8(disk_dir, key_id: 'DISKKEY')
            stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR', disk_dir)
            # Keychain tier: a different key entirely.
            allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :asc).and_return(['KEYCHAIN_KEY'])

            # Env tier: a third, distinct key. The cascade contract says
            # this must win over both lower tiers.
            env_path = write_p8(env_dir, key_id: 'ENVKEY')
            env_vars = env(
              'APP_STORE_CONNECT_API_KEY_PATH' => env_path,
              'APP_STORE_CONNECT_API_KEY_ID' => 'ENVKEY',
              'APP_STORE_CONNECT_API_KEY_ISSUER_ID' => 'env-issuer'
            )

            creds = described_class.resolve_asc(
              options: {}, env: env_vars, stdin: no_tty_stdin, stderr: stderr
            )

            expect(creds.source).to eq(:env)
            expect(creds.key_id).to eq('ENVKEY')
            expect(creds.issuer_id).to eq('env-issuer')
          end
        end
      end
    end

    describe 'tier 3 — Keychain' do
      let(:ec_pem) { "-----BEGIN EC PRIVATE KEY-----\nFAKE\n-----END EC PRIVATE KEY-----\n" }

      it 'returns the single keychain entry when one is stored, marking source :keychain' do
        allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :asc).and_return(['KEY42'])
        allow(Mysigner::LocalCredentials).to receive(:fetch)
          .with(kind: :asc, id: 'KEY42')
          .and_return(JSON.generate('issuer_id' => 'ISSUER42', 'p8_pem' => ec_pem))

        creds = described_class.resolve_asc(options: {}, env: env, stdin: no_tty_stdin, stderr: stderr)

        expect(creds.source).to eq(:keychain)
        expect(creds.key_id).to eq('KEY42')
        expect(creds.issuer_id).to eq('ISSUER42')
        expect(creds.p8_pem).to eq(ec_pem)
      end

      it 'raises AmbiguousCredentialsError when multiple keychain entries exist and no hint disambiguates' do
        allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :asc).and_return(%w[A B])

        expect do
          described_class.resolve_asc(options: {}, env: env, stdin: no_tty_stdin, stderr: stderr)
        end.to raise_error(described_class::AmbiguousCredentialsError, /Multiple ASC credentials.*--asc-key-id/)
      end

      it 'picks the keychain entry matching the --asc-key-id hint when multiple exist' do
        allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :asc).and_return(%w[A B])
        allow(Mysigner::LocalCredentials).to receive(:fetch)
          .with(kind: :asc, id: 'B')
          .and_return(JSON.generate('issuer_id' => 'IB', 'p8_pem' => ec_pem))

        creds = described_class.resolve_asc(
          options: { asc_key_id: 'B' }, env: env, stdin: no_tty_stdin, stderr: stderr
        )
        expect(creds.source).to eq(:keychain)
        expect(creds.key_id).to eq('B')
        expect(creds.issuer_id).to eq('IB')
      end

      it 'fails loud when a stored keychain envelope is not valid JSON (defensive — legacy plain PEM)' do
        allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :asc).and_return(['LEGACY'])
        allow(Mysigner::LocalCredentials).to receive(:fetch)
          .with(kind: :asc, id: 'LEGACY')
          .and_return('this is not json')

        expect do
          described_class.resolve_asc(options: {}, env: env, stdin: no_tty_stdin, stderr: stderr)
        end.to raise_error(described_class::CredentialNotFoundError, /not valid JSON/)
      end

      it 'fails loud when a stored keychain envelope is missing required fields' do
        allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :asc).and_return(['HALF'])
        allow(Mysigner::LocalCredentials).to receive(:fetch)
          .with(kind: :asc, id: 'HALF')
          .and_return(JSON.generate('p8_pem' => 'data only'))

        expect do
          described_class.resolve_asc(options: {}, env: env, stdin: no_tty_stdin, stderr: stderr)
        end.to raise_error(described_class::CredentialNotFoundError, /missing required fields/)
      end
    end

    describe 'tier 4 — disk scan (~/.appstoreconnect/private_keys)' do
      it 'finds a single AuthKey_<KEY_ID>.p8, derives key_id from filename, marks source :disk' do
        Dir.mktmpdir do |dir|
          write_p8(dir, key_id: 'DISK1')
          stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR', dir)

          creds = described_class.resolve_asc(
            options: {},
            env: env('APP_STORE_CONNECT_API_KEY_ISSUER_ID' => 'disk-issuer'),
            stdin: no_tty_stdin, stderr: stderr
          )

          expect(creds.source).to eq(:disk)
          expect(creds.key_id).to eq('DISK1')
          expect(creds.issuer_id).to eq('disk-issuer')
        end
      end

      it 'raises AmbiguousCredentialsError on multiple .p8 files without disambiguator' do
        Dir.mktmpdir do |dir|
          write_p8(dir, key_id: 'AAA')
          write_p8(dir, key_id: 'BBB')
          stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR', dir)

          expect do
            described_class.resolve_asc(options: {}, env: env, stdin: no_tty_stdin, stderr: stderr)
          end.to raise_error(described_class::AmbiguousCredentialsError, /Multiple ASC private keys/)
        end
      end

      it 'falls through past disk scan when the directory is missing (cascade continues)' do
        stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR', '/tmp/__truly_not_here__')

        expect do
          described_class.resolve_asc(options: {}, env: env, stdin: no_tty_stdin, stderr: stderr)
        end.to raise_error(described_class::CredentialNotFoundError) # falls through to tier 5
      end

      # WHY this spec exists: the disk-scan ambiguity check only matters when
      # disk is the WINNING tier. If env or flag already supplies a .p8 path,
      # the user has already disambiguated — surfacing "Multiple ASC private
      # keys found, pass --asc-key-path / APP_STORE_CONNECT_API_KEY_PATH"
      # while the user has literally just set that exact env var is nonsense.
      # Higher tier wins => lower tier shouldn't even probe.
      it 'does NOT raise on multiple disk .p8 files when env already supplies the path' do
        Dir.mktmpdir do |disk_dir|
          Dir.mktmpdir do |env_dir|
            # Two .p8 files in the standard Apple dir — the would-be
            # ambiguous-error trigger.
            write_p8(disk_dir, key_id: 'AAA')
            write_p8(disk_dir, key_id: 'BBB')
            stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR', disk_dir)

            # Env tier supplies a complete, unambiguous credential. The
            # cascade must take it without ever raising on disk.
            env_path = write_p8(env_dir, key_id: 'ENVCHOSEN')
            env_vars = env(
              'APP_STORE_CONNECT_API_KEY_PATH' => env_path,
              'APP_STORE_CONNECT_API_KEY_ID' => 'ENVCHOSEN',
              'APP_STORE_CONNECT_API_KEY_ISSUER_ID' => 'env-issuer'
            )

            creds = described_class.resolve_asc(
              options: {}, env: env_vars, stdin: no_tty_stdin, stderr: stderr
            )

            expect(creds.source).to eq(:env)
            expect(creds.key_id).to eq('ENVCHOSEN')
            expect(creds.issuer_id).to eq('env-issuer')
          end
        end
      end

      it 'does NOT raise on multiple disk .p8 files when --asc-key-path flag already supplies the path' do
        Dir.mktmpdir do |disk_dir|
          Dir.mktmpdir do |flag_dir|
            write_p8(disk_dir, key_id: 'AAA')
            write_p8(disk_dir, key_id: 'BBB')
            stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR', disk_dir)

            flag_path = write_p8(flag_dir, key_id: 'FLAGCHOSEN')

            creds = described_class.resolve_asc(
              options: { asc_key_path: flag_path, asc_key_id: 'FLAGCHOSEN', asc_issuer_id: 'flag-issuer' },
              env: env, stdin: no_tty_stdin, stderr: stderr
            )

            expect(creds.source).to eq(:flag)
            expect(creds.key_id).to eq('FLAGCHOSEN')
            expect(creds.issuer_id).to eq('flag-issuer')
          end
        end
      end
    end

    describe 'partial-cascade stitching' do
      it 'reads .p8 from disk but issuer_id from env (the documented half-and-half scenario)' do
        Dir.mktmpdir do |dir|
          write_p8(dir, key_id: 'HALFK')
          stub_const('Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR', dir)

          creds = described_class.resolve_asc(
            options: {},
            env: env('APP_STORE_CONNECT_API_KEY_ISSUER_ID' => 'env-issuer-uuid'),
            stdin: no_tty_stdin, stderr: stderr
          )

          # The PATH came from disk so the source is :disk, but the issuer
          # came from env — that's the point of the partial-cascade contract.
          expect(creds.source).to eq(:disk)
          expect(creds.key_id).to eq('HALFK')
          expect(creds.issuer_id).to eq('env-issuer-uuid')
        end
      end

      it 'reads .p8 path from env but key_id from filename and issuer from a flag' do
        Dir.mktmpdir do |dir|
          path = write_p8(dir, key_id: 'FROMFILE')
          creds = described_class.resolve_asc(
            options: { asc_issuer_id: 'flag-issuer' },
            env: env('APP_STORE_CONNECT_API_KEY_PATH' => path),
            stdin: no_tty_stdin, stderr: stderr
          )

          expect(creds.source).to eq(:env)
          expect(creds.key_id).to eq('FROMFILE')
          expect(creds.issuer_id).to eq('flag-issuer')
        end
      end
    end

    describe 'tier 5 — interactive prompt' do
      it 'prompts when STDIN is a TTY and nothing else resolved' do
        # Three gets() responses: path, key_id (no AuthKey_ filename → ask), issuer.
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'mykey.p8')
          File.write(path, "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n")
          tty = instance_double(IO, tty?: true)
          allow(tty).to receive(:gets).and_return("#{path}\n", "ANSWERED_KEY\n", "answered-issuer\n")

          creds = described_class.resolve_asc(options: {}, env: env, stdin: tty, stderr: stderr)
          expect(creds.source).to eq(:prompt)
          expect(creds.key_id).to eq('ANSWERED_KEY')
          expect(creds.issuer_id).to eq('answered-issuer')
        end
      end

      it 'NEVER prompts when STDIN is not a TTY (CI safety)' do
        # Even if `gets` would work, we must refuse to call it — non-TTY runs
        # must fail loud rather than hang forever waiting for input that will
        # never come.
        no_tty = instance_double(IO, tty?: false)
        expect(no_tty).not_to receive(:gets)

        expect do
          described_class.resolve_asc(options: {}, env: env, stdin: no_tty, stderr: stderr)
        end.to raise_error(described_class::CredentialNotFoundError)
      end

      # WHY this spec exists: the audit log line in helpers.rb prints
      # `[mysigner] ASC credentials source: <source>`. When the .p8 path
      # comes from env and only the missing issuer_id is prompted, the
      # source must remain :env — otherwise the log misattributes the
      # whole credential to :prompt, which is wrong (the primary material
      # came from env; issuer_id is metadata).
      it 'preserves source :env when path is from env but issuer_id is prompted' do
        Dir.mktmpdir do |dir|
          path = write_p8(dir, key_id: 'ENVK')
          tty = instance_double(IO, tty?: true)
          # Only the issuer should be asked (path and key_id come from env/filename).
          allow(tty).to receive(:gets).and_return("env-prompted-issuer\n")

          creds = described_class.resolve_asc(
            options: {},
            env: env('APP_STORE_CONNECT_API_KEY_PATH' => path),
            stdin: tty, stderr: stderr
          )

          expect(creds.source).to eq(:env)
          expect(creds.key_id).to eq('ENVK')
          expect(creds.issuer_id).to eq('env-prompted-issuer')
        end
      end

      # Inverse: when path itself is prompted (no env/flag/keychain/disk
      # supplied it), source MUST be :prompt — the originating tier is the
      # prompt for the primary material.
      it 'reports source :prompt when both path and issuer are prompted' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'plain-key.p8')
          File.write(path, "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n")
          tty = instance_double(IO, tty?: true)
          # Three responses: path, key_id (no AuthKey_ filename → ask), issuer.
          allow(tty).to receive(:gets).and_return("#{path}\n", "P-KEY\n", "p-issuer\n")

          creds = described_class.resolve_asc(options: {}, env: env, stdin: tty, stderr: stderr)
          expect(creds.source).to eq(:prompt)
          expect(creds.key_id).to eq('P-KEY')
          expect(creds.issuer_id).to eq('p-issuer')
        end
      end
    end

    describe 'CredentialNotFoundError message' do
      it 'names every source tried AND every override knob (Rule 12 — fail loud)' do
        described_class.resolve_asc(options: {}, env: env, stdin: no_tty_stdin, stderr: stderr)
      rescue described_class::CredentialNotFoundError => e
        msg = e.message
        expect(msg).to include('--asc-key-path')
        expect(msg).to include('APP_STORE_CONNECT_API_KEY_PATH')
        expect(msg).to include('mysigner onboard --local-only')
        expect(msg).to include(Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR)
        # Lists what was tried with a marker per source.
        expect(msg).to match(/Tried in order/)
        expect(msg).to include('keychain:')
        expect(msg).to include('disk:')
      else
        raise 'expected CredentialNotFoundError'
      end
    end
  end

  describe '.resolve_play' do
    describe 'tier 1 — flag' do
      it 'reads the SA-JSON at --play-credentials and returns PlayCreds with source :flag' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'sa.json')
          _, email = write_sa_json(path)

          creds = described_class.resolve_play(
            options: { play_credentials: path }, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
          expect(creds.source).to eq(:flag)
          expect(creds.client_email).to eq(email)
        end
      end

      it 'raises CredentialNotFoundError when the flag points at a malformed JSON file' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'bad.json')
          File.write(path, '{not json')

          expect do
            described_class.resolve_play(
              options: { play_credentials: path }, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
            )
          end.to raise_error(described_class::CredentialNotFoundError, /not valid JSON/)
        end
      end

      it 'raises CredentialNotFoundError when the SA-JSON is missing required fields' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'half.json')
          File.write(path, JSON.generate('type' => 'service_account', 'client_email' => 'x@y.com'))

          expect do
            described_class.resolve_play(
              options: { play_credentials: path }, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
            )
          end.to raise_error(described_class::CredentialNotFoundError, /missing required fields/)
        end
      end
    end

    describe 'tier 2 — GOOGLE_APPLICATION_CREDENTIALS env' do
      it 'reads the env-pointed SA-JSON, source :env' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'env-sa.json')
          _, email = write_sa_json(path)

          creds = described_class.resolve_play(
            options: {}, env: env('GOOGLE_APPLICATION_CREDENTIALS' => path),
            stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          expect(creds.source).to eq(:env)
          expect(creds.client_email).to eq(email)
        end
      end
    end

    describe 'tier 3 — Keychain' do
      it 'returns the single keychain entry, source :keychain' do
        Dir.mktmpdir do |dir|
          raw_payload = JSON.generate(
            'type' => 'service_account',
            'client_email' => 'k@me.com',
            'private_key' => 'fake',
            'project_id' => 'p'
          )
          allow(Mysigner::LocalCredentials).to receive(:list).with(kind: :google_play).and_return(['k@me.com'])
          allow(Mysigner::LocalCredentials).to receive(:fetch)
            .with(kind: :google_play, id: 'k@me.com').and_return(raw_payload)

          creds = described_class.resolve_play(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
          expect(creds.source).to eq(:keychain)
          expect(creds.client_email).to eq('k@me.com')
          expect(creds.sa_json).to eq(raw_payload)
        end
      end

      it 'raises AmbiguousCredentialsError when multiple keychain entries exist' do
        allow(Mysigner::LocalCredentials).to receive(:list)
          .with(kind: :google_play).and_return(['a@x.com', 'b@x.com'])

        Dir.mktmpdir do |dir|
          expect do
            described_class.resolve_play(
              options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
            )
          end.to raise_error(described_class::AmbiguousCredentialsError, /Multiple Google Play/)
        end
      end
    end

    describe 'tier 4 — project sniff' do
      it 'finds service-account.json at the project root' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'service-account.json')
          _, email = write_sa_json(path)

          creds = described_class.resolve_play(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
          expect(creds.source).to eq(:disk)
          expect(creds.client_email).to eq(email)
        end
      end

      it 'walks up parent directories (up to PROJECT_SNIFF_MAX_DEPTH) to find the file' do
        Dir.mktmpdir do |root|
          deep = File.join(root, 'apps', 'ios')
          FileUtils.mkdir_p(deep)
          path = File.join(root, 'play-credentials.json')
          _, email = write_sa_json(path)

          creds = described_class.resolve_play(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: deep
          )
          expect(creds.source).to eq(:disk)
          expect(creds.client_email).to eq(email)
        end
      end

      it 'extracts serviceAccountKeyPath from eas.json (Expo convention)' do
        Dir.mktmpdir do |dir|
          sa_path = File.join(dir, 'sa-from-eas.json')
          _, email = write_sa_json(sa_path)
          File.write(File.join(dir, 'eas.json'), JSON.generate(
                                                   'submit' => {
                                                     'production' => {
                                                       'android' => { 'serviceAccountKeyPath' => './sa-from-eas.json' }
                                                     }
                                                   }
                                                 ))

          creds = described_class.resolve_play(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
          expect(creds.source).to eq(:disk)
          expect(creds.client_email).to eq(email)
        end
      end

      it 'returns nothing (and raises in non-TTY) when no sniff matches' do
        Dir.mktmpdir do |dir|
          expect do
            described_class.resolve_play(
              options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
            )
          end.to raise_error(described_class::CredentialNotFoundError)
        end
      end
    end

    describe 'tier 5 — interactive prompt (TTY only)' do
      it 'prompts when TTY and nothing else resolved' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'sa.json')
          _, email = write_sa_json(path)
          tty = instance_double(IO, tty?: true, gets: "#{path}\n")

          creds = described_class.resolve_play(
            options: {}, env: env, stdin: tty, stderr: stderr, cwd: dir
          )
          expect(creds.source).to eq(:prompt)
          expect(creds.client_email).to eq(email)
        end
      end

      it 'NEVER prompts when STDIN is not a TTY (CI safety)' do
        no_tty = instance_double(IO, tty?: false)
        expect(no_tty).not_to receive(:gets)

        Dir.mktmpdir do |dir|
          expect do
            described_class.resolve_play(
              options: {}, env: env, stdin: no_tty, stderr: stderr, cwd: dir
            )
          end.to raise_error(described_class::CredentialNotFoundError)
        end
      end
    end

    describe 'CredentialNotFoundError message names every source tried + override knobs' do
      it 'lists --play-credentials, GOOGLE_APPLICATION_CREDENTIALS, onboard, project files' do
        Dir.mktmpdir do |dir|
          described_class.resolve_play(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
        rescue described_class::CredentialNotFoundError => e
          msg = e.message
          expect(msg).to include('--play-credentials')
          expect(msg).to include('GOOGLE_APPLICATION_CREDENTIALS')
          expect(msg).to include('mysigner onboard --local-only')
          expect(msg).to include('eas.json')
          expect(msg).to match(/Tried in order/)
        else
          raise 'expected CredentialNotFoundError'
        end
      end
    end
  end

  # mysigner-22 Phase 7 — Android keystore cascade. Every spec here pins
  # one rung of the contract `ship play --local-only` now depends on:
  # priority order (flag > env > keychain > sniff > prompt),
  # partial-tier stitching (env path + flag password, etc.),
  # non-TTY safety (must raise, never block on read),
  # ambiguous-keychain error wording (mentions --key-alias),
  # project sniff walks up parent dirs and parses key.properties / eas.json.
  # A regression here re-introduces the MySigner-server keystore download
  # that mysigner-22 was meant to remove.
  describe '.resolve_android_keystore' do
    def write_jks(path, content: "FAKE\x00JKS\x01BYTES".b)
      File.binwrite(path, content)
      path
    end

    describe 'tier 1 — per-command flags' do
      it 'returns AndroidKeystoreCreds from flags alone when all four are present, source :flag' do
        Dir.mktmpdir do |dir|
          path = write_jks(File.join(dir, 'release.jks'))
          creds = described_class.resolve_android_keystore(
            options: { keystore_path: path, keystore_password: 'kspw', key_alias: 'a1', key_password: 'kpw' },
            env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          expect(creds.keystore_path).to eq(path)
          expect(creds.keystore_password).to eq('kspw')
          expect(creds.key_alias).to eq('a1')
          expect(creds.key_password).to eq('kpw')
          expect(creds.source).to eq(:flag)
        end
      end

      it 'defaults key_password to keystore_password when not given (Gradle convention)' do
        Dir.mktmpdir do |dir|
          path = write_jks(File.join(dir, 'release.jks'))
          creds = described_class.resolve_android_keystore(
            options: { keystore_path: path, keystore_password: 'shared', key_alias: 'a1' },
            env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
          expect(creds.key_password).to eq('shared')
        end
      end
    end

    describe 'tier 2 — env vars (CI convention)' do
      it 'reads MYSIGNER_KEYSTORE_* env names and stitches all four pieces, source :env' do
        Dir.mktmpdir do |dir|
          path = write_jks(File.join(dir, 'env.jks'))
          creds = described_class.resolve_android_keystore(
            options: {},
            env: env(
              'MYSIGNER_KEYSTORE_PATH' => path,
              'MYSIGNER_KEYSTORE_PASSWORD' => 'envpw',
              'MYSIGNER_KEY_ALIAS' => 'envalias',
              'MYSIGNER_KEY_PASSWORD' => 'envkeypw'
            ),
            stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          expect(creds.source).to eq(:env)
          expect(creds.keystore_path).to eq(path)
          expect(creds.keystore_password).to eq('envpw')
          expect(creds.key_alias).to eq('envalias')
          expect(creds.key_password).to eq('envkeypw')
        end
      end

      it 'falls back to ANDROID_KEYSTORE_* names when MYSIGNER_KEYSTORE_* are unset' do
        Dir.mktmpdir do |dir|
          path = write_jks(File.join(dir, 'env.jks'))
          creds = described_class.resolve_android_keystore(
            options: {},
            env: env(
              'ANDROID_KEYSTORE_PATH' => path,
              'ANDROID_KEYSTORE_PASSWORD' => 'a',
              'ANDROID_KEY_ALIAS' => 'b',
              'ANDROID_KEY_PASSWORD' => 'c'
            ),
            stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
          expect(creds.source).to eq(:env)
          expect(creds.keystore_password).to eq('a')
        end
      end

      # WHY: a flag must outrank env even when env has every piece — a user
      # passing --keystore-path on the command line is making an explicit
      # one-shot override that should not be silently shadowed by stale CI
      # vars in their shell.
      #
      # The MYSIGNER_KEY_PASSWORD => 'should-not-win' env var + --key-password
      # flag assertion locks the per-piece cascade: it is not enough that the
      # PATH comes from flag; every field the flag supplies must also win,
      # even when env supplies a competing value for that field. Without this,
      # a regression that overwrote flag fields with env ones (e.g. a future
      # refactor of `layer_android_piece!` that flipped the nil-check) would
      # silently pass the old, weaker assertion.
      it 'flag wins over env per-piece (path, password, alias, AND key_password)' do
        Dir.mktmpdir do |dir|
          env_path = write_jks(File.join(dir, 'env.jks'))
          flag_path = write_jks(File.join(dir, 'flag.jks'))
          creds = described_class.resolve_android_keystore(
            options: {
              keystore_path: flag_path, keystore_password: 'fpw',
              key_alias: 'fa', key_password: 'fkpw'
            },
            env: env(
              'MYSIGNER_KEYSTORE_PATH' => env_path,
              'MYSIGNER_KEYSTORE_PASSWORD' => 'epw',
              'MYSIGNER_KEY_ALIAS' => 'ea',
              'MYSIGNER_KEY_PASSWORD' => 'should-not-win'
            ),
            stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
          expect(creds.source).to eq(:flag)
          expect(creds.keystore_path).to eq(flag_path)
          expect(creds.keystore_password).to eq('fpw')
          expect(creds.key_alias).to eq('fa')
          expect(creds.key_password).to eq('fkpw')
          expect(creds.key_password).not_to eq('should-not-win')
        end
      end
    end

    describe 'tier 3 — Keychain' do
      def envelope(b64:, password: 'kspw', alias_: 'a1', key_pw: 'kpw')
        JSON.generate(
          'keystore_b64' => b64,
          'keystore_password' => password,
          'key_alias' => alias_,
          'key_password' => key_pw
        )
      end

      it 'returns single keychain entry, materializes .jks to tmpfile, source :keychain' do
        bytes = "FAKE_KEYSTORE_BYTES_\x00\x01".b
        b64 = Base64.strict_encode64(bytes)
        allow(Mysigner::LocalCredentials).to receive(:list)
          .with(kind: :android_keystore).and_return(['a1'])
        allow(Mysigner::LocalCredentials).to receive(:fetch)
          .with(kind: :android_keystore, id: 'a1')
          .and_return(envelope(b64: b64))

        Dir.mktmpdir do |dir|
          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          expect(creds.source).to eq(:keychain)
          expect(creds.keystore_password).to eq('kspw')
          expect(creds.key_alias).to eq('a1')
          expect(creds.key_password).to eq('kpw')
          # Tempfile materialized — file on disk with the decoded bytes.
          expect(File.exist?(creds.keystore_path)).to be true
          expect(File.binread(creds.keystore_path)).to eq(bytes)
          # Held on the Struct so GC doesn't unlink mid-build.
          expect(creds.tmpfile).not_to be_nil
        end
      end

      it 'raises AmbiguousCredentialsError mentioning --key-alias when multiple keychain entries exist' do
        allow(Mysigner::LocalCredentials).to receive(:list)
          .with(kind: :android_keystore).and_return(%w[debug release])

        Dir.mktmpdir do |dir|
          expect do
            described_class.resolve_android_keystore(
              options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
            )
          end.to raise_error(described_class::AmbiguousCredentialsError, /Multiple Android keystore.*--key-alias/)
        end
      end

      it 'picks the keychain entry matching --key-alias when multiple exist' do
        bytes = 'FAKE'.b
        b64 = Base64.strict_encode64(bytes)
        allow(Mysigner::LocalCredentials).to receive(:list)
          .with(kind: :android_keystore).and_return(%w[debug release])
        allow(Mysigner::LocalCredentials).to receive(:fetch)
          .with(kind: :android_keystore, id: 'release')
          .and_return(envelope(b64: b64, alias_: 'release'))

        Dir.mktmpdir do |dir|
          creds = described_class.resolve_android_keystore(
            options: { key_alias: 'release' }, env: env,
            stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
          expect(creds.source).to eq(:keychain)
          expect(creds.key_alias).to eq('release')
        end
      end

      it 'fails loud when the keychain envelope is missing keystore_b64' do
        allow(Mysigner::LocalCredentials).to receive(:list)
          .with(kind: :android_keystore).and_return(['a1'])
        allow(Mysigner::LocalCredentials).to receive(:fetch)
          .with(kind: :android_keystore, id: 'a1')
          .and_return(JSON.generate('keystore_password' => 'k', 'key_alias' => 'a'))

        Dir.mktmpdir do |dir|
          expect do
            described_class.resolve_android_keystore(
              options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
            )
          end.to raise_error(described_class::CredentialNotFoundError, /missing required `keystore_b64`/)
        end
      end
    end

    describe 'tier 4 — project sniff' do
      it 'reads android/key.properties (Flutter convention)' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'android'))
          jks_path = write_jks(File.join(dir, 'android', 'release.jks'))
          File.write(File.join(dir, 'android', 'key.properties'), <<~PROPS)
            # signing config
            storeFile=release.jks
            storePassword=propspw
            keyAlias=propsalias
            keyPassword=propskeypw
          PROPS

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          expect(creds.source).to eq(:disk)
          expect(creds.keystore_path).to eq(jks_path)
          expect(creds.keystore_password).to eq('propspw')
          expect(creds.key_alias).to eq('propsalias')
          expect(creds.key_password).to eq('propskeypw')
        end
      end

      it 'walks up parent directories (PROJECT_SNIFF_MAX_DEPTH) to find android/key.properties' do
        Dir.mktmpdir do |root|
          deep = File.join(root, 'apps', 'mobile')
          FileUtils.mkdir_p(File.join(root, 'android'))
          FileUtils.mkdir_p(deep)
          jks_path = write_jks(File.join(root, 'android', 'release.jks'))
          File.write(File.join(root, 'android', 'key.properties'), <<~PROPS)
            storeFile=release.jks
            storePassword=p
            keyAlias=k
          PROPS

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: deep
          )
          expect(creds.source).to eq(:disk)
          expect(creds.keystore_path).to eq(jks_path)
        end
      end

      it 'extracts credentials.android.keystore.* from eas.json (Expo convention)' do
        Dir.mktmpdir do |dir|
          jks_path = write_jks(File.join(dir, 'expo-release.jks'))
          File.write(File.join(dir, 'eas.json'), JSON.generate(
                                                   'credentials' => {
                                                     'android' => {
                                                       'keystore' => {
                                                         'keystorePath' => './expo-release.jks',
                                                         'keystorePassword' => 'epw',
                                                         'keyAlias' => 'ek',
                                                         'keyPassword' => 'ekpw'
                                                       }
                                                     }
                                                   }
                                                 ))

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
          expect(creds.source).to eq(:disk)
          expect(creds.keystore_path).to eq(jks_path)
          expect(creds.keystore_password).to eq('epw')
        end
      end

      # mysigner-22 Phase 7 follow-up: a literal quoted value like
      # `storePassword="my pw"` is valid `.properties` syntax (Android docs
      # and many Stack Overflow signing-config examples write it that way).
      # Before this fix, `parse_key_properties` did `value.strip` only — so
      # the 8-char string `"my pw"` (quotes included) flowed through to
      # apksigner, which rejected it as an incorrect password. This spec
      # locks in that single matching leading + trailing quote pairs (both
      # double and single) are stripped, mirroring the `prompt` helper.
      it 'strips surrounding quotes from key.properties values' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'android'))
          jks_path = write_jks(File.join(dir, 'android', 'release.jks'))
          File.write(File.join(dir, 'android', 'key.properties'), <<~PROPS)
            storeFile=release.jks
            storePassword="my-quoted-pw"
            keyAlias='single-quoted'
            keyPassword="another-quoted"
          PROPS

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          expect(creds.source).to eq(:disk)
          expect(creds.keystore_path).to eq(jks_path)
          expect(creds.keystore_password).to eq('my-quoted-pw')
          expect(creds.key_alias).to eq('single-quoted')
          expect(creds.key_password).to eq('another-quoted')
        end
      end

      it 'falls through past a key.properties whose storeFile points at a missing path' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'android'))
          File.write(File.join(dir, 'android', 'key.properties'), <<~PROPS)
            storeFile=nonexistent.jks
            storePassword=p
            keyAlias=k
          PROPS

          # No fallback found → non-TTY → CredentialNotFoundError.
          expect do
            described_class.resolve_android_keystore(
              options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
            )
          end.to raise_error(described_class::CredentialNotFoundError)
        end
      end
    end

    describe 'partial-cascade stitching' do
      # WHY: real users will have a key.properties on disk with paths but
      # not passwords (committing passwords to git is a bad idea), and the
      # CI runner supplies passwords via env. The cascade has to merge
      # those two tiers — not pick one wholesale.
      it 'reads path from sniff but layers env-supplied passwords on top' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'android'))
          jks_path = write_jks(File.join(dir, 'android', 'release.jks'))
          File.write(File.join(dir, 'android', 'key.properties'), <<~PROPS)
            storeFile=release.jks
            keyAlias=propsalias
          PROPS

          creds = described_class.resolve_android_keystore(
            options: {},
            env: env(
              'MYSIGNER_KEYSTORE_PASSWORD' => 'env-supplied',
              'MYSIGNER_KEY_PASSWORD' => 'env-key-supplied'
            ),
            stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          # Path attribution → :env wins because env is the highest tier
          # to supply ANYTHING; but the path itself came from sniff.
          # Actually, no — `source` follows the path's tier. The path came
          # from disk, so source is :disk; env merely filled in passwords.
          expect(creds.keystore_path).to eq(jks_path)
          expect(creds.key_alias).to eq('propsalias')
          expect(creds.keystore_password).to eq('env-supplied')
          expect(creds.key_password).to eq('env-key-supplied')
        end
      end
    end

    describe 'tier 5 — interactive prompt (TTY only)' do
      it 'prompts for missing pieces when stdin is a TTY' do
        Dir.mktmpdir do |dir|
          jks_path = write_jks(File.join(dir, 'p.jks'))
          tty = instance_double(IO, tty?: true)
          # path → keystore_password → key_password (Enter = reuse) → alias.
          # Empty key_password input preserves the "key_password defaults to
          # keystore_password" Gradle convention covered below.
          allow(tty).to receive(:gets).and_return("#{jks_path}\n", "prompted-pw\n", "\n", "prompted-alias\n")

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: tty, stderr: stderr, cwd: dir
          )

          expect(creds.source).to eq(:prompt)
          expect(creds.keystore_path).to eq(jks_path)
          expect(creds.keystore_password).to eq('prompted-pw')
          expect(creds.key_alias).to eq('prompted-alias')
          expect(creds.key_password).to eq('prompted-pw') # defaulted via Enter
        end
      end

      # mysigner-22 Phase 7 follow-up: before this fix, `android_missing_pieces`
      # excluded :key_password ("defaults to keystore_password") AND the prompt
      # path never asked for it — so a user with a distinct key password who
      # forgot --key-password and ran interactively got a silent fuse to
      # keystore_password and a downstream apksigner "incorrect key password"
      # failure with no hint. This spec locks in that the prompt path asks
      # for a distinct key_password and respects it when supplied.
      it 'prompts for a distinct key_password after keystore_password and uses it when given' do
        Dir.mktmpdir do |dir|
          jks_path = write_jks(File.join(dir, 'p.jks'))
          tty = instance_double(IO, tty?: true)
          # path → keystore_password → key_password (non-empty) → alias.
          allow(tty).to receive(:gets).and_return(
            "#{jks_path}\n", "store-pw\n", "distinct-key-pw\n", "alias-x\n"
          )

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: tty, stderr: stderr, cwd: dir
          )

          expect(creds.keystore_password).to eq('store-pw')
          expect(creds.key_password).to eq('distinct-key-pw')
          expect(creds.key_password).not_to eq(creds.keystore_password)
        end
      end

      # Inverse: empty input (the user pressed Enter at the key_password
      # prompt) preserves the long-standing Gradle convention of reusing the
      # keystore password. The final `||` defaulting in resolve_android_keystore
      # must still kick in — guarding against a regression where an empty
      # string from prompt overwrites the fallback path.
      it 'defaults key_password to keystore_password when prompt input is empty' do
        Dir.mktmpdir do |dir|
          jks_path = write_jks(File.join(dir, 'p.jks'))
          tty = instance_double(IO, tty?: true)
          # Empty key_password input — Enter pressed to reuse.
          allow(tty).to receive(:gets).and_return(
            "#{jks_path}\n", "shared-pw\n", "\n", "alias-y\n"
          )

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: tty, stderr: stderr, cwd: dir
          )

          expect(creds.keystore_password).to eq('shared-pw')
          expect(creds.key_password).to eq('shared-pw')
        end
      end

      it 'NEVER prompts when STDIN is not a TTY (CI safety — Rule 12, fail loud)' do
        no_tty = instance_double(IO, tty?: false)
        expect(no_tty).not_to receive(:gets)

        Dir.mktmpdir do |dir|
          expect do
            described_class.resolve_android_keystore(
              options: {}, env: env, stdin: no_tty, stderr: stderr, cwd: dir
            )
          end.to raise_error(described_class::CredentialNotFoundError)
        end
      end
    end

    describe 'CredentialNotFoundError message names every source tried + override knobs' do
      it 'lists --keystore-path, MYSIGNER_KEYSTORE_PATH, onboard, key.properties' do
        Dir.mktmpdir do |dir|
          described_class.resolve_android_keystore(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )
        rescue described_class::CredentialNotFoundError => e
          msg = e.message
          expect(msg).to include('--keystore-path')
          expect(msg).to include('--key-alias')
          expect(msg).to include('MYSIGNER_KEYSTORE_PATH')
          expect(msg).to include('ANDROID_KEYSTORE_PATH')
          expect(msg).to include('mysigner onboard --local-only')
          expect(msg).to include('key.properties')
          expect(msg).to include('eas.json')
          expect(msg).to match(/Tried in order/)
        else
          raise 'expected CredentialNotFoundError'
        end
      end
    end

    # mysigner-22 Phase 7 follow-up — extra Android Studio conventions.
    # Two new project-sniff sub-tiers:
    #   * inline signingConfigs.release in android/app/build.gradle[.kts]
    #   * ~/.gradle/gradle.properties with PREFIX_STORE_FILE / _PASSWORD / etc.
    # WHY each spec exists: each tier is a real user setup the pre-follow-up
    # resolver silently failed on, forcing them to set --keystore-path by
    # hand. The cascade ordering specs lock in that adding these tiers can
    # NEVER regress the higher-priority key.properties/eas.json paths.
    describe 'tier 4 — project sniff — android/app/build.gradle (Groovy DSL)' do
      def write_jks(path, content: "FAKE\x00JKS\x01BYTES".b)
        File.binwrite(path, content)
        path
      end

      it 'extracts literal signingConfigs.release fields from android/app/build.gradle' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'android', 'app'))
          jks_path = write_jks(File.join(dir, 'android', 'app', 'release.jks'))
          File.write(File.join(dir, 'android', 'app', 'build.gradle'), <<~GRADLE)
            android {
                signingConfigs {
                    debug {
                        storeFile file("debug.jks")
                    }
                    release {
                        storeFile file("release.jks")
                        storePassword "groovy-pw"
                        keyAlias "upload-groovy"
                        keyPassword "groovy-key-pw"
                    }
                }
                buildTypes {
                    release { signingConfig signingConfigs.release }
                }
            }
          GRADLE

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          expect(creds.source).to eq(:disk)
          expect(creds.keystore_path).to eq(jks_path)
          expect(creds.keystore_password).to eq('groovy-pw')
          expect(creds.key_alias).to eq('upload-groovy')
          expect(creds.key_password).to eq('groovy-key-pw')
        end
      end

      # Locks in: we must NEVER try to evaluate Groovy. A release block whose
      # password / alias values are all `System.getenv(...)` calls returns
      # nothing for those fields from this tier — the env tier (or prompt)
      # fills them. Without this guard the resolver would either silently set
      # `nil` strings (which apksigner rejects with cryptic errors) or, worse,
      # persist the literal Groovy source text (e.g. `System.getenv("FOO")`)
      # as if it were a password.
      it 'skips System.getenv password / alias references and lets env tier fill them' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'android', 'app'))
          jks_path = write_jks(File.join(dir, 'android', 'app', 'release.jks'))
          # storeFile gets a plain literal so the path is sniffed from the
          # gradle file; the other three fields are all System.getenv calls
          # that the regex MUST refuse to capture as literals.
          File.write(File.join(dir, 'android', 'app', 'build.gradle'), <<~GRADLE)
            android {
                signingConfigs {
                    release {
                        storeFile file("release.jks")
                        storePassword System.getenv("MYAPP_RELEASE_STORE_PASSWORD")
                        keyAlias System.getenv("MYAPP_RELEASE_KEY_ALIAS")
                        keyPassword System.getenv("MYAPP_RELEASE_KEY_PASSWORD")
                    }
                }
            }
          GRADLE

          creds = described_class.resolve_android_keystore(
            options: {},
            env: env(
              'MYSIGNER_KEYSTORE_PASSWORD' => 'env-pw',
              'MYSIGNER_KEY_ALIAS' => 'env-alias',
              'MYSIGNER_KEY_PASSWORD' => 'env-key-pw'
            ),
            stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          # Path: literal from build.gradle (disk tier).
          # Passwords/alias: env tier (build.gradle had only System.getenv refs).
          expect(creds.keystore_path).to eq(jks_path)
          expect(creds.keystore_password).to eq('env-pw')
          expect(creds.key_alias).to eq('env-alias')
          expect(creds.key_password).to eq('env-key-pw')
          # And — critically — none of the resolved values are Groovy source.
          expect(creds.keystore_password).not_to include('System.getenv')
          expect(creds.key_alias).not_to include('System.getenv')
          expect(creds.key_password).not_to include('System.getenv')
        end
      end
    end

    describe 'tier 4 — project sniff — android/app/build.gradle.kts (Kotlin DSL)' do
      def write_jks(path, content: "FAKE\x00JKS\x01BYTES".b)
        File.binwrite(path, content)
        path
      end

      it 'extracts literal signingConfigs.release fields from android/app/build.gradle.kts' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'android', 'app'))
          jks_path = write_jks(File.join(dir, 'android', 'app', 'release.jks'))
          File.write(File.join(dir, 'android', 'app', 'build.gradle.kts'), <<~GRADLE)
            android {
                signingConfigs {
                    create("release") {
                        storeFile = file("release.jks")
                        storePassword = "kotlin-pw"
                        keyAlias = "upload-kotlin"
                        keyPassword = "kotlin-key-pw"
                    }
                }
            }
          GRADLE

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          expect(creds.source).to eq(:disk)
          expect(creds.keystore_path).to eq(jks_path)
          expect(creds.keystore_password).to eq('kotlin-pw')
          expect(creds.key_alias).to eq('upload-kotlin')
          expect(creds.key_password).to eq('kotlin-key-pw')
        end
      end
    end

    describe 'tier 4 — project sniff — cascade priority within project tier' do
      def write_jks(path, content: "FAKE\x00JKS\x01BYTES".b)
        File.binwrite(path, content)
        path
      end

      # WHY this spec exists: the sniff ordering inside the project tier is a
      # contract. Within one directory, key.properties must win over
      # build.gradle — many Studio templates write both (the gradle file loads
      # `keystoreProperties[...]`), and key.properties is the canonical
      # source of truth. Reversing the order would silently pick a stale
      # placeholder out of build.gradle on real projects.
      it 'key.properties wins over build.gradle when both are present in the same dir' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'android', 'app'))
          kp_jks = write_jks(File.join(dir, 'android', 'kp-release.jks'))
          write_jks(File.join(dir, 'android', 'app', 'gradle-release.jks'))

          File.write(File.join(dir, 'android', 'key.properties'), <<~PROPS)
            storeFile=kp-release.jks
            storePassword=kp-pw
            keyAlias=kp-alias
            keyPassword=kp-key-pw
          PROPS

          File.write(File.join(dir, 'android', 'app', 'build.gradle'), <<~GRADLE)
            android {
                signingConfigs {
                    release {
                        storeFile file("gradle-release.jks")
                        storePassword "gradle-pw"
                        keyAlias "gradle-alias"
                        keyPassword "gradle-key-pw"
                    }
                }
            }
          GRADLE

          creds = described_class.resolve_android_keystore(
            options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
          )

          expect(creds.keystore_path).to eq(kp_jks)
          expect(creds.keystore_password).to eq('kp-pw')
          expect(creds.key_alias).to eq('kp-alias')
          expect(creds.key_password).to eq('kp-key-pw')
        end
      end
    end

    describe 'tier 4 — project sniff — ~/.gradle/gradle.properties (per-user fallback)' do
      def write_jks(path, content: "FAKE\x00JKS\x01BYTES".b)
        File.binwrite(path, content)
        path
      end

      it 'extracts a single full-prefix set (MYAPP_RELEASE_*) when project-local sources are absent' do
        Dir.mktmpdir do |gradle_home|
          jks_path = write_jks(File.join(gradle_home, 'release.jks'))
          gradle_props_path = File.join(gradle_home, 'gradle.properties')
          File.write(gradle_props_path, <<~PROPS)
            # Per-user signing config (Android docs convention)
            MYAPP_RELEASE_STORE_FILE=#{jks_path}
            MYAPP_RELEASE_STORE_PASSWORD=gradle-props-pw
            MYAPP_RELEASE_KEY_ALIAS=upload
            MYAPP_RELEASE_KEY_PASSWORD=gradle-props-key-pw
          PROPS

          # Override the global stub: this is the spec that exercises it.
          allow(File).to receive(:exist?).with(@real_expand_path.call('~/.gradle/gradle.properties')).and_return(true)
          allow(File).to receive(:expand_path)
            .with('~/.gradle/gradle.properties').and_return(gradle_props_path)

          Dir.mktmpdir do |project_dir|
            creds = described_class.resolve_android_keystore(
              options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: project_dir
            )

            expect(creds.source).to eq(:disk)
            expect(creds.keystore_path).to eq(jks_path)
            expect(creds.keystore_password).to eq('gradle-props-pw')
            expect(creds.key_alias).to eq('upload')
            expect(creds.key_password).to eq('gradle-props-key-pw')
          end
        end
      end

      it 'raises AmbiguousCredentialsError when multiple prefixes have full sets' do
        Dir.mktmpdir do |gradle_home|
          jks_a = write_jks(File.join(gradle_home, 'a.jks'))
          jks_b = write_jks(File.join(gradle_home, 'b.jks'))
          gradle_props_path = File.join(gradle_home, 'gradle.properties')
          File.write(gradle_props_path, <<~PROPS)
            MYAPP_RELEASE_STORE_FILE=#{jks_a}
            MYAPP_RELEASE_STORE_PASSWORD=a-pw
            MYAPP_RELEASE_KEY_ALIAS=a-alias
            MYAPP_RELEASE_KEY_PASSWORD=a-key-pw
            OTHER_RELEASE_STORE_FILE=#{jks_b}
            OTHER_RELEASE_STORE_PASSWORD=b-pw
            OTHER_RELEASE_KEY_ALIAS=b-alias
            OTHER_RELEASE_KEY_PASSWORD=b-key-pw
          PROPS

          allow(File).to receive(:exist?).with(@real_expand_path.call('~/.gradle/gradle.properties')).and_return(true)
          allow(File).to receive(:expand_path)
            .with('~/.gradle/gradle.properties').and_return(gradle_props_path)

          Dir.mktmpdir do |project_dir|
            expect do
              described_class.resolve_android_keystore(
                options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: project_dir
              )
            end.to raise_error(
              described_class::AmbiguousCredentialsError,
              /Multiple Android keystore prefixes.*MYAPP_RELEASE.*OTHER_RELEASE.*--key-alias/m
            )
          end
        end
      end

      # WHY partial sets don't raise: a real ~/.gradle/gradle.properties may
      # contain dozens of unrelated keys including incomplete signing
      # remnants from old projects. Raising on partials would force users
      # to clean up unrelated cruft before mysigner runs. Skipping silently
      # lets the cascade fall through to prompt / fail-loud-with-knobs.
      it 'skips silently when only a partial set is present (no _KEY_ALIAS / _KEY_PASSWORD)' do
        Dir.mktmpdir do |gradle_home|
          gradle_props_path = File.join(gradle_home, 'gradle.properties')
          File.write(gradle_props_path, <<~PROPS)
            MYAPP_RELEASE_STORE_FILE=/path/that/does/not/matter.jks
            MYAPP_RELEASE_STORE_PASSWORD=partial-pw
            # NOTE: alias + key_password intentionally missing
          PROPS

          allow(File).to receive(:exist?).with(@real_expand_path.call('~/.gradle/gradle.properties')).and_return(true)
          allow(File).to receive(:expand_path)
            .with('~/.gradle/gradle.properties').and_return(gradle_props_path)

          Dir.mktmpdir do |project_dir|
            # No project-local sources + partial gradle.properties + non-TTY →
            # fall through to fail-loud. Specifically: no AmbiguousCredentialsError.
            expect do
              described_class.resolve_android_keystore(
                options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: project_dir
              )
            end.to raise_error(described_class::CredentialNotFoundError)
          end
        end
      end

      # WHY this spec exists: the gradle.properties tier is a PER-USER
      # fallback, not a project-local source. If the project's own
      # key.properties supplies everything, gradle.properties must NEVER
      # silently override — that's exactly the kind of cross-project
      # contamination users get bitten by when they have multiple Android
      # projects sharing one machine.
      it 'does NOT consult gradle.properties when project-local key.properties supplies all fields' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'android'))
          kp_jks = write_jks(File.join(dir, 'android', 'kp.jks'))
          File.write(File.join(dir, 'android', 'key.properties'), <<~PROPS)
            storeFile=kp.jks
            storePassword=kp-pw
            keyAlias=kp-alias
            keyPassword=kp-key-pw
          PROPS

          # If gradle.properties were consulted, this would raise (multiple
          # prefixes with full sets). The expectation is that it is NOT
          # consulted — so no raise, and key.properties values win.
          Dir.mktmpdir do |gradle_home|
            gradle_props_path = File.join(gradle_home, 'gradle.properties')
            File.write(gradle_props_path, <<~PROPS)
              MYAPP_RELEASE_STORE_FILE=/some.jks
              MYAPP_RELEASE_STORE_PASSWORD=ambig-a
              MYAPP_RELEASE_KEY_ALIAS=a
              MYAPP_RELEASE_KEY_PASSWORD=a
              OTHER_RELEASE_STORE_FILE=/some.jks
              OTHER_RELEASE_STORE_PASSWORD=ambig-b
              OTHER_RELEASE_KEY_ALIAS=b
              OTHER_RELEASE_KEY_PASSWORD=b
            PROPS

            allow(File).to receive(:exist?).with(@real_expand_path.call('~/.gradle/gradle.properties')).and_return(true)
            allow(File).to receive(:expand_path)
              .with('~/.gradle/gradle.properties').and_return(gradle_props_path)

            creds = described_class.resolve_android_keystore(
              options: {}, env: env, stdin: no_tty_stdin, stderr: stderr, cwd: dir
            )

            expect(creds.keystore_path).to eq(kp_jks)
            expect(creds.keystore_password).to eq('kp-pw')
            expect(creds.key_alias).to eq('kp-alias')
            expect(creds.key_password).to eq('kp-key-pw')
          end
        end
      end
    end
  end
end
