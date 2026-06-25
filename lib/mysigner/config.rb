# frozen_string_literal: true

require 'English'

require 'yaml'
require 'fileutils'
require 'openssl'
require 'base64'
require 'json'
require 'securerandom'
require 'rbconfig'

module Mysigner
  class Config
    CONFIG_DIR = File.expand_path('~/.mysigner').freeze
    CONFIG_FILE = File.join(CONFIG_DIR, 'config.yml').freeze
    KEY_FILE = File.join(CONFIG_DIR, '.encryption_key').freeze
    KEYCHAIN_SERVICE = 'com.mysigner.cli'
    KEYCHAIN_ACCOUNT = 'config_encryption_key'

    # Environment variable names for CI/CD support
    ENV_API_TOKEN = 'MYSIGNER_API_TOKEN'
    ENV_API_URL = 'MYSIGNER_API_URL'
    ENV_EMAIL = 'MYSIGNER_EMAIL'
    ENV_ORG_ID = 'MYSIGNER_ORG_ID'
    ENV_LOCAL_ONLY = 'MYSIGNER_LOCAL_ONLY'

    attr_accessor :api_url, :user_email, :current_organization_id, :encryption_enabled, :local_only
    attr_reader :organizations

    def initialize
      @api_url = nil
      @user_email = nil
      @current_organization_id = nil
      @organizations = {}
      @encryption_enabled = true # Enable by default for security
      @local_only = false
      @from_env = false
      load if exists?
    end

    # Check if all required env vars are set for CI/CD mode
    def self.env_configured?
      ENV.fetch(ENV_API_TOKEN, nil) && !ENV[ENV_API_TOKEN].empty? &&
        ENV.fetch(ENV_ORG_ID, nil) && !ENV[ENV_ORG_ID].empty?
    end

    # Create a Config from environment variables (for CI/CD)
    def self.from_env
      config = allocate
      config.instance_variable_set(:@encryption_enabled, false)
      config.instance_variable_set(:@from_env, true)
      config.instance_variable_set(:@local_only, false)

      org_id = ENV.fetch(ENV_ORG_ID, nil)
      token = ENV.fetch(ENV_API_TOKEN, nil)
      config.instance_variable_set(:@api_url, ENV[ENV_API_URL] || 'https://mysigner.dev')
      config.instance_variable_set(:@user_email, ENV.fetch(ENV_EMAIL, nil))
      config.instance_variable_set(:@current_organization_id, org_id.to_i)
      config.instance_variable_set(:@organizations, {
                                     org_id.to_s => { 'name' => 'CI', 'token' => token }
                                   })

      config
    end

    # Whether this config was loaded from environment variables
    def from_env?
      @from_env
    end

    # Local-only mode at the Config level: cascade ENV → file. The CLI
    # Helpers concern layers --local-only / --no-local-only on top.
    def self.local_only?
      local_only_from_env? || local_only_from_file?
    end

    # Public predicate for the env-var source. Mirrors local_only_from_file?
    # so status's "Source: …" attribution can distinguish env vs file
    # using the same truthy parser the cascade uses (a literal env value
    # of "0" / "false" reads as off, not as "env var enabled it").
    def self.local_only_from_env?
      truthy_env?(ENV_LOCAL_ONLY)
    end

    # Lightweight check that reads only ~/.mysigner/config.yml's
    # `local_only:` key without invoking #load (which decrypts tokens
    # via the Keychain). A user with no MySigner account still needs
    # to flip this setting, so we never raise on a missing/corrupt
    # or absent file — we just return false.
    def self.local_only_from_file?
      data = YAML.safe_load_file(CONFIG_FILE)
      data.is_a?(Hash) && data['local_only'] == true
    rescue Errno::ENOENT, Psych::SyntaxError
      false
    end

    # Instance-level predicate. Merges two surfaces:
    #   - @local_only: set to true by Helpers#blank_local_only_config so a
    #     sentinel config always answers true without touching ENV or disk.
    #   - self.class.local_only?: the normal ENV → file cascade.
    def local_only?
      @local_only || self.class.local_only?
    end

    # Get API token for current organization (or specific org)
    def api_token(org_id = nil)
      org_id ||= @current_organization_id
      return nil if org_id.nil?

      org_data = @organizations[org_id.to_s]
      token = org_data&.dig('token')
      return nil if token.nil?

      # Decrypt if encrypted
      encrypted?(token) ? decrypt_token(token) : token
    end

    # Save token for a specific organization
    def save_token_for_org(org_id, org_name, token)
      encrypted_token = @encryption_enabled ? encrypt_token(token) : token
      @organizations[org_id.to_s] = {
        'name' => org_name,
        'token' => encrypted_token
      }
    end

    # Check if we have a token for a specific organization
    def has_token_for_org?(org_id)
      token = api_token(org_id)
      !token.nil? && !token.empty?
    end

    # Get organization name
    def org_name(org_id = nil)
      org_id ||= @current_organization_id
      return nil if org_id.nil?

      org_data = @organizations[org_id.to_s]
      org_data&.dig('name')
    end

    # Get all organization IDs
    def organization_ids
      @organizations.keys.map(&:to_i)
    end

    def organization_id
      @current_organization_id
    end

    # Remove token for specific organization
    def remove_token_for_org(org_id)
      @organizations.delete(org_id.to_s)
    end

    # Load configuration from file
    def load
      return false unless exists?

      # mysigner-51 — safe_load_file rejects arbitrary Ruby object
      # instantiation in the YAML (`!ruby/object:Foo` etc.). The config
      # shape is just String/Integer/Boolean/Hash (api_url, user_email,
      # current_organization_id, local_only, organizations: {id => {name,
      # token}}), all in safe_load's default allowed set, so no
      # permitted_classes
      # extension is needed. Low risk (the file is 0600 and user-owned)
      # but cheap hardening against a future RCE if config write or read
      # ever moves outside the owner-only assumption.
      data = YAML.safe_load_file(CONFIG_FILE)

      @api_url = data['api_url']
      @user_email = data['user_email']
      @current_organization_id = data['current_organization_id']
      @organizations = data['organizations'] || {}
      @local_only = data['local_only'] == true

      # Auto-detect encryption from config
      @encryption_enabled = encrypted_config?

      true
    rescue StandardError => e
      raise ConfigError, "Failed to load config: #{e.message}"
    end

    # Save configuration to file
    def save
      ensure_config_dir_exists

      data = {
        'api_url' => @api_url,
        'user_email' => @user_email,
        'current_organization_id' => @current_organization_id,
        'organizations' => @organizations,
        'local_only' => @local_only
      }

      File.write(CONFIG_FILE, data.to_yaml)
      File.chmod(0o600, CONFIG_FILE) # Make file readable only by owner
      true
    rescue StandardError => e
      raise ConfigError, "Failed to save config: #{e.message}"
    end

    # Clear all configuration
    def clear
      @api_url = nil
      @user_email = nil
      @current_organization_id = nil
      @organizations = {}
      @local_only = false

      File.delete(CONFIG_FILE) if exists?

      # On non-macOS the encryption key lives in a file fallback. Wipe it on
      # logout so a fresh login can mint a new key — otherwise the old key
      # would silently encrypt a new token that nobody else can decrypt.
      FileUtils.rm_f(KEY_FILE)

      # Phase 0: logout also purges the keystore cache so a shared machine
      # doesn't leave prior-user keystore blobs on disk.
      keystores_dir = File.expand_path('~/.mysigner/keystores')
      FileUtils.rm_rf(keystores_dir)

      true
    rescue StandardError => e
      raise ConfigError, "Failed to clear config: #{e.message}"
    end

    # Check if config file exists
    def exists?
      File.exist?(CONFIG_FILE)
    end

    # Check if configuration is complete (has required fields)
    def valid?
      !@api_url.nil? && !@api_url.empty? &&
        !@current_organization_id.nil? &&
        has_token_for_org?(@current_organization_id)
    end

    # Get config as hash
    def to_h
      {
        api_url: @api_url,
        user_email: @user_email,
        current_organization_id: @current_organization_id
      }
    end

    # Display config (with masked tokens)
    def display
      current_org_name = org_name(@current_organization_id) || '(not set)'
      # Never let an undecryptable token turn `mysigner config` into a crash —
      # render it as an actionable placeholder instead.
      current_token = begin
        api_token(@current_organization_id)
      rescue ConfigError
        :unreadable
      end

      token_display = case current_token
                      when nil then '(not set)'
                      when :unreadable then '(unreadable — run mysigner login)'
                      else mask_token(current_token)
                      end

      display_data = {
        api_url: @api_url || '(not set)',
        user_email: @user_email || '(not set)',
        current_organization: "#{current_org_name} (ID: #{@current_organization_id || 'not set'})",
        current_token: token_display
      }

      # Show all organizations
      if @organizations.any?
        display_data[:all_organizations] = @organizations.map do |org_id, org_data|
          token_status = org_data['token'] ? '✓' : '✗'
          "#{org_data['name']} (ID: #{org_id}) #{token_status}"
        end.join(', ')
      end

      display_data
    end

    # Enable encryption and re-encrypt all tokens
    def enable_encryption!
      return true if @encryption_enabled

      @encryption_enabled = true

      # Re-encrypt all existing tokens
      @organizations.each_value do |org_data|
        token = org_data['token']
        next if token.nil? || encrypted?(token)

        org_data['token'] = encrypt_token(token)
      end

      save
      true
    end

    # Disable encryption and decrypt all tokens
    def disable_encryption!
      return true unless @encryption_enabled

      # Decrypt all tokens first
      @organizations.each_value do |org_data|
        token = org_data['token']
        next if token.nil? || !encrypted?(token)

        org_data['token'] = decrypt_token(token)
      end

      @encryption_enabled = false
      save
      true
    end

    # Check if config uses encryption
    def encrypted_config?
      @organizations.values.any? { |org_data| encrypted?(org_data['token']) }
    end

    # Public accessor for the per-machine 32-byte AES-256-GCM key.
    # Exposed so sibling stores (e.g. LocalCredentials) can encrypt secrets
    # under the same key without duplicating the keychain/file fallback.
    # The key itself is created on first read and is stable across calls.
    def fetch_encryption_key
      get_or_create_encryption_key
    end

    def self.truthy_env?(name)
      raw = ENV.fetch(name, nil)
      return false if raw.nil?

      value = raw.strip
      return false if value.empty?

      value.match?(/\A(1|true|yes)\z/i)
    end
    private_class_method :truthy_env?

    private

    def ensure_config_dir_exists
      FileUtils.mkdir_p(CONFIG_DIR)
    end

    def mask_token(token)
      return token if token.length < 8

      "#{token[0..3]}...#{token[-4..]}"
    end

    # Encryption methods
    def encrypt_token(token)
      key = get_or_create_encryption_key
      cipher = OpenSSL::Cipher.new('aes-256-gcm')
      cipher.encrypt
      cipher.key = key
      iv = cipher.random_iv

      encrypted = cipher.update(token) + cipher.final
      auth_tag = cipher.auth_tag

      # Format: encrypted:base64(iv):base64(auth_tag):base64(encrypted_data)
      "encrypted:#{Base64.strict_encode64(iv)}:#{Base64.strict_encode64(auth_tag)}:#{Base64.strict_encode64(encrypted)}"
    end

    def decrypt_token(encrypted_token)
      return encrypted_token unless encrypted?(encrypted_token)

      # Parse format
      parts = encrypted_token.split(':', 4)
      return encrypted_token if parts.length != 4 || parts[0] != 'encrypted'

      iv = Base64.strict_decode64(parts[1])
      auth_tag = Base64.strict_decode64(parts[2])
      encrypted_data = Base64.strict_decode64(parts[3])

      key = get_or_create_encryption_key
      decipher = OpenSSL::Cipher.new('aes-256-gcm')
      decipher.decrypt
      decipher.key = key
      decipher.iv = iv
      decipher.auth_tag = auth_tag

      decipher.update(encrypted_data) + decipher.final
    rescue StandardError => e
      raise ConfigError, "Failed to decrypt token: #{e.message}"
    end

    def encrypted?(token)
      token.to_s.start_with?('encrypted:')
    end

    def get_or_create_encryption_key
      # macOS Keychain is the preferred key store. On Linux/Windows we fall
      # back to a 0600 file in the config dir so the encrypted YAML token
      # is still recoverable across CLI invocations. The fallback is roughly
      # equivalent in security to the config file itself; for the strongest
      # posture in CI, prefer the MYSIGNER_API_TOKEN env var path.
      if macos_keychain?
        key = get_key_from_keychain
        return key if key

        new_key = SecureRandom.bytes(32) # 256-bit key
        store_key_in_keychain(new_key)
        return new_key
      end

      key = read_key_from_file
      return key if key

      warn_keychain_unavailable_once
      ensure_config_dir_exists
      new_key = SecureRandom.bytes(32) # 256-bit key
      write_key_to_file(new_key)
      new_key
    end

    def macos_keychain?
      RbConfig::CONFIG['host_os'] =~ /darwin/i
    end

    def get_key_from_keychain
      # Use macOS security command to get key from keychain
      cmd = "security find-generic-password -s '#{KEYCHAIN_SERVICE}' -a '#{KEYCHAIN_ACCOUNT}' -w 2>/dev/null"
      result = `#{cmd}`.strip

      return nil if result.empty? || $CHILD_STATUS.exitstatus != 0

      # Decode from base64
      Base64.strict_decode64(result)
    rescue StandardError
      nil
    end

    def store_key_in_keychain(key)
      # Encode key as base64
      encoded_key = Base64.strict_encode64(key)

      # Delete existing key if present
      `security delete-generic-password -s '#{KEYCHAIN_SERVICE}' -a '#{KEYCHAIN_ACCOUNT}' 2>/dev/null`

      # Add new key to keychain
      cmd = "security add-generic-password -s '#{KEYCHAIN_SERVICE}' -a '#{KEYCHAIN_ACCOUNT}' -w '#{encoded_key}'"
      system(cmd)

      $CHILD_STATUS.exitstatus.zero?
    rescue StandardError => e
      raise ConfigError, "Failed to store encryption key in keychain: #{e.message}"
    end

    def read_key_from_file
      return nil unless File.exist?(KEY_FILE)

      encoded = File.read(KEY_FILE).strip
      return nil if encoded.empty?

      Base64.strict_decode64(encoded)
    rescue StandardError
      nil
    end

    def write_key_to_file(key)
      File.write(KEY_FILE, Base64.strict_encode64(key))
      File.chmod(0o600, KEY_FILE)
      true
    rescue StandardError => e
      raise ConfigError, "Failed to write encryption key file: #{e.message}"
    end

    def warn_keychain_unavailable_once
      return if defined?(@keychain_warning_shown) && @keychain_warning_shown

      @keychain_warning_shown = true
      return unless $stderr.respond_to?(:tty?) && $stderr.tty?

      warn(<<~MSG)
        [mysigner] macOS Keychain is unavailable on this platform. Falling
        back to file-based encryption key at #{KEY_FILE} (mode 0600).
        For the strongest CI/CD posture, set MYSIGNER_API_TOKEN as an
        encrypted secret instead — env-var auth never touches the disk.
      MSG
    end
  end

  class ConfigError < StandardError; end
end
