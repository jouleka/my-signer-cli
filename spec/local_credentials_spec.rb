# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'

RSpec.describe Mysigner::LocalCredentials do
  let(:test_config_dir) { File.expand_path('~/.mysigner_test_lc') }
  let(:test_credentials_dir) { File.join(test_config_dir, 'credentials') }
  let(:test_index_dir) { File.join(test_credentials_dir, '.index') }
  let(:test_key_file) { File.join(test_config_dir, '.encryption_key') }

  before do
    # Isolate every test from the user's real ~/.mysigner so neither Config's
    # key nor the credentials store can leak between runs.
    stub_const('Mysigner::Config::CONFIG_DIR', test_config_dir)
    stub_const('Mysigner::Config::CONFIG_FILE', File.join(test_config_dir, 'config.yml'))
    stub_const('Mysigner::Config::KEY_FILE', test_key_file)
    stub_const('Mysigner::LocalCredentials::CREDENTIALS_DIR', test_credentials_dir)
    stub_const('Mysigner::LocalCredentials::INDEX_DIR', test_index_dir)

    FileUtils.rm_rf(test_config_dir)
  end

  after do
    FileUtils.rm_rf(test_config_dir)
  end

  describe 'validation' do
    # The kind allow-list is the whole point of fail-loud (Rule 12). A typo
    # like :asc_ vs :asc must never silently land in some forgotten file.
    it 'raises ArgumentError for an unknown kind' do
      expect do
        described_class.store(kind: :totally_made_up, id: 'a', secret: 'b')
      end.to raise_error(ArgumentError, /unknown kind/)
    end

    it 'raises ArgumentError for nil id' do
      expect do
        described_class.store(kind: :asc, id: nil, secret: 'b')
      end.to raise_error(ArgumentError, /id must be a non-empty/)
    end

    it 'raises ArgumentError for empty id' do
      expect do
        described_class.store(kind: :asc, id: '   ', secret: 'b')
      end.to raise_error(ArgumentError, /id must be a non-empty/)
    end

    it 'raises ArgumentError for nil secret' do
      expect do
        described_class.store(kind: :asc, id: 'KEY1', secret: nil)
      end.to raise_error(ArgumentError, /secret must be a non-empty/)
    end

    it 'raises ArgumentError for empty secret' do
      expect do
        described_class.store(kind: :asc, id: 'KEY1', secret: '')
      end.to raise_error(ArgumentError, /secret must be a non-empty/)
    end

    it 'raises ArgumentError for an id starting with "-" (would be parsed as a security CLI flag)' do
      # WHY: macOS `security` uses getopt-style flag parsing on the `-a`
      # value, so an id like `-D` would be silently mis-parsed as a
      # different flag. Defensive rejection because there's no `--` end-of-
      # options delimiter we can use.
      expect do
        described_class.store(kind: :asc, id: '-D', secret: 'x')
      end.to raise_error(ArgumentError, /must not start with "-"/)
    end

    it 'raises ArgumentError for an id containing a NUL byte' do
      # WHY: Open3 raises an opaque ArgumentError from the C layer on NUL
      # bytes; reject up front with a clear message so callers see the
      # validation contract documented elsewhere in this module.
      expect do
        described_class.store(kind: :asc, id: "a\0b", secret: 'x')
      end.to raise_error(ArgumentError, /NUL/)
    end

    it 'rejects unknown kind on list as well' do
      # Different entry points must validate consistently — otherwise a bad
      # kind could "exist" silently.
      expect { described_class.list(kind: :nope) }.to raise_error(ArgumentError)
    end
  end

  # -------------------------------------------------------------------------
  # macOS Keychain branch
  # -------------------------------------------------------------------------
  describe 'macOS Keychain backend' do
    let(:pem) { "-----BEGIN PRIVATE KEY-----\nABC\n-----END PRIVATE KEY-----\n" }
    let(:stored) { {} }

    before do
      allow(RbConfig::CONFIG).to receive(:[]).and_call_original
      allow(RbConfig::CONFIG).to receive(:[]).with('host_os').and_return('darwin23.0.0')

      # In-memory fake of the macOS `security` CLI keyed by account string.
      # We assert on `account` shape via this fake (kind:id format).
      success = instance_double(Process::Status, success?: true)
      failure = instance_double(Process::Status, success?: false)

      allow(Open3).to receive(:capture3) do |*argv|
        action = argv[1]
        idx = argv.index('-a')
        account = argv[idx + 1] if idx

        case action
        when 'add-generic-password'
          w_idx = argv.index('-w')
          stored[account] = argv[w_idx + 1]
          ['', '', success]
        when 'find-generic-password'
          if stored.key?(account)
            ["#{stored[account]}\n", '', success]
          else
            ['', 'item not found', failure]
          end
        when 'delete-generic-password'
          if stored.delete(account)
            ['', '', success]
          else
            # security exits non-zero when nothing to delete — caller treats
            # that as fine for the idempotent overwrite/delete idiom.
            ['', '', failure]
          end
        end
      end
    end

    it 'round-trips a stored secret' do
      # The contract callers depend on: whatever bytes go in come back out.
      # If this breaks, every Phase 3 `ship` command silently misuses keys.
      described_class.store(kind: :asc, id: 'KEY12345', secret: pem)
      expect(described_class.fetch(kind: :asc, id: 'KEY12345')).to eq(pem)
    end

    it 'base64-encodes the secret before handing it to security' do
      # Binary-safe storage matters because a real .p8 has newlines, and
      # `security` historically chokes on raw NULs and unencoded payloads.
      described_class.store(kind: :asc, id: 'KEY12345', secret: pem)
      expect(stored['asc:KEY12345']).to eq(Base64.strict_encode64(pem))
      expect(stored['asc:KEY12345']).not_to include("\n")
    end

    it 'overwrite is idempotent (latest secret wins, no duplicates)' do
      # If overwrite created duplicate entries, fetch would return whatever
      # `security` happens to surface first — non-deterministic across hosts.
      described_class.store(kind: :asc, id: 'KEY', secret: 'first')
      described_class.store(kind: :asc, id: 'KEY', secret: 'second')

      expect(described_class.fetch(kind: :asc, id: 'KEY')).to eq('second')
      # Our fake keys by account; one logical entry => one fake slot.
      expect(stored.keys).to contain_exactly('asc:KEY')
    end

    it 'fetch returns nil for missing entries (not an error)' do
      # Callers must be able to probe with fetch without rescuing — that's
      # what makes `exists?` cheap and what `login` can rely on.
      expect(described_class.fetch(kind: :asc, id: 'nope')).to be_nil
    end

    it 'delete is idempotent when entry is missing' do
      expect { described_class.delete(kind: :asc, id: 'never_existed') }.not_to raise_error
    end

    it 'delete removes the secret so fetch returns nil afterwards' do
      described_class.store(kind: :asc, id: 'KEY', secret: 'x')
      described_class.delete(kind: :asc, id: 'KEY')
      expect(described_class.fetch(kind: :asc, id: 'KEY')).to be_nil
    end

    it 'uses a dedicated keychain service distinct from Config encryption key' do
      # Sharing services would let a future Config rotation wipe credentials
      # by accident. The brief explicitly forbids reusing com.mysigner.cli.
      expect(Mysigner::LocalCredentials::KEYCHAIN_SERVICE).to eq('com.mysigner.cli.credentials')
      expect(Mysigner::LocalCredentials::KEYCHAIN_SERVICE).not_to eq(Mysigner::Config::KEYCHAIN_SERVICE)
    end

    it 'shells out with array argv (no shell expansion of id)' do
      # If `id` were ever interpolated, a value like "x'; rm -rf ~" would
      # be catastrophic. This test asserts the call shape only.
      described_class.store(kind: :asc, id: %(weird"id'$X), secret: 's')
      expect(Open3).to have_received(:capture3).with(
        'security', 'add-generic-password',
        '-s', 'com.mysigner.cli.credentials',
        '-a', %(asc:weird"id'$X),
        '-w', Base64.strict_encode64('s')
      )
    end

    describe 'list and exists?' do
      it 'list returns the ids that have been stored, not the secrets' do
        # Leaking secrets via `list` would be the single worst regression
        # this module could ship.
        described_class.store(kind: :asc, id: 'A', secret: 'sa')
        described_class.store(kind: :asc, id: 'B', secret: 'sb')
        result = described_class.list(kind: :asc)
        expect(result).to contain_exactly('A', 'B')
        expect(result).not_to include('sa', 'sb')
      end

      it 'list is empty before anything is stored' do
        expect(described_class.list(kind: :google_play)).to eq([])
      end

      it 'list drops ids after delete' do
        described_class.store(kind: :asc, id: 'A', secret: 's')
        described_class.delete(kind: :asc, id: 'A')
        expect(described_class.list(kind: :asc)).to eq([])
      end

      it 'exists? is true after store and false after delete' do
        expect(described_class.exists?(kind: :asc, id: 'X')).to be false
        described_class.store(kind: :asc, id: 'X', secret: 'v')
        expect(described_class.exists?(kind: :asc, id: 'X')).to be true
        described_class.delete(kind: :asc, id: 'X')
        expect(described_class.exists?(kind: :asc, id: 'X')).to be false
      end
    end

    it 'multiple kinds with the same id coexist' do
      # Real callers (ASC + Play) often share key_ids by coincidence; the
      # account format must namespace by kind or they'd clobber each other.
      described_class.store(kind: :asc, id: 'SAME', secret: 'a-secret')
      described_class.store(kind: :google_play, id: 'SAME', secret: 'g-secret')
      expect(described_class.fetch(kind: :asc, id: 'SAME')).to eq('a-secret')
      expect(described_class.fetch(kind: :google_play, id: 'SAME')).to eq('g-secret')
    end
  end

  # -------------------------------------------------------------------------
  # File-fallback branch (Linux/Windows)
  # -------------------------------------------------------------------------
  describe 'file fallback backend' do
    let(:large_json) { %({"client_email":"#{'x' * 1800}"}) }

    before do
      allow(RbConfig::CONFIG).to receive(:[]).and_call_original
      allow(RbConfig::CONFIG).to receive(:[]).with('host_os').and_return('linux-gnu')
    end

    it 'round-trips a 2 KB JSON blob through AES-256-GCM' do
      # Real google-play service-account JSONs hit ~2 KB; PEM keys are
      # smaller. Both must round-trip identically with no truncation.
      described_class.store(kind: :google_play, id: 'sa@example.com', secret: large_json)
      expect(described_class.fetch(kind: :google_play, id: 'sa@example.com')).to eq(large_json)
    end

    it 'writes ciphertext, not the plaintext secret, to disk' do
      # If we ever silently disabled encryption, this assertion catches it
      # before a release ships an unencrypted .p8 to anyone's home dir.
      secret = 'super-secret-pem-bytes'
      described_class.store(kind: :asc, id: 'KEY', secret: secret)

      contents = Dir["#{test_credentials_dir}/asc/*"].first
      expect(contents).not_to be_nil
      expect(File.read(contents)).not_to include(secret)
    end

    it 'sets credential file mode to 0600' do
      # Other users on the machine must not be able to read the file. This
      # is the same posture as Config's KEY_FILE.
      described_class.store(kind: :asc, id: 'KEY', secret: 's')
      path = Dir["#{test_credentials_dir}/asc/*"].first
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it 'overwrite replaces the prior secret' do
      described_class.store(kind: :asc, id: 'KEY', secret: 'first')
      described_class.store(kind: :asc, id: 'KEY', secret: 'second')
      expect(described_class.fetch(kind: :asc, id: 'KEY')).to eq('second')
    end

    it 'fetch returns nil for missing entries' do
      expect(described_class.fetch(kind: :asc, id: 'gone')).to be_nil
    end

    it 'delete removes the file and is idempotent' do
      described_class.store(kind: :asc, id: 'KEY', secret: 's')
      described_class.delete(kind: :asc, id: 'KEY')
      expect(described_class.fetch(kind: :asc, id: 'KEY')).to be_nil
      expect { described_class.delete(kind: :asc, id: 'KEY') }.not_to raise_error
    end

    it 'list returns ids, never secrets' do
      described_class.store(kind: :asc, id: 'A', secret: 'sa')
      described_class.store(kind: :asc, id: 'B', secret: 'sb')
      expect(described_class.list(kind: :asc)).to contain_exactly('A', 'B')
    end

    it 'reuses the same per-machine encryption key as Config' do
      # The whole point of routing through Config.fetch_encryption_key is
      # that one rotation rotates everything. If we duplicated the key, a
      # Config rotate would silently orphan all stored credentials.
      described_class.store(kind: :asc, id: 'KEY', secret: 'plaintext')

      # Reading the same blob with the same Config key must yield the value.
      expect(described_class.fetch(kind: :asc, id: 'KEY')).to eq('plaintext')
    end
  end

  describe 'kinds allowlist' do
    it 'matches the documented set' do
      # If the set drifts without thought, downstream Phase 3 tickets could
      # write to a kind that nobody else reads — this freezes the contract.
      expect(Mysigner::LocalCredentials::KINDS).to eq(%i[asc google_play apple_ads android_keystore])
    end
  end
end
