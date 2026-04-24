# frozen_string_literal: true

require 'digest'
require 'faraday'
require 'uri'

module Mysigner
  module Upload
    class AscRestUploader
      # Raised when Apple rejects the /v1/buildUploads POST with a 409
      # (duplicate CFBundleVersion). Callers should translate this into a
      # "bump your build number" hint rather than a generic "Unexpected error".
      class BuildVersionConflictError < StandardError; end

      TERMINAL_APPLE_STATES = %w[COMPLETE FAILED INVALIDATED].freeze
      POLL_INTERVAL = 10
      POLL_TIMEOUT  = 600
      CHUNK_RETRIES = 2

      def initialize(client:, organization_id:, ipa_path:, apple_app_id:,
                     cf_bundle_version:, cf_bundle_short_version_string:,
                     platform: 'IOS', poll_interval: POLL_INTERVAL, poll_timeout: POLL_TIMEOUT)
        @client = client
        @org_id = organization_id
        @ipa_path = ipa_path
        @apple_app_id = apple_app_id
        @cf_bundle_version = cf_bundle_version
        @cf_bundle_short_version_string = cf_bundle_short_version_string
        @platform = platform
        @poll_interval = poll_interval
        @poll_timeout = poll_timeout
      end

      def call
        begin
          resp = @client.post(
            "/api/v1/organizations/#{@org_id}/builds/asc_upload",
            body: {
              apple_app_id: @apple_app_id,
              cf_bundle_version: @cf_bundle_version,
              cf_bundle_short_version_string: @cf_bundle_short_version_string,
              platform: @platform,
              file_name: File.basename(@ipa_path),
              file_size: File.size(@ipa_path)
            }
          )
        rescue StandardError => e
          # Apple returns 409 from /v1/buildUploads when a build with the
          # same CFBundleVersion already exists for this app. Surface a
          # useful message instead of letting the caller print the raw
          # "ASC /v1/buildUploads returned 409" string.
          if e.message =~ /\b(409|buildUploads returned 409|duplicate)/i
            raise BuildVersionConflictError,
                  "Apple refused the upload: build #{@cf_bundle_version} already exists for this app (CFBundleVersion must be unique). " \
                  'Bump CFBundleVersion in your Xcode project and re-archive, then retry.'
          end
          raise
        end
        data = resp[:data]
        build_upload_id = data['build_upload_id']
        ops             = data['upload_operations']

        File.open(@ipa_path, 'rb') do |f|
          ops.each { |op| put_chunk_with_retry(f, op) }
        end

        md5 = Digest::MD5.file(@ipa_path).hexdigest
        sha = Digest::SHA256.file(@ipa_path).hexdigest

        @client.patch(
          "/api/v1/organizations/#{@org_id}/builds/asc_upload/#{build_upload_id}",
          body: { uploaded: true, source_file_checksums: { md5: md5, sha256: sha } }
        )

        final = poll_until_terminal(build_upload_id)
        { build_upload_id: build_upload_id, final_state: final }
      end

      private

      def put_chunk_with_retry(file, operation)
        # Defense-in-depth: Apple's signed URLs are always https. If the
        # server ever returns an http:// URL, refuse to PUT the chunk — that
        # would leak the .ipa bytes (and auth headers) in clear text.
        scheme = URI.parse(operation['url'].to_s).scheme
        raise "refusing non-https upload URL (scheme=#{scheme.inspect})" unless scheme == 'https'

        file.seek(operation['offset'])
        bytes = file.read(operation['length'])
        attempts = 0
        begin
          conn = Faraday.new { |f| f.adapter Faraday.default_adapter }
          resp = conn.public_send(operation['method'].downcase) do |req|
            req.url operation['url']
            (operation['requestHeaders'] || []).each { |h| req.headers[h['name']] = h['value'] }
            req.body = bytes
          end
          raise "chunk PUT failed #{resp.status}" unless resp.status.between?(200, 299)
        rescue StandardError
          attempts += 1
          retry if attempts <= CHUNK_RETRIES
          raise
        end
      end

      def poll_until_terminal(build_upload_id)
        deadline = Time.now + @poll_timeout
        loop do
          resp = @client.get("/api/v1/organizations/#{@org_id}/builds/asc_upload/#{build_upload_id}")
          state = resp[:data]['apple_state']
          return state if TERMINAL_APPLE_STATES.include?(state)
          return 'TIMEOUT' if Time.now > deadline

          sleep @poll_interval
        end
      end
    end
  end
end
