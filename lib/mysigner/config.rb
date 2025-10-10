require 'yaml'
require 'fileutils'
require 'openssl'
require 'base64'
require 'json'
require 'securerandom'

module Mysigner
  class Config
    CONFIG_DIR = File.expand_path("~/.mysigner").freeze
    CONFIG_FILE = File.join(CONFIG_DIR, "config.yml").freeze
    KEYCHAIN_SERVICE = "com.mysigner.cli".freeze
    KEYCHAIN_ACCOUNT = "config_encryption_key".freeze

    attr_accessor :api_url, :user_email, :current_organization_id
    attr_reader :organizations
    attr_accessor :encryption_enabled

    def initialize
      @api_url = nil
      @user_email = nil
      @current_organization_id = nil
      @organizations = {}
      @encryption_enabled = true  # Enable by default for security
      load if exists?
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

    # Remove token for specific organization
    def remove_token_for_org(org_id)
      @organizations.delete(org_id.to_s)
    end

    # Check if config needs email migration
    def needs_email_migration?
      @user_email.nil? || @user_email.empty?
    end

    # Load configuration from file
    def load
      return false unless exists?

      data = YAML.load_file(CONFIG_FILE)
      
      # Check for old format and migrate
      if data['api_token'] && !data['organizations']
        migrate_from_old_format(data)
      else
        load_new_format(data)
      end
      
      true
    rescue => e
      raise ConfigError, "Failed to load config: #{e.message}"
    end

    # Save configuration to file
    def save
      ensure_config_dir_exists

      data = {
        'api_url' => @api_url,
        'user_email' => @user_email,
        'current_organization_id' => @current_organization_id,
        'organizations' => @organizations
      }

      File.write(CONFIG_FILE, data.to_yaml)
      File.chmod(0600, CONFIG_FILE) # Make file readable only by owner
      true
    rescue => e
      raise ConfigError, "Failed to save config: #{e.message}"
    end

    # Clear all configuration
    def clear
      @api_url = nil
      @user_email = nil
      @current_organization_id = nil
      @organizations = {}
      
      if exists?
        File.delete(CONFIG_FILE)
      end
      true
    rescue => e
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
        current_organization_id: @current_organization_id,
        api_token: api_token, # For backward compatibility
        organization_id: @current_organization_id # For backward compatibility
      }
    end

    # Display config (with masked tokens)
    def display
      current_org_name = org_name(@current_organization_id) || '(not set)'
      current_token = api_token(@current_organization_id)
      
      display_data = {
        api_url: @api_url || '(not set)',
        user_email: @user_email || '(not set)',
        current_organization: "#{current_org_name} (ID: #{@current_organization_id || 'not set'})",
        current_token: current_token ? mask_token(current_token) : '(not set)'
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
    
    # Setter for backward compatibility (deprecated)
    def api_token=(token)
      return unless @current_organization_id
      save_token_for_org(@current_organization_id, org_name(@current_organization_id) || 'Unknown', token)
    end
    
    # Setter for backward compatibility (deprecated)
    def organization_id=(org_id)
      @current_organization_id = org_id
    end

    # Enable encryption and re-encrypt all tokens
    def enable_encryption!
      return true if @encryption_enabled
      
      @encryption_enabled = true
      
      # Re-encrypt all existing tokens
      @organizations.each do |org_id, org_data|
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
      @organizations.each do |org_id, org_data|
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

    private

    def load_new_format(data)
      @api_url = data['api_url']
      @user_email = data['user_email']
      @current_organization_id = data['current_organization_id']
      @organizations = data['organizations'] || {}
      
      # Auto-detect encryption from config
      @encryption_enabled = encrypted_config?
    end

    def migrate_from_old_format(data)
      @api_url = data['api_url']
      @current_organization_id = data['organization_id']
      
      # If we have old format, save the token under current org
      # (Note: we don't know the org name yet, will be filled in by login command)
      if @current_organization_id && data['api_token']
        @organizations[@current_organization_id.to_s] = {
          'name' => 'Unknown', # Will be updated on next API call
          'token' => data['api_token']
        }
      end
      
      # Detect encryption
      @encryption_enabled = encrypted_config?
    end

    def ensure_config_dir_exists
      FileUtils.mkdir_p(CONFIG_DIR) unless Dir.exist?(CONFIG_DIR)
    end

    def mask_token(token)
      return token if token.length < 8
      "#{token[0..3]}...#{token[-4..-1]}"
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
    rescue => e
      raise ConfigError, "Failed to decrypt token: #{e.message}"
    end

    def encrypted?(token)
      token.to_s.start_with?('encrypted:')
    end

    def get_or_create_encryption_key
      # Try to get key from keychain
      key = get_key_from_keychain
      return key if key
      
      # Generate new key and store in keychain
      new_key = SecureRandom.bytes(32) # 256-bit key
      store_key_in_keychain(new_key)
      new_key
    end

    def get_key_from_keychain
      # Use macOS security command to get key from keychain
      cmd = "security find-generic-password -s '#{KEYCHAIN_SERVICE}' -a '#{KEYCHAIN_ACCOUNT}' -w 2>/dev/null"
      result = `#{cmd}`.strip
      
      return nil if result.empty? || $?.exitstatus != 0
      
      # Decode from base64
      Base64.strict_decode64(result)
    rescue => e
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
      
      $?.exitstatus == 0
    rescue => e
      raise ConfigError, "Failed to store encryption key in keychain: #{e.message}"
    end
  end

  class ConfigError < StandardError; end
end

