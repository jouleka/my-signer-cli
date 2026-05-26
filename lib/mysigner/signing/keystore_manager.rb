# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'base64'
require 'open3'

module Mysigner
  module Signing
    class KeystoreManager
      class KeystoreError < StandardError; end
      class KeystoreNotFoundError < KeystoreError; end
      class DownloadError < KeystoreError; end

      KEYSTORES_DIR = File.expand_path('~/.mysigner/keystores')

      def initialize(client, organization_id)
        @client = client
        @organization_id = organization_id
        ensure_keystores_dir
      end

      # List all keystores from API. The list payload never contains the
      # keystore_password or key_password (mysigner-49) — callers that need
      # the secrets must use #fetch_secrets.
      # @param android_app_id [Integer, nil] Filter by app ID
      def list(android_app_id: nil)
        params = {}
        params[:android_app_id] = android_app_id if android_app_id

        response = @client.get(
          "/api/v1/organizations/#{@organization_id}/android_keystores",
          params: params
        )
        response[:data]['android_keystores'] || []
      end

      # Get active keystore for an app (or any active keystore if no app
      # specified). Returns the same secret-free payload shape as #list.
      def active_keystore(android_app_id: nil)
        keystores = list(android_app_id: android_app_id)
        keystores.find { |k| k['active'] }
      end

      # Phase 0: narrow audit-logged endpoint that returns the keystore
      # password + key password + key alias for a single keystore. Replaces
      # the insecure ?include_secrets=true list flag.
      # Returns a hash: { 'keystore_password' =>, 'key_password' =>, 'key_alias' => }
      def fetch_secrets(keystore_id)
        response = @client.post(
          "/api/v1/organizations/#{@organization_id}/android_keystores/#{keystore_id}/secrets"
        )
        response[:data] || {}
      end

      # Download a keystore from API and save locally
      # Returns: { path: String, password: String, alias: String, key_password: String }
      def download(keystore_id)
        # Get keystore details
        keystores = list
        keystore = keystores.find { |k| k['id'].to_s == keystore_id.to_s }

        raise KeystoreNotFoundError, "Keystore with ID #{keystore_id} not found" unless keystore

        # Download the keystore file
        download_url = "/api/v1/organizations/#{@organization_id}/android_keystores/#{keystore_id}/download"

        conn = build_download_connection
        response = conn.get(download_url)

        unless response.success?
          error_msg = begin
            JSON.parse(response.body)['message']
          rescue StandardError
            "HTTP #{response.status}"
          end
          raise DownloadError, "Failed to download keystore: #{error_msg}"
        end

        # Save to local file
        filename = "#{keystore['name'].gsub(/[^a-zA-Z0-9_.-]/, '_')}.jks"
        local_path = File.join(KEYSTORES_DIR, filename)

        File.binwrite(local_path, response.body)
        File.chmod(0o600, local_path) # Secure permissions

        {
          path: local_path,
          name: keystore['name'],
          key_alias: keystore['key_alias'],
          id: keystore['id']
        }
      end

      # Get or download keystore (uses cached version if available and fresh).
      # Phase 0: cache has a TTL (default 24h, override via
      # MYSIGNER_KEYSTORE_CACHE_HOURS). Stale files are deleted + re-downloaded.
      def get_or_download(keystore_id)
        keystores = list
        keystore = keystores.find { |k| k['id'].to_s == keystore_id.to_s }

        raise KeystoreNotFoundError, "Keystore with ID #{keystore_id} not found" unless keystore

        filename = "#{keystore['name'].gsub(/[^a-zA-Z0-9_.-]/, '_')}.jks"
        local_path = File.join(KEYSTORES_DIR, filename)
        max_age_hours = (ENV['MYSIGNER_KEYSTORE_CACHE_HOURS'] || 24).to_i

        if File.exist?(local_path)
          age_seconds = Time.now - File.mtime(local_path)
          if age_seconds < (max_age_hours * 3600)
            return {
              path: local_path,
              name: keystore['name'],
              key_alias: keystore['key_alias'],
              id: keystore['id'],
              cached: true
            }
          else
            # Stale cache — delete and re-download below
            File.delete(local_path)
          end
        end

        # Download if not cached (or stale)
        result = download(keystore_id)
        result[:cached] = false
        result
      end

      # Upload a keystore to API
      def upload(name:, keystore_path:, keystore_password:, key_alias:, key_password: nil, android_app_id: nil,
                 active: true)
        raise KeystoreError, "Keystore file not found: #{keystore_path}" unless File.exist?(keystore_path)

        # Read and encode keystore
        keystore_content = File.binread(keystore_path)
        keystore_base64 = Base64.strict_encode64(keystore_content)

        body = {
          android_keystore: {
            name: name,
            keystore_file_base64: keystore_base64,
            keystore_password: keystore_password,
            key_alias: key_alias,
            key_password: key_password || keystore_password,
            android_app_id: android_app_id,
            active: active
          }
        }

        response = @client.post(
          "/api/v1/organizations/#{@organization_id}/android_keystores",
          body: body
        )

        response[:data]
      end

      # Delete a keystore
      def delete(keystore_id)
        @client.delete("/api/v1/organizations/#{@organization_id}/android_keystores/#{keystore_id}")

        # Also remove local cached file
        keystores = begin
          list
        rescue StandardError
          []
        end
        keystore = keystores.find { |k| k['id'].to_s == keystore_id.to_s }
        if keystore
          filename = "#{keystore['name'].gsub(/[^a-zA-Z0-9_.-]/, '_')}.jks"
          local_path = File.join(KEYSTORES_DIR, filename)
          FileUtils.rm_f(local_path)
        end

        true
      end

      # Activate a keystore (make it the default for its app)
      def activate(keystore_id)
        response = @client.post(
          "/api/v1/organizations/#{@organization_id}/android_keystores/#{keystore_id}/activate"
        )
        response[:data]
      end

      # Clear local keystore cache
      def clear_cache
        Dir.glob(File.join(KEYSTORES_DIR, '*.jks')).each do |file|
          File.delete(file)
        end
      end

      # List locally cached keystores
      def cached_keystores
        Dir.glob(File.join(KEYSTORES_DIR, '*.jks')).map do |path|
          {
            path: path,
            name: File.basename(path, '.jks'),
            size: File.size(path),
            modified: File.mtime(path)
          }
        end
      end

      # Get keystore info using keytool.
      # Phase 0: passes the password via a temp env var consumed by
      # `-storepass:env` so it's never in argv/ps output.
      def keystore_info(keystore_path, password)
        return nil unless File.exist?(keystore_path)
        return nil unless system('which keytool > /dev/null 2>&1')

        env = { 'MYSIGNER_KS_PW' => password.to_s }
        output, status = Open3.capture2e(
          env,
          'keytool', '-list', '-v',
          '-keystore', keystore_path,
          '-storepass:env', 'MYSIGNER_KS_PW'
        )
        return nil unless status.success?

        # Parse output
        info = {}

        info[:aliases] = output.scan(/Alias name: (.+)/).flatten if output =~ /Alias name: (.+)/

        info[:expires] = ::Regexp.last_match(1) if output =~ /Valid from: .+ until: (.+)/

        info[:sha256] = ::Regexp.last_match(1).strip if output =~ /SHA256: (.+)/

        info[:sha1] = ::Regexp.last_match(1).strip if output =~ /SHA1: (.+)/

        info
      end

      private

      def ensure_keystores_dir
        FileUtils.mkdir_p(KEYSTORES_DIR)
        File.chmod(0o700, KEYSTORES_DIR) # Secure permissions
      end

      def build_download_connection
        config = Mysigner::Config.new
        config.load if config.exists?

        Faraday.new(url: config.api_url) do |f|
          f.request :authorization, 'Bearer', config.api_token
          f.options.timeout = 60
          f.options.open_timeout = 10
          f.adapter Faraday.default_adapter
        end
      end
    end
  end
end
