require 'yaml'
require 'fileutils'

module Mysigner
  class Config
    CONFIG_DIR = File.expand_path("~/.mysigner").freeze
    CONFIG_FILE = File.join(CONFIG_DIR, "config.yml").freeze

    attr_accessor :api_url, :api_token, :organization_id

    def initialize
      @api_url = nil
      @api_token = nil
      @organization_id = nil
      load if exists?
    end

    # Load configuration from file
    def load
      return false unless exists?

      data = YAML.load_file(CONFIG_FILE)
      @api_url = data['api_url']
      @api_token = data['api_token']
      @organization_id = data['organization_id']
      true
    rescue => e
      raise ConfigError, "Failed to load config: #{e.message}"
    end

    # Save configuration to file
    def save
      ensure_config_dir_exists

      data = {
        'api_url' => @api_url,
        'api_token' => @api_token,
        'organization_id' => @organization_id
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
      @api_token = nil
      @organization_id = nil
      
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
      !@api_token.nil? && !@api_token.empty?
    end

    # Get config as hash
    def to_h
      {
        api_url: @api_url,
        api_token: @api_token,
        organization_id: @organization_id
      }
    end

    # Display config (with masked token)
    def display
      {
        api_url: @api_url || '(not set)',
        api_token: @api_token ? mask_token(@api_token) : '(not set)',
        organization_id: @organization_id || '(not set)'
      }
    end

    private

    def ensure_config_dir_exists
      FileUtils.mkdir_p(CONFIG_DIR) unless Dir.exist?(CONFIG_DIR)
    end

    def mask_token(token)
      return token if token.length < 8
      "#{token[0..3]}...#{token[-4..-1]}"
    end
  end

  class ConfigError < StandardError; end
end

