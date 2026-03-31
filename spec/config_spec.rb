# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'

RSpec.describe Mysigner::Config do
  let(:test_config_dir) { File.expand_path('~/.mysigner_test') }
  let(:test_config_file) { File.join(test_config_dir, 'config.yml') }

  before do
    # Stub the constants to use test directory
    stub_const('Mysigner::Config::CONFIG_DIR', test_config_dir)
    stub_const('Mysigner::Config::CONFIG_FILE', test_config_file)

    # Clean up test directory
    FileUtils.rm_rf(test_config_dir)
  end

  after do
    # Clean up after tests
    FileUtils.rm_rf(test_config_dir)
  end

  describe '#initialize' do
    it 'creates a new config with nil values' do
      config = Mysigner::Config.new
      expect(config.api_url).to be_nil
      expect(config.api_token).to be_nil
      expect(config.current_organization_id).to be_nil
      expect(config.organizations).to eq({})
    end

    it 'loads existing config if file exists (new format)' do
      FileUtils.mkdir_p(test_config_dir)
      File.write(test_config_file, {
        'api_url' => 'http://localhost:3000',
        'user_email' => 'test@example.com',
        'current_organization_id' => 1,
        'organizations' => {
          '1' => { 'name' => 'Test Org', 'token' => 'test_token' }
        }
      }.to_yaml)

      config = Mysigner::Config.new
      expect(config.api_url).to eq('http://localhost:3000')
      expect(config.user_email).to eq('test@example.com')
      expect(config.api_token).to eq('test_token')
      expect(config.current_organization_id).to eq(1)
    end
  end

  describe '#save' do
    it "creates config directory if it doesn't exist" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Test Org', 'test_token')
      config.save

      expect(Dir.exist?(test_config_dir)).to be true
    end

    it 'saves configuration to file in new format' do
      config = Mysigner::Config.new
      config.encryption_enabled = false  # Disable encryption for this test
      config.api_url = 'http://localhost:3000'
      config.user_email = 'test@example.com'
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Test Org', 'test_token')
      config.save

      expect(File.exist?(test_config_file)).to be true

      data = YAML.load_file(test_config_file)
      expect(data['api_url']).to eq('http://localhost:3000')
      expect(data['user_email']).to eq('test@example.com')
      expect(data['current_organization_id']).to eq(1)
      expect(data['organizations']).to eq({
                                            '1' => { 'name' => 'Test Org', 'token' => 'test_token' }
                                          })
    end

    it 'saves multiple organizations' do
      config = Mysigner::Config.new
      config.encryption_enabled = false  # Disable encryption for this test
      config.api_url = 'http://localhost:3000'
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Org 1', 'token1')
      config.save_token_for_org(2, 'Org 2', 'token2')
      config.save_token_for_org(3, 'Org 3', 'token3')
      config.save

      data = YAML.load_file(test_config_file)
      expect(data['organizations'].keys.sort).to eq(%w[1 2 3])
      expect(data['organizations']['1']['token']).to eq('token1')
      expect(data['organizations']['2']['token']).to eq('token2')
      expect(data['organizations']['3']['token']).to eq('token3')
    end

    it 'sets file permissions to 0600' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.save

      file_mode = File.stat(test_config_file).mode.to_s(8)[-3..]
      expect(file_mode).to eq('600')
    end
  end

  describe '#load' do
    it "returns false if config file doesn't exist" do
      config = Mysigner::Config.new
      expect(config.load).to be false
    end

    it 'loads configuration from file (new format)' do
      FileUtils.mkdir_p(test_config_dir)
      File.write(test_config_file, {
        'api_url' => 'http://example.com',
        'user_email' => 'user@example.com',
        'current_organization_id' => 42,
        'organizations' => {
          '42' => { 'name' => 'My Org', 'token' => 'secret_token' }
        }
      }.to_yaml)

      config = Mysigner::Config.new
      config.load

      expect(config.api_url).to eq('http://example.com')
      expect(config.user_email).to eq('user@example.com')
      expect(config.api_token(42)).to eq('secret_token')
      expect(config.current_organization_id).to eq(42)
    end
  end

  describe '#clear' do
    it 'clears all config values' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.user_email = 'test@example.com'
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Test Org', 'test_token')
      config.clear

      expect(config.api_url).to be_nil
      expect(config.user_email).to be_nil
      expect(config.api_token).to be_nil
      expect(config.current_organization_id).to be_nil
      expect(config.organizations).to eq({})
    end

    it 'deletes config file if it exists' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.save

      expect(File.exist?(test_config_file)).to be true

      config.clear
      expect(File.exist?(test_config_file)).to be false
    end
  end

  describe '#exists?' do
    it "returns false when config file doesn't exist" do
      config = Mysigner::Config.new
      expect(config.exists?).to be false
    end

    it 'returns true when config file exists' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.save

      expect(config.exists?).to be true
    end
  end

  describe '#valid?' do
    it 'returns false when api_url is nil' do
      config = Mysigner::Config.new
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Test', 'token')
      expect(config.valid?).to be false
    end

    it 'returns false when current_organization_id is nil' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      expect(config.valid?).to be false
    end

    it 'returns false when api_url is empty' do
      config = Mysigner::Config.new
      config.api_url = ''
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Test', 'token')
      expect(config.valid?).to be false
    end

    it 'returns false when no token for current organization' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.current_organization_id = 1
      expect(config.valid?).to be false
    end

    it 'returns true when api_url, current_organization_id, and token are set' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Test', 'token')
      expect(config.valid?).to be true
    end
  end

  describe '#to_h' do
    it 'returns config as hash' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.user_email = 'test@example.com'
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Test Org', 'token')

      hash = config.to_h
      expect(hash).to eq({
                           api_url: 'http://localhost:3000',
                           user_email: 'test@example.com',
                           current_organization_id: 1
                         })
    end
  end

  describe '#display' do
    it 'returns config with masked token' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.user_email = 'test@example.com'
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Test Org', 'very_long_secret_token_12345')

      display = config.display
      expect(display[:api_url]).to eq('http://localhost:3000')
      expect(display[:user_email]).to eq('test@example.com')
      expect(display[:current_token]).to eq('very...2345')
      expect(display[:current_organization]).to eq('Test Org (ID: 1)')
    end

    it 'shows (not set) for nil values' do
      config = Mysigner::Config.new
      display = config.display

      expect(display[:api_url]).to eq('(not set)')
      expect(display[:user_email]).to eq('(not set)')
      expect(display[:current_token]).to eq('(not set)')
    end

    it 'shows all organizations' do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.current_organization_id = 1
      config.save_token_for_org(1, 'Org 1', 'token1')
      config.save_token_for_org(2, 'Org 2', 'token2')

      display = config.display
      expect(display[:all_organizations]).to include('Org 1 (ID: 1) ✓')
      expect(display[:all_organizations]).to include('Org 2 (ID: 2) ✓')
    end
  end

  describe 'multi-token methods' do
    let(:config) { Mysigner::Config.new }

    describe '#save_token_for_org' do
      it 'saves token for specific organization' do
        config.save_token_for_org(5, 'My Org', 'token123')
        expect(config.api_token(5)).to eq('token123')
        expect(config.org_name(5)).to eq('My Org')
      end

      it 'overwrites existing token for organization' do
        config.save_token_for_org(5, 'My Org', 'old_token')
        config.save_token_for_org(5, 'My Org Updated', 'new_token')

        expect(config.api_token(5)).to eq('new_token')
        expect(config.org_name(5)).to eq('My Org Updated')
      end
    end

    describe '#has_token_for_org?' do
      it 'returns true when token exists' do
        config.save_token_for_org(5, 'My Org', 'token123')
        expect(config.has_token_for_org?(5)).to be true
      end

      it "returns false when token doesn't exist" do
        expect(config.has_token_for_org?(999)).to be false
      end

      it 'returns false when token is empty string' do
        config.save_token_for_org(5, 'My Org', '')
        expect(config.has_token_for_org?(5)).to be false
      end
    end

    describe '#api_token' do
      it 'returns token for current organization by default' do
        config.current_organization_id = 5
        config.save_token_for_org(5, 'My Org', 'token123')

        expect(config.api_token).to eq('token123')
      end

      it 'returns token for specific organization when provided' do
        config.current_organization_id = 5
        config.save_token_for_org(5, 'Org 5', 'token5')
        config.save_token_for_org(7, 'Org 7', 'token7')

        expect(config.api_token(7)).to eq('token7')
        expect(config.api_token(5)).to eq('token5')
        expect(config.api_token).to eq('token5') # default to current
      end

      it 'returns nil when organization has no token' do
        expect(config.api_token(999)).to be_nil
      end

      it 'returns nil when current_organization_id is nil' do
        config.current_organization_id = nil
        expect(config.api_token).to be_nil
      end
    end

    describe '#org_name' do
      it 'returns organization name' do
        config.save_token_for_org(5, 'Test Organization', 'token')
        expect(config.org_name(5)).to eq('Test Organization')
      end

      it 'returns nil for non-existent organization' do
        expect(config.org_name(999)).to be_nil
      end
    end

    describe '#organization_ids' do
      it 'returns all organization IDs' do
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.save_token_for_org(5, 'Org 5', 'token5')
        config.save_token_for_org(10, 'Org 10', 'token10')

        expect(config.organization_ids.sort).to eq([1, 5, 10])
      end

      it 'returns empty array when no organizations' do
        expect(config.organization_ids).to eq([])
      end
    end

    describe '#remove_token_for_org' do
      it 'removes token for specific organization' do
        config.save_token_for_org(5, 'My Org', 'token123')
        expect(config.has_token_for_org?(5)).to be true

        config.remove_token_for_org(5)
        expect(config.has_token_for_org?(5)).to be false
      end

      it "doesn't affect other organizations" do
        config.save_token_for_org(5, 'Org 5', 'token5')
        config.save_token_for_org(7, 'Org 7', 'token7')

        config.remove_token_for_org(5)

        expect(config.has_token_for_org?(5)).to be false
        expect(config.has_token_for_org?(7)).to be true
      end
    end
  end

  describe '.env_configured?' do
    after do
      ENV.delete('MYSIGNER_API_TOKEN')
      ENV.delete('MYSIGNER_ORG_ID')
      ENV.delete('MYSIGNER_API_URL')
      ENV.delete('MYSIGNER_EMAIL')
    end

    it 'returns true when required env vars are set' do
      ENV['MYSIGNER_API_TOKEN'] = 'test_token'
      ENV['MYSIGNER_ORG_ID'] = '42'
      expect(Mysigner::Config.env_configured?).to be true
    end

    it 'returns false when MYSIGNER_API_TOKEN is missing' do
      ENV.delete('MYSIGNER_API_TOKEN')
      ENV['MYSIGNER_ORG_ID'] = '42'
      expect(Mysigner::Config.env_configured?).to be_falsey
    end

    it 'returns false when MYSIGNER_ORG_ID is missing' do
      ENV['MYSIGNER_API_TOKEN'] = 'test_token'
      ENV.delete('MYSIGNER_ORG_ID')
      expect(Mysigner::Config.env_configured?).to be_falsey
    end

    it 'returns false when MYSIGNER_API_TOKEN is empty' do
      ENV['MYSIGNER_API_TOKEN'] = ''
      ENV['MYSIGNER_ORG_ID'] = '42'
      expect(Mysigner::Config.env_configured?).to be false
    end

    it 'returns false when MYSIGNER_ORG_ID is empty' do
      ENV['MYSIGNER_API_TOKEN'] = 'test_token'
      ENV['MYSIGNER_ORG_ID'] = ''
      expect(Mysigner::Config.env_configured?).to be false
    end
  end

  describe '.from_env' do
    before do
      ENV['MYSIGNER_API_TOKEN'] = 'ci_token_123'
      ENV['MYSIGNER_ORG_ID'] = '99'
      ENV['MYSIGNER_API_URL'] = 'https://mysigner.dev'
      ENV['MYSIGNER_EMAIL'] = 'ci@example.com'
    end

    after do
      ENV.delete('MYSIGNER_API_TOKEN')
      ENV.delete('MYSIGNER_ORG_ID')
      ENV.delete('MYSIGNER_API_URL')
      ENV.delete('MYSIGNER_EMAIL')
    end

    it 'creates a config from environment variables' do
      config = Mysigner::Config.from_env
      expect(config.api_url).to eq('https://mysigner.dev')
      expect(config.user_email).to eq('ci@example.com')
      expect(config.current_organization_id).to eq(99)
      expect(config.api_token).to eq('ci_token_123')
    end

    it 'marks config as from_env' do
      config = Mysigner::Config.from_env
      expect(config.from_env?).to be true
    end

    it 'defaults api_url to production when not set' do
      ENV.delete('MYSIGNER_API_URL')
      config = Mysigner::Config.from_env
      expect(config.api_url).to eq('https://mysigner.dev')
    end

    it 'allows nil email' do
      ENV.delete('MYSIGNER_EMAIL')
      config = Mysigner::Config.from_env
      expect(config.user_email).to be_nil
    end

    it 'creates valid config' do
      config = Mysigner::Config.from_env
      expect(config.valid?).to be true
    end

    it 'disables encryption' do
      config = Mysigner::Config.from_env
      expect(config.encryption_enabled).to be false
    end

    it 'sets organization name to CI' do
      config = Mysigner::Config.from_env
      expect(config.org_name).to eq('CI')
    end
  end

  describe 'encryption' do
    let(:config) { Mysigner::Config.new }
    let(:test_token) { 'test_token_12345678' }

    before do
      # Clean up keychain before each test
      `security delete-generic-password -s 'com.mysigner.cli' -a 'config_encryption_key' 2>/dev/null`
    end

    after do
      # Clean up keychain after each test
      `security delete-generic-password -s 'com.mysigner.cli' -a 'config_encryption_key' 2>/dev/null`
    end

    describe '#encrypt_token and #decrypt_token' do
      it 'encrypts and decrypts token correctly' do
        config.encryption_enabled = true
        encrypted = config.send(:encrypt_token, test_token)

        expect(encrypted).to start_with('encrypted:')
        expect(encrypted).not_to include(test_token)

        decrypted = config.send(:decrypt_token, encrypted)
        expect(decrypted).to eq(test_token)
      end

      it 'uses different IV for each encryption' do
        config.encryption_enabled = true
        encrypted1 = config.send(:encrypt_token, test_token)
        encrypted2 = config.send(:encrypt_token, test_token)

        expect(encrypted1).not_to eq(encrypted2)

        # But both decrypt to same value
        expect(config.send(:decrypt_token, encrypted1)).to eq(test_token)
        expect(config.send(:decrypt_token, encrypted2)).to eq(test_token)
      end

      it 'stores encryption key in keychain' do
        config.encryption_enabled = true
        config.send(:encrypt_token, test_token)

        # Verify key exists in keychain
        result = `security find-generic-password -s 'com.mysigner.cli' -a 'config_encryption_key' -w 2>/dev/null`
        expect(result).not_to be_empty
      end

      it 'reuses same encryption key across instances' do
        config1 = Mysigner::Config.new
        config1.encryption_enabled = true
        encrypted = config1.send(:encrypt_token, test_token)

        config2 = Mysigner::Config.new
        config2.encryption_enabled = true
        decrypted = config2.send(:decrypt_token, encrypted)

        expect(decrypted).to eq(test_token)
      end
    end

    describe '#encrypted?' do
      it 'returns true for encrypted tokens' do
        expect(config.send(:encrypted?, 'encrypted:abc:def:ghi')).to be true
      end

      it 'returns false for plain tokens' do
        expect(config.send(:encrypted?, 'plain_token')).to be false
      end

      it 'returns false for nil' do
        expect(config.send(:encrypted?, nil)).to be false
      end
    end

    describe '#enable_encryption!' do
      it 'enables encryption' do
        config.encryption_enabled = false # Start with encryption disabled
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.save_token_for_org(2, 'Org 2', 'token2')

        expect(config.encryption_enabled).to be false

        config.enable_encryption!

        expect(config.encryption_enabled).to be true
      end

      it 'encrypts all existing tokens' do
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.save_token_for_org(2, 'Org 2', 'token2')

        config.enable_encryption!

        # Check internal storage (encrypted)
        expect(config.organizations['1']['token']).to start_with('encrypted:')
        expect(config.organizations['2']['token']).to start_with('encrypted:')

        # But api_token returns decrypted value
        expect(config.api_token(1)).to eq('token1')
        expect(config.api_token(2)).to eq('token2')
      end

      it 'saves config after encryption' do
        config.api_url = 'http://localhost:3000'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.save

        config.enable_encryption!

        # Load new config and verify tokens are encrypted
        new_config = Mysigner::Config.new
        expect(new_config.encryption_enabled).to be true
        expect(new_config.api_token(1)).to eq('token1')
      end

      it 'is idempotent' do
        config.save_token_for_org(1, 'Org 1', 'token1')

        config.enable_encryption!
        encrypted_first = config.organizations['1']['token']

        config.enable_encryption!
        encrypted_second = config.organizations['1']['token']

        expect(encrypted_first).to eq(encrypted_second)
      end
    end

    describe '#disable_encryption!' do
      it 'disables encryption' do
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.enable_encryption!

        expect(config.encryption_enabled).to be true

        config.disable_encryption!

        expect(config.encryption_enabled).to be false
      end

      it 'decrypts all tokens' do
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.save_token_for_org(2, 'Org 2', 'token2')
        config.enable_encryption!

        config.disable_encryption!

        # Check tokens are now plain text
        expect(config.organizations['1']['token']).to eq('token1')
        expect(config.organizations['2']['token']).to eq('token2')
        expect(config.organizations['1']['token']).not_to start_with('encrypted:')
      end

      it 'saves config after decryption' do
        config.api_url = 'http://localhost:3000'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.enable_encryption!

        config.disable_encryption!

        # Load new config and verify tokens are decrypted
        new_config = Mysigner::Config.new
        expect(new_config.encryption_enabled).to be false
        expect(new_config.organizations['1']['token']).to eq('token1')
      end
    end

    describe '#encrypted_config?' do
      it 'returns true when config has encrypted tokens' do
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.enable_encryption!

        expect(config.encrypted_config?).to be true
      end

      it 'returns false when config has no encrypted tokens' do
        config.encryption_enabled = false  # Disable encryption to test unencrypted tokens
        config.save_token_for_org(1, 'Org 1', 'token1')

        expect(config.encrypted_config?).to be false
      end

      it 'returns false when config has no organizations' do
        expect(config.encrypted_config?).to be false
      end
    end

    describe 'save and load with encryption' do
      it 'saves encrypted tokens and loads them correctly' do
        config.encryption_enabled = false  # Start without encryption
        config.api_url = 'http://localhost:3000'
        config.current_organization_id = 1
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.save_token_for_org(2, 'Org 2', 'token2')
        config.enable_encryption! # This should also call save internally

        # Load config in new instance
        new_config = Mysigner::Config.new

        expect(new_config.encryption_enabled).to be true
        expect(new_config.api_token(1)).to eq('token1')
        expect(new_config.api_token(2)).to eq('token2')
      end

      it 'auto-detects encryption on load' do
        config.api_url = 'http://localhost:3000'
        config.current_organization_id = 1
        config.encryption_enabled = true
        config.save_token_for_org(1, 'Org 1', 'token1')
        config.save

        new_config = Mysigner::Config.new
        expect(new_config.encryption_enabled).to be true
      end
    end

    describe 'encryption with existing commands' do
      it 'works transparently with save_token_for_org' do
        config.encryption_enabled = true
        config.save_token_for_org(5, 'My Org', 'secret_token')

        # Token should be encrypted in storage
        expect(config.organizations['5']['token']).to start_with('encrypted:')

        # But api_token returns decrypted
        expect(config.api_token(5)).to eq('secret_token')
      end

      it 'has_token_for_org? works with encrypted tokens' do
        config.encryption_enabled = true
        config.save_token_for_org(5, 'My Org', 'secret_token')

        expect(config.has_token_for_org?(5)).to be true
      end
    end
  end
end
