# frozen_string_literal: true

require 'json'
require 'mysigner/formatting'

module Mysigner
  module Upload
    class PlayStoreUploader
      class UploadError < Mysigner::Error; end
      class CredentialsError < UploadError; end
      class TrackError < UploadError; end

      # Raised when local-only mode is requested but no Google Play credentials
      # are stored in the LocalCredentials store. The message points users at
      # `mysigner onboard --local-only` (mysigner-44) which is what persists
      # them. We refuse to silently fall back to the server path — local-only
      # must fail loud. Defined locally (not shared with AscRestUploader) so
      # each uploader owns its own error contract.
      class MissingLocalCredentialsError < UploadError; end

      # Special error for when AAB uploaded but track assignment failed
      # This carries the version_code so it can be saved to prevent conflicts
      class PartialUploadError < UploadError
        attr_reader :version_code

        def initialize(message, version_code:)
          super(message)
          @version_code = version_code
        end
      end

      VALID_TRACKS = %w[internal alpha beta production].freeze
      SCOPE = 'https://www.googleapis.com/auth/androidpublisher'

      # mysigner-22 follow-up — pre-check the user's project versionCode
      # against what's already on Google Play in local-only mode, where the
      # MySigner server's `highest_version_code` lookup is bypassed. The
      # cheapest authenticated way to ask Google "what's already there" is
      # to insert an edit, list all uploaded bundles (which carry their
      # versionCode), and discard the edit. Inserting an edit is free and
      # has no side effect when never committed.
      #
      # Returns the maximum versionCode across all bundles (Integer), or
      # nil when the app has no bundles yet (very first upload).
      def self.fetch_highest_version_code(package_name:, access_token:)
        require 'google/apis/androidpublisher_v3'

        service = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
        service.authorization = access_token

        edit = service.insert_edit(package_name, Google::Apis::AndroidpublisherV3::AppEdit.new)
        begin
          bundles_response = service.list_edit_bundles(package_name, edit.id)
          version_codes = Array(bundles_response&.bundles).map(&:version_code).compact
          return nil if version_codes.empty?

          version_codes.max
        ensure
          # Best-effort cleanup — the edit auto-expires after a week if we
          # leak one, but tidiness is cheap. Swallow errors so a transient
          # cleanup failure can't mask the real return value.
          begin
            service.delete_edit(package_name, edit.id)
          rescue StandardError
            nil
          end
        end
      rescue Google::Apis::ClientError
        # We treat a lookup failure (auth issue, package-not-found) as
        # "unknown" rather than fatal — Google will still reject at upload
        # time with a useful message. This pre-check is best-effort.
        nil
      end

      # Phase 0: accepts a short-lived OAuth2 access_token (minted server-side
      # from the customer's service-account JSON). The JSON no longer leaves
      # the server. google-api-ruby-client accepts a bare string for
      # authorization= and sends it as `Authorization: Bearer <token>`.
      #
      # mysigner-43: when `local_only: true`, `access_token` is optional —
      # the uploader mints one locally from Keychain-backed SA-JSON. The
      # SA-JSON never leaves the user's machine, and no MySigner server
      # credential endpoints are contacted.
      def initialize(aab_path:, package_name:, access_token: nil, local_only: false, play_creds: nil)
        @aab_path = File.expand_path(aab_path)
        @access_token = access_token
        @package_name = package_name
        @local_only = local_only
        # mysigner-22 Phase 5 — pre-resolved PlayCreds Struct from the
        # CredentialResolver cascade. When nil (legacy / unit tests), we fall
        # back to the resolver with default args (Keychain only) inside
        # local_access_token — preserving existing spec invariants.
        @play_creds = play_creds

        if @local_only
          # Mint immediately so missing-credentials errors surface at
          # construction time (same DX as the server path's
          # CredentialsError) rather than mid-upload.
          @access_token = local_access_token
        elsif @access_token.nil? || @access_token.to_s.empty?
          raise CredentialsError, 'access_token is required'
        end

        validate_aab!
        setup_google_client!
      end

      # Upload AAB and optionally assign to a track
      # @param track [String] Track to assign: internal, alpha, beta, production
      # @param release_notes [Hash] Localized release notes { 'en-US' => 'What\'s new...' }
      # @param user_fraction [Float] Rollout percentage (0.0-1.0) for staged rollouts
      # @param status [String] Explicit release status: draft | inProgress | completed.
      #   Overrides the user_fraction-derived default. `draft` is useful for
      #   "upload, don't release yet" flows that iOS-MANUAL users expect.
      # @param in_app_update_priority [Integer] 0–5 priority hint for in-app update flows
      # @param release_name [String] Optional release name (defaults to AAB versionName)
      # @param country_targeting [Hash] { countries: ['US','CA'], include_rest_of_world: false }
      # @param changes_not_sent_for_review [Boolean] Skip submitting changes to Play review on commit
      # @return [Hash] Upload result with version_code and track info
      def upload!(track: 'internal', release_notes: nil, user_fraction: nil,
                  status: nil, in_app_update_priority: nil, release_name: nil,
                  country_targeting: nil, changes_not_sent_for_review: nil)
        @current_track = track # Store for error messages
        say_uploading(track)

        version_code = nil

        begin
          # 1. Create an edit
          edit = create_edit

          # 2. Upload the AAB
          bundle = upload_bundle(edit.id)
          version_code = bundle.version_code

          say_upload_success(version_code)

          # 3. Assign to track with release
          if track
            assign_to_track(
              edit.id, track, version_code,
              release_notes: release_notes,
              user_fraction: user_fraction,
              status: status,
              in_app_update_priority: in_app_update_priority,
              release_name: release_name,
              country_targeting: country_targeting
            )
          end

          # 4. Commit the edit
          commit_edit(edit.id, changes_not_sent_for_review: changes_not_sent_for_review)

          say_success(track, version_code)

          {
            success: true,
            version_code: version_code,
            track: track,
            package_name: @package_name
          }
        rescue Google::Apis::ClientError => e
          error_message = parse_google_error(e)
          # If AAB was uploaded, raise PartialUploadError so CLI can save the version
          raise PartialUploadError.new("Google Play API error: #{error_message}", version_code: version_code) if version_code

          raise UploadError, "Google Play API error: #{error_message}"
        rescue PartialUploadError
          # Re-raise as-is
          raise
        rescue StandardError => e
          raise PartialUploadError.new("Upload failed: #{e.message}", version_code: version_code) if version_code

          raise UploadError, "Upload failed: #{e.message}"
        end
      end

      # Upload AAB only (without assigning to track)
      def upload_bundle_only!
        say_uploading(nil)

        begin
          edit = create_edit
          bundle = upload_bundle(edit.id)
          version_code = bundle.version_code

          say_upload_success(version_code)

          # Don't assign to track, just commit
          commit_edit(edit.id)

          {
            success: true,
            version_code: version_code,
            package_name: @package_name
          }
        rescue Google::Apis::ClientError => e
          error_message = parse_google_error(e)
          raise UploadError, "Google Play API error: #{error_message}"
        rescue StandardError => e
          raise UploadError, "Upload failed: #{e.message}"
        end
      end

      # Assign an existing version code to a track
      def assign_existing_to_track!(version_code, track:, release_notes: nil, user_fraction: nil)
        @current_track = track # Store for error messages
        begin
          edit = create_edit
          assign_to_track(edit.id, track, version_code, release_notes: release_notes, user_fraction: user_fraction)
          commit_edit(edit.id)

          {
            success: true,
            version_code: version_code,
            track: track,
            package_name: @package_name
          }
        rescue Google::Apis::ClientError => e
          error_message = parse_google_error(e)
          raise TrackError, "Failed to assign to track: #{error_message}"
        end
      end

      private

      def validate_aab!
        raise UploadError, "AAB file not found: #{@aab_path}" unless File.exist?(@aab_path)

        raise UploadError, "Invalid file type: #{@aab_path} (must be .aab)" unless @aab_path.end_with?('.aab')

        file_size = File.size(@aab_path)
        return unless file_size < 10_000

        raise UploadError, "AAB file seems too small: #{file_size} bytes (possible corruption)"
      end

      def setup_google_client!
        require 'google/apis/androidpublisher_v3'

        # Create service with the bare bearer token. google-api-ruby-client
        # sends a string authorization as `Authorization: Bearer <string>`.
        @service = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
        @service.authorization = @access_token
        @service.client_options.open_timeout_sec = 30
        @service.client_options.read_timeout_sec = 300 # Large file uploads need time
        @service.request_options.retries = 3
      rescue LoadError
        raise CredentialsError, 'Google API client not installed. Run: gem install google-api-client'
      end

      # mysigner-43 + mysigner-22 Phase 5: look up the Google Play SA-JSON
      # through the CredentialResolver cascade (flag → env → keychain →
      # project sniff → prompt) and mint a short-lived OAuth2 access_token.
      # The SA-JSON never leaves the process; the MySigner server is never
      # contacted.
      def local_access_token
        require 'mysigner/auth/google_oauth_minter'
        creds = @play_creds || resolve_play_creds
        Mysigner::Auth::GoogleOauthMinter.new(creds.sa_json).mint(scope: SCOPE)
      end

      def resolve_play_creds
        require 'mysigner/credential_resolver'
        Mysigner::CredentialResolver.resolve_play
      rescue Mysigner::CredentialResolver::CredentialNotFoundError, Mysigner::CredentialResolver::AmbiguousCredentialsError => e
        raise MissingLocalCredentialsError, rewrite_resolver_error(e.message)
      end

      def rewrite_resolver_error(text)
        if text.start_with?('No usable Google Play credentials found')
          "No local Google Play credentials found via `mysigner onboard --local-only`. #{text}"
        else
          text
        end
      end

      def create_edit
        edit = Google::Apis::AndroidpublisherV3::AppEdit.new
        @service.insert_edit(@package_name, edit)
      rescue Google::Apis::ClientError => e
        raise UploadError, first_upload_error_message if e.message.include?('Package not found') || e.status_code == 404

        raise
      end

      def first_upload_error_message
        <<~MSG
          Google Play API can't find package '#{@package_name}'.

          This happens when no build has been uploaded to this app yet.
          Google Play API requires the FIRST build to be uploaded manually.

          To fix:
            1. Build AAB: mysigner android build
            2. Go to Play Console → Your App → Internal testing → Create release
            3. Upload the AAB file shown in the build output
            4. Save the release (don't need to roll out)

          After that, mysigner ship will work for all future uploads.
        MSG
      end

      def upload_bundle(edit_id)
        puts "📦 Uploading AAB (#{format_bytes(File.size(@aab_path))})..."
        puts ''

        begin
          @service.upload_edit_bundle(
            @package_name,
            edit_id,
            upload_source: @aab_path,
            content_type: 'application/octet-stream'
          )
        rescue Google::Apis::ClientError => e
          error_msg = parse_google_error(e)
          raise UploadError, "Bundle upload failed: #{error_msg}"
        rescue StandardError => e
          raise UploadError, "Bundle upload failed: #{e.message}"
        end
      end

      def assign_to_track(edit_id, track, version_code, release_notes: nil, user_fraction: nil,
                          status: nil, in_app_update_priority: nil, release_name: nil,
                          country_targeting: nil)
        raise TrackError, "Invalid track '#{track}'. Valid tracks: #{VALID_TRACKS.join(', ')}" unless VALID_TRACKS.include?(track)

        puts "🚂 Assigning to #{track} track..."

        # Status precedence: explicit `status:` arg > user_fraction-derived >
        # completed. Google Play rejects `userFraction` outside (0,1) and also
        # rejects it when status != inProgress, so we clear it when the
        # caller-provided status is non-rollout.
        effective_status = if status && %w[draft inProgress halted completed].include?(status)
                             status
                           elsif user_fraction
                             'inProgress'
                           else
                             'completed'
                           end

        release = Google::Apis::AndroidpublisherV3::TrackRelease.new(
          version_codes: [version_code.to_s],
          status: effective_status
        )

        release.name = release_name if release_name

        if release_notes&.any?
          release.release_notes = release_notes.map do |lang, text|
            Google::Apis::AndroidpublisherV3::LocalizedText.new(
              language: lang,
              text: text
            )
          end
        end

        release.user_fraction = user_fraction if user_fraction && effective_status == 'inProgress'
        release.in_app_update_priority = in_app_update_priority if in_app_update_priority

        if country_targeting.is_a?(Hash) && country_targeting[:countries].is_a?(Array) && country_targeting[:countries].any?
          release.country_targeting = Google::Apis::AndroidpublisherV3::CountryTargeting.new(
            countries: country_targeting[:countries],
            include_rest_of_world: country_targeting.fetch(:include_rest_of_world, false)
          )
        end

        track_obj = Google::Apis::AndroidpublisherV3::Track.new(
          track: track,
          releases: [release]
        )

        @service.update_edit_track(@package_name, edit_id, track, track_obj)
      end

      # Commit the edit. When `changes_not_sent_for_review` is nil (the
      # historical default) we opt-in (true) and fall back to false if Google
      # rejects — some apps have Play-managed review that forbids the flag.
      # When the caller passes an explicit boolean (from cli_defaults), we
      # pass it through without the fallback retry.
      def commit_edit(edit_id, changes_not_sent_for_review: nil)
        puts '💾 Committing changes...'

        if changes_not_sent_for_review.nil?
          begin
            @service.commit_edit(@package_name, edit_id, changes_not_sent_for_review: true)
          rescue Google::Apis::ClientError => e
            error_text = e.message.to_s
            error_text += " #{e.body}" if e.respond_to?(:body) && e.body
            raise unless error_text.include?('changesNotSentForReview')

            @service.commit_edit(@package_name, edit_id)
          end
        else
          @service.commit_edit(@package_name, edit_id, changes_not_sent_for_review: !!changes_not_sent_for_review)
        end
      end

      def parse_google_error(error)
        body = nil
        if error.respond_to?(:body) && error.body
          body = begin
            JSON.parse(error.body)
          rescue StandardError
            nil
          end
        end

        message = body&.dig('error', 'message') || error.message
        details = body&.dig('error', 'errors')&.map { |e| e['message'] }&.join('; ')
        full_message = details ? "#{message} (#{details})" : message

        # Provide helpful context for common errors
        case full_message.to_s.downcase
        when /package.*not found/i, /app not found/i
          "#{full_message}\n\n💡 Make sure the package name '#{@package_name}' matches your app in Google Play Console."
        when /not authorized/i, /permission denied/i, /forbidden/i
          "#{full_message}\n\n💡 Check that your service account has Editor or Admin access to the app in Google Play Console."
        when /version.*code.*already/i, /already.*used/i
          "#{full_message}\n\n💡 Version code already exists. Increment versionCode in android/app/build.gradle and rebuild."
        when /precondition.*check.*failed/i, /precondition.*failed/i
          track_name = @current_track || 'this track'
          "#{full_message}\n\n" \
            "💡 Google Play Console requires setup before publishing to #{track_name}:\n\n   " \
            "For PRODUCTION track:\n   " \
            "• Complete store listing (description, screenshots, etc.)\n   " \
            "• Set content rating\n   " \
            "• Configure pricing & distribution\n\n   " \
            "For BETA/ALPHA tracks:\n   " \
            "• Create a closed/open testing track in Play Console\n   " \
            "• Add at least one tester email\n\n   " \
            "For INTERNAL track:\n   " \
            "• Add internal testers in Play Console\n\n   " \
            "✅ Your AAB was uploaded successfully!\n   " \
            "→ Go to Play Console to complete track setup, then use:\n     " \
            "mysigner submit #{track_name} --platform android --version-code VERSION"
        when /invalid request/i
          "#{full_message}\n\n💡 Common causes:\n   " \
          "• Version code not found on Google Play (must upload first)\n   " \
          "• App not created in Google Play Console\n   " \
          '• Service account missing permissions'
        when /signing/i, /signature/i
          "#{full_message}\n\n💡 The AAB may not be signed with the correct key. Check your keystore matches what's registered in Play Console."
        else
          full_message
        end
      rescue StandardError => e
        "#{error.message} (parsing error: #{e.message})"
      end

      def say_uploading(track)
        puts "☁️  Uploading to Google Play#{" (#{track} track)" if track}..."
        puts ''
        puts "AAB:         #{File.basename(@aab_path)}"
        puts "Size:        #{format_bytes(File.size(@aab_path))}"
        puts "Package:     #{@package_name}"
        puts "Track:       #{track || 'none (upload only)'}"
        puts ''
      end

      def say_upload_success(version_code)
        puts "✓ Bundle uploaded successfully (version code: #{version_code})"
        puts ''
      end

      def say_success(track, version_code)
        puts ''
        puts '=' * 80
        puts '✓ Upload complete!'
        puts '=' * 80
        puts ''
        puts "🎉 Your app is now on Google Play (#{track} track)"
        puts ''
        puts "Version Code: #{version_code}"
        puts "Package:      #{@package_name}"
        puts "Track:        #{track}"
        puts ''
      end

      def format_bytes(bytes)
        Mysigner::Formatting.format_bytes(bytes)
      end
    end
  end
end
