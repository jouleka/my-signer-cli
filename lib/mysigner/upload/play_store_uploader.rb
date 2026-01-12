require 'json'
require 'stringio'

module Mysigner
  module Upload
    class PlayStoreUploader
      class UploadError < Mysigner::Error; end
      class CredentialsError < UploadError; end
      class TrackError < UploadError; end
      
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
      SCOPE = 'https://www.googleapis.com/auth/androidpublisher'.freeze

      def initialize(aab_path:, service_account_json:, package_name:)
        @aab_path = File.expand_path(aab_path)
        @service_account_json = service_account_json
        @package_name = package_name

        validate_aab!
        setup_google_client!
      end

      # Upload AAB and optionally assign to a track
      # @param track [String] Track to assign: internal, alpha, beta, production
      # @param release_notes [Hash] Localized release notes { 'en-US' => 'What\'s new...' }
      # @param user_fraction [Float] Rollout percentage (0.0-1.0) for staged rollouts
      # @return [Hash] Upload result with version_code and track info
      def upload!(track: 'internal', release_notes: nil, user_fraction: nil)
        @current_track = track  # Store for error messages
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
            assign_to_track(edit.id, track, version_code, release_notes: release_notes, user_fraction: user_fraction)
          end

          # 4. Commit the edit
          commit_edit(edit.id)

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
          if version_code
            raise PartialUploadError.new("Google Play API error: #{error_message}", version_code: version_code)
          else
            raise UploadError, "Google Play API error: #{error_message}"
          end
        rescue PartialUploadError
          # Re-raise as-is
          raise
        rescue => e
          if version_code
            raise PartialUploadError.new("Upload failed: #{e.message}", version_code: version_code)
          else
            raise UploadError, "Upload failed: #{e.message}"
          end
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
        rescue => e
          raise UploadError, "Upload failed: #{e.message}"
        end
      end

      # Assign an existing version code to a track
      def assign_existing_to_track!(version_code, track:, release_notes: nil, user_fraction: nil)
        @current_track = track  # Store for error messages
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
        unless File.exist?(@aab_path)
          raise UploadError, "AAB file not found: #{@aab_path}"
        end

        unless @aab_path.end_with?('.aab')
          raise UploadError, "Invalid file type: #{@aab_path} (must be .aab)"
        end

        file_size = File.size(@aab_path)
        if file_size < 10_000
          raise UploadError, "AAB file seems too small: #{file_size} bytes (possible corruption)"
        end
      end

      def setup_google_client!
        require 'googleauth'
        require 'google/apis/androidpublisher_v3'

        # Parse and validate service account JSON
        begin
          @credentials_data = JSON.parse(@service_account_json)
        rescue JSON::ParserError => e
          raise CredentialsError, "Invalid service account JSON: #{e.message}"
        end

        # Build authorization
        @auth = Google::Auth::ServiceAccountCredentials.make_creds(
          json_key_io: StringIO.new(@service_account_json),
          scope: SCOPE
        )

        # Create service
        @service = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
        @service.authorization = @auth
        @service.client_options.open_timeout_sec = 30
        @service.client_options.read_timeout_sec = 300  # Large file uploads need time
        @service.request_options.retries = 3

      rescue LoadError => e
        raise CredentialsError, "Google API client not installed. Run: gem install google-api-client"
      end

      def create_edit
        edit = Google::Apis::AndroidpublisherV3::AppEdit.new
        @service.insert_edit(@package_name, edit)
      rescue Google::Apis::ClientError => e
        if e.message.include?("Package not found") || e.status_code == 404
          raise UploadError, first_upload_error_message
        end
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
        puts ""

        begin
          result = @service.upload_edit_bundle(
            @package_name,
            edit_id,
            upload_source: @aab_path,
            content_type: 'application/octet-stream'
          )
          result
        rescue Google::Apis::ClientError => e
          error_msg = parse_google_error(e)
          raise UploadError, "Bundle upload failed: #{error_msg}"
        rescue => e
          raise UploadError, "Bundle upload failed: #{e.message}"
        end
      end

      def assign_to_track(edit_id, track, version_code, release_notes: nil, user_fraction: nil)
        unless VALID_TRACKS.include?(track)
          raise TrackError, "Invalid track '#{track}'. Valid tracks: #{VALID_TRACKS.join(', ')}"
        end

        puts "🚂 Assigning to #{track} track..."

        # Build release
        release = Google::Apis::AndroidpublisherV3::TrackRelease.new(
          version_codes: [version_code.to_s],
          status: user_fraction ? 'inProgress' : 'completed'
        )

        # Add release notes if provided
        if release_notes && release_notes.any?
          release.release_notes = release_notes.map do |lang, text|
            Google::Apis::AndroidpublisherV3::LocalizedText.new(
              language: lang,
              text: text
            )
          end
        end

        # Add user fraction for staged rollouts
        if user_fraction
          release.user_fraction = user_fraction
        end

        # Build track update
        track_obj = Google::Apis::AndroidpublisherV3::Track.new(
          track: track,
          releases: [release]
        )

        @service.update_edit_track(@package_name, edit_id, track, track_obj)
      end

      def commit_edit(edit_id)
        puts "💾 Committing changes..."
        begin
          # Try with changesNotSentForReview first (for apps without managed review)
          @service.commit_edit(@package_name, edit_id, changes_not_sent_for_review: true)
        rescue Google::Apis::ClientError => e
          error_text = e.message.to_s
          # Also check body if present
          if e.respond_to?(:body) && e.body
            error_text += " #{e.body}"
          end
          
          if error_text.include?('changesNotSentForReview')
            # App has managed review enabled, commit without the flag
            @service.commit_edit(@package_name, edit_id)
          else
            raise
          end
        end
      end

      def parse_google_error(error)
        begin
          body = nil
          if error.respond_to?(:body) && error.body
            body = JSON.parse(error.body) rescue nil
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
            track_name = @current_track || "this track"
            "#{full_message}\n\n" \
            "💡 Google Play Console requires setup before publishing to #{track_name}:\n\n" \
            "   For PRODUCTION track:\n" \
            "   • Complete store listing (description, screenshots, etc.)\n" \
            "   • Set content rating\n" \
            "   • Configure pricing & distribution\n\n" \
            "   For BETA/ALPHA tracks:\n" \
            "   • Create a closed/open testing track in Play Console\n" \
            "   • Add at least one tester email\n\n" \
            "   For INTERNAL track:\n" \
            "   • Add internal testers in Play Console\n\n" \
            "   ✅ Your AAB was uploaded successfully!\n" \
            "   → Go to Play Console to complete track setup, then use:\n" \
            "     mysigner submit #{track_name} --platform android --version-code VERSION"
          when /invalid request/i
            "#{full_message}\n\n💡 Common causes:\n" \
            "   • Version code not found on Google Play (must upload first)\n" \
            "   • App not created in Google Play Console\n" \
            "   • Service account missing permissions"
          when /signing/i, /signature/i
            "#{full_message}\n\n💡 The AAB may not be signed with the correct key. Check your keystore matches what's registered in Play Console."
          else
            full_message
          end
        rescue => parse_error
          "#{error.message} (parsing error: #{parse_error.message})"
        end
      end

      def say_uploading(track)
        puts "☁️  Uploading to Google Play#{track ? " (#{track} track)" : ''}..."
        puts ""
        puts "AAB:         #{File.basename(@aab_path)}"
        puts "Size:        #{format_bytes(File.size(@aab_path))}"
        puts "Package:     #{@package_name}"
        puts "Track:       #{track || 'none (upload only)'}"
        puts ""
      end

      def say_upload_success(version_code)
        puts "✓ Bundle uploaded successfully (version code: #{version_code})"
        puts ""
      end

      def say_success(track, version_code)
        puts ""
        puts "=" * 80
        puts "✓ Upload complete!"
        puts "=" * 80
        puts ""
        puts "🎉 Your app is now on Google Play (#{track} track)"
        puts ""
        puts "Version Code: #{version_code}"
        puts "Package:      #{@package_name}"
        puts "Track:        #{track}"
        puts ""
      end

      def format_bytes(bytes)
        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)} KB"
        else
          "#{(bytes / (1024.0 * 1024)).round(1)} MB"
        end
      end
    end
  end
end
