require 'fileutils'
require 'base64'

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

      # List all keystores from API
      # @param android_app_id [Integer, nil] Filter by app ID
      # @param include_secrets [Boolean] Include passwords in response (only for build operations)
      def list(android_app_id: nil, include_secrets: false)
        params = {}
        params[:android_app_id] = android_app_id if android_app_id
        params[:include_secrets] = true if include_secrets

        response = @client.get(
          "/api/v1/organizations/#{@organization_id}/android_keystores",
          params: params
        )
        response[:data]['android_keystores'] || []
      end

      # Get active keystore for an app (or any active keystore if no app specified)
      # @param include_secrets [Boolean] Include passwords in response (only for build operations)
      def active_keystore(android_app_id: nil, include_secrets: false)
        keystores = list(android_app_id: android_app_id, include_secrets: include_secrets)
        keystores.find { |k| k['active'] }
      end

      # Download a keystore from API and save locally
      # Returns: { path: String, password: String, alias: String, key_password: String }
      def download(keystore_id)
        # Get keystore details
        keystores = list
        keystore = keystores.find { |k| k['id'].to_s == keystore_id.to_s }
        
        unless keystore
          raise KeystoreNotFoundError, "Keystore with ID #{keystore_id} not found"
        end

        # Download the keystore file
        download_url = "/api/v1/organizations/#{@organization_id}/android_keystores/#{keystore_id}/download"
        
        conn = build_download_connection
        response = conn.get(download_url)
        
        unless response.success?
          error_msg = begin
            JSON.parse(response.body)['message']
          rescue
            "HTTP #{response.status}"
          end
          raise DownloadError, "Failed to download keystore: #{error_msg}"
        end

        # Save to local file
        filename = "#{keystore['name'].gsub(/[^a-zA-Z0-9_.-]/, '_')}.jks"
        local_path = File.join(KEYSTORES_DIR, filename)
        
        File.binwrite(local_path, response.body)
        File.chmod(0600, local_path)  # Secure permissions

        {
          path: local_path,
          name: keystore['name'],
          key_alias: keystore['key_alias'],
          id: keystore['id']
        }
      end

      # Get or download keystore (uses cached version if available)
      def get_or_download(keystore_id)
        keystores = list
        keystore = keystores.find { |k| k['id'].to_s == keystore_id.to_s }
        
        unless keystore
          raise KeystoreNotFoundError, "Keystore with ID #{keystore_id} not found"
        end

        # Check if already cached locally
        filename = "#{keystore['name'].gsub(/[^a-zA-Z0-9_.-]/, '_')}.jks"
        local_path = File.join(KEYSTORES_DIR, filename)

        if File.exist?(local_path)
          return {
            path: local_path,
            name: keystore['name'],
            key_alias: keystore['key_alias'],
            id: keystore['id'],
            cached: true
          }
        end

        # Download if not cached
        result = download(keystore_id)
        result[:cached] = false
        result
      end

      # Upload a keystore to API
      def upload(name:, keystore_path:, keystore_password:, key_alias:, key_password: nil, android_app_id: nil, active: true)
        unless File.exist?(keystore_path)
          raise KeystoreError, "Keystore file not found: #{keystore_path}"
        end

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
        keystores = list rescue []
        keystore = keystores.find { |k| k['id'].to_s == keystore_id.to_s }
        if keystore
          filename = "#{keystore['name'].gsub(/[^a-zA-Z0-9_.-]/, '_')}.jks"
          local_path = File.join(KEYSTORES_DIR, filename)
          File.delete(local_path) if File.exist?(local_path)
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

      # Get keystore info using keytool
      def keystore_info(keystore_path, password)
        return nil unless File.exist?(keystore_path)
        return nil unless system('which keytool > /dev/null 2>&1')

        output = `keytool -list -v -keystore #{shell_escape(keystore_path)} -storepass #{shell_escape(password)} 2>&1`
        return nil unless $?.success?

        # Parse output
        info = {}
        
        if output =~ /Alias name: (.+)/
          info[:aliases] = output.scan(/Alias name: (.+)/).flatten
        end
        
        if output =~ /Valid from: .+ until: (.+)/
          info[:expires] = $1
        end
        
        if output =~ /SHA256: (.+)/
          info[:sha256] = $1.strip
        end
        
        if output =~ /SHA1: (.+)/
          info[:sha1] = $1.strip
        end

        info
      end

      private

      def ensure_keystores_dir
        FileUtils.mkdir_p(KEYSTORES_DIR)
        File.chmod(0700, KEYSTORES_DIR)  # Secure permissions
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

      def shell_escape(str)
        return "''" if str.nil? || str.empty?
        "'" + str.gsub("'", "'\\''") + "'"
      end
    end
  end
end
