# frozen_string_literal: true

require 'digest'
require 'faraday'
require 'fileutils'
require 'json'
require 'open3'
require 'uri'

module Mysigner
  module Upload
    class AscRestUploader
      # Raised when Apple rejects the build for a duplicate CFBundleVersion.
      # In vault mode this surfaces as a 409 on /v1/buildUploads; in
      # local-only mode altool prints an ITMS-90... "build version already
      # exists" diagnostic. Both translate to this same class so the CLI
      # rescue can give the user one consistent "bump your build number" hint.
      class BuildVersionConflictError < StandardError; end

      # Raised when local-only mode is requested but no ASC credentials are
      # stored in the LocalCredentials store. The message points users at the
      # onboard flow that persists the credentials (mysigner-44). We refuse to
      # silently fall back to the server path — local-only must fail loud.
      class MissingLocalCredentialsError < StandardError; end

      # Raised when altool fails for any reason OTHER than the
      # BuildVersionConflictError case. Carries altool's own error code and
      # message verbatim — we deliberately do NOT blanket-map every altool
      # failure to a generic "upload failed" string. WHY: the previous
      # implementation mapped every 409 to BuildVersionConflictError and
      # silently hid real causes (attribute-shape mismatches, signature
      # rejections, expired tokens). Surfacing altool's exact error is the
      # only way the user can act on it.
      class AltoolUploadError < StandardError; end

      TERMINAL_APPLE_STATES = %w[COMPLETE FAILED INVALIDATED].freeze
      POLL_INTERVAL = 10
      POLL_TIMEOUT  = 600
      CHUNK_RETRIES = 2

      APPLE_ASC_BASE = 'https://api.appstoreconnect.apple.com'

      # Apple's hardcoded discovery path for ASC private keys. `altool
      # --apiKey KEY_ID` looks for AuthKey_<KEY_ID>.p8 in this directory
      # (and only this directory) — no flag exists to override it. We ensure
      # the .p8 lives here before invoking altool.
      APPLE_PRIVATE_KEYS_DIR = File.expand_path('~/.appstoreconnect/private_keys').freeze

      def initialize(client:, organization_id:, ipa_path:, apple_app_id:,
                     cf_bundle_version:, cf_bundle_short_version_string:,
                     platform: 'IOS', poll_interval: POLL_INTERVAL, poll_timeout: POLL_TIMEOUT,
                     local_only: false, asc_creds: nil)
        @client = client
        @org_id = organization_id
        @ipa_path = ipa_path
        @apple_app_id = apple_app_id
        @cf_bundle_version = cf_bundle_version
        @cf_bundle_short_version_string = cf_bundle_short_version_string
        @platform = platform
        @poll_interval = poll_interval
        @poll_timeout = poll_timeout
        @local_only = local_only
        # mysigner-22 Phase 5 — pre-resolved AscCreds Struct from the
        # CredentialResolver cascade. When nil (legacy callers / unit tests),
        # we fall back to the resolver inside resolve_asc_creds with default
        # args (which preserves the Keychain-only behavior the existing specs
        # pin).
        @asc_creds = asc_creds
      end

      def call
        return call_altool! if @local_only

        build_upload_id, ops = create_build_upload_via_server

        File.open(@ipa_path, 'rb') do |f|
          ops.each { |op| put_chunk_with_retry(f, op) }
        end

        md5 = Digest::MD5.file(@ipa_path).hexdigest
        sha = Digest::SHA256.file(@ipa_path).hexdigest

        mark_uploaded_via_server(build_upload_id, md5: md5, sha: sha)

        final = poll_until_terminal_via_server(build_upload_id)
        { build_upload_id: build_upload_id, final_state: final }
      end

      private

      # Local-only: shell out to `xcrun altool --upload-app`. altool is
      # Apple's canonical CLI for App Store uploads — it handles the multi-
      # step buildUploads/buildUploadFiles/chunk-PUT/commit dance correctly
      # (we previously tried to reimplement it via raw REST and got the
      # payload shape wrong, see mysigner-46). After altool exits 0 the
      # upload is complete; altool itself polls Apple's transporter to
      # completion, so we don't need to poll on our side.
      #
      # Return contract matches the vault path: {build_upload_id, final_state}.
      # altool doesn't surface the buildUploads id, so we return nil for it —
      # callers should already tolerate a nil id (vault mode is the only one
      # that uses it for follow-up calls).
      def call_altool!
        creds = resolve_asc_creds_for_altool
        ensure_p8_in_apple_dir!(creds)

        argv = altool_argv(creds)
        stdout_stderr, status = Open3.capture2e(*argv)

        return { build_upload_id: nil, final_state: 'COMPLETE' } if status.success?

        raise_altool_failure!(stdout_stderr)
      end

      # `xcrun altool --upload-app --file ... --type ios --apiKey KEY_ID
      # --apiIssuer ISSUER_UUID --output-format json`. We pass each token as
      # its own argv element (no shell) so paths with spaces / weird chars
      # can't break the invocation or open injection holes.
      def altool_argv(creds)
        [
          'xcrun', 'altool', '--upload-app',
          '--file', @ipa_path,
          '--type', altool_platform_for(@platform),
          '--apiKey', creds.key_id,
          '--apiIssuer', creds.issuer_id,
          '--output-format', 'json'
        ]
      end

      # altool uses lowercase platform tokens distinct from Apple's REST
      # buildUploads platform names. Map them explicitly; default to ios so
      # legacy callers that omit @platform still work.
      def altool_platform_for(platform)
        case platform.to_s.upcase
        when 'MAC_OS', 'MACOS' then 'macos'
        when 'TV_OS', 'TVOS'   then 'tvos'
        else 'ios'
        end
      end

      # altool requires the .p8 at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
      # There is no flag override — this is hardcoded in Apple's binary.
      # AscCreds carries the PEM bytes (read from flag/env/keychain/disk by
      # CredentialResolver) but not the original on-disk path, so we write
      # the bytes to the canonical location. Idempotent: skip the write when
      # the file already contains the exact same PEM. We use 0600 perms
      # because this file holds a private key.
      def ensure_p8_in_apple_dir!(creds)
        FileUtils.mkdir_p(APPLE_PRIVATE_KEYS_DIR, mode: 0o700)
        target = File.join(APPLE_PRIVATE_KEYS_DIR, "AuthKey_#{creds.key_id}.p8")

        if File.exist?(target) && File.read(target) == creds.p8_pem
          File.chmod(0o600, target)
          return target
        end

        File.write(target, creds.p8_pem)
        File.chmod(0o600, target)
        target
      end

      # Parse altool's --output-format json blob. The error path is:
      #   { "product-errors": [ { "code": ..., "message": "..." }, ... ] }
      # Any "build version already exists" diagnostic — Apple's ITMS-90... —
      # maps to BuildVersionConflictError so the CLI rescue gives the same
      # "bump CFBundleVersion" hint as the vault path. Everything else
      # raises AltoolUploadError carrying altool's verbatim payload (we
      # deliberately do NOT blanket-map: that masked real bugs before).
      def raise_altool_failure!(combined_output)
        parsed = parse_altool_json(combined_output)
        errors = Array(parsed && parsed['product-errors'])

        if errors.any? { |e| build_version_conflict?(e) }
          raise BuildVersionConflictError,
                "Apple refused the upload: build #{@cf_bundle_version} already exists for this app (CFBundleVersion must be unique). " \
                'Bump CFBundleVersion in your Xcode project and re-archive, then retry.'
        end

        raise AltoolUploadError, altool_error_message(errors, combined_output)
      end

      # altool prints diagnostics interleaved with the JSON on stdout/stderr.
      # We scan for the first balanced { ... } block that parses as JSON;
      # when none is found we return nil so the caller falls back to the raw
      # combined output.
      def parse_altool_json(text)
        return nil if text.nil? || text.empty?

        start = text.index('{')
        return nil if start.nil?

        # Try progressively longer balanced slices. altool's JSON is small
        # enough that O(n^2) here is fine and far simpler than a full parser.
        tail = text[start..]
        (0...tail.length).each do |len|
          candidate = tail[0..len]
          next unless candidate.end_with?('}')

          begin
            return JSON.parse(candidate)
          rescue JSON::ParserError
            next
          end
        end
        nil
      end

      # The canonical "duplicate build" diagnostic is ITMS-90... with the
      # phrase "build version" + "already exists" in the message. We match
      # on the phrase (case-insensitive) rather than the ITMS code so we
      # catch the family of variants Apple has shipped over the years.
      def build_version_conflict?(error)
        msg = error.is_a?(Hash) ? error['message'].to_s : error.to_s
        msg.match?(/build version.*already exists/i)
      end

      def altool_error_message(errors, combined_output)
        if errors.any?
          parts = errors.map do |e|
            code = e.is_a?(Hash) ? e['code'] : nil
            msg  = e.is_a?(Hash) ? e['message'] : e.to_s
            code ? "[#{code}] #{msg}" : msg.to_s
          end
          "altool --upload-app failed: #{parts.join(' | ')}"
        else
          "altool --upload-app failed (no parseable JSON errors): #{combined_output.strip}"
        end
      end

      def create_build_upload_via_server
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
        data = resp[:data]
        [data['build_upload_id'], data['upload_operations']]
      rescue StandardError => e
        # Apple returns 409 from /v1/buildUploads when a build with the
        # same CFBundleVersion already exists for this app. Surface a
        # useful message instead of letting the caller print the raw
        # "ASC /v1/buildUploads returned 409" string.
        raise unless e.message =~ /\b(409|buildUploads returned 409|duplicate)/i

        raise BuildVersionConflictError,
              "Apple refused the upload: build #{@cf_bundle_version} already exists for this app (CFBundleVersion must be unique). " \
              'Bump CFBundleVersion in your Xcode project and re-archive, then retry.'
      end

      def mark_uploaded_via_server(build_upload_id, md5:, sha:)
        @client.patch(
          "/api/v1/organizations/#{@org_id}/builds/asc_upload/#{build_upload_id}",
          body: { uploaded: true, source_file_checksums: { md5: md5, sha256: sha } }
        )
      end

      # Resolves ASC creds via the cascade for the altool path. Translates
      # CredentialResolver errors into MissingLocalCredentialsError so the
      # existing CLI rescue + the "No local ASC credentials found" wording
      # the specs pin on continue to work.
      def resolve_asc_creds_for_altool
        @asc_creds || resolve_asc_creds
      end

      def resolve_asc_creds
        require 'mysigner/credential_resolver'
        # Default: no Thor options, no env vars guaranteed — this preserves
        # the "Keychain-only" behavior the existing local_only specs assert
        # on (they stub LocalCredentials and don't expect any other tier to
        # win). The CLI passes an asc_creds: that was resolved with the real
        # Thor options/env/stdin.
        Mysigner::CredentialResolver.resolve_asc
      rescue Mysigner::CredentialResolver::CredentialNotFoundError, Mysigner::CredentialResolver::AmbiguousCredentialsError => e
        # Keep the historic error class so CLI rescue / upstream specs that
        # rescue on MissingLocalCredentialsError still work; the message now
        # carries the resolver's "tried in order + override knobs" block.
        raise MissingLocalCredentialsError, rewrite_resolver_error(e.message)
      end

      # Make the resolver's text match the historical wording the CLI rescue
      # specs were written against, without losing the resolver's richer
      # cascade info. WHY: callers regex-match on "No local ASC credentials
      # found" — preserving that string is cheaper than churning every spec.
      def rewrite_resolver_error(text)
        if text.start_with?('No usable App Store Connect credentials found')
          "No local ASC credentials found via `mysigner onboard --local-only`. #{text}"
        else
          text
        end
      end

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

      def poll_until_terminal_via_server(build_upload_id)
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
