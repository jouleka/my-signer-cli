# frozen_string_literal: true

module Mysigner
  class CLI < Thor
    module Concerns
      module ErrorHandlers
        # Show guidance for getting a token
        def show_token_guidance(api_url)
          say "Don't have a token yet?", :yellow
          say "  1. Go to: #{api_url}", :cyan
          say '  2. Navigate to: Your Organization → API Tokens', :cyan
          say "  3. Click 'Create Token'", :cyan
          say "  4. Copy the token (you'll only see it once!)", :cyan
          say ''
          say "💡 Or run 'mysigner onboard' for step-by-step guidance", :yellow
          say ''
        end

        # Handle connection failure
        def handle_connection_failure(api_url)
          say ''
          say 'Possible issues:', :yellow
          say "  • API server is not running at #{api_url}"
          say '  • Network connectivity problems'
          say '  • Incorrect API URL'
          say ''
          say '💡 Try:', :cyan
          say '  • Check the API URL is correct'
          say '  • Verify the server is running'
          say "  • Run 'mysigner onboard' for guided setup"
        end

        # Show guidance for creating an organization
        def show_create_org_guidance(api_url)
          say 'To create an organization:', :cyan
          say "  1. Go to: #{api_url}"
          say '  2. Sign in to your account'
          say "  3. Click 'Create Organization'"
          say '  4. Then generate a new API token for that organization'
          say ''
          say "💡 Run 'mysigner onboard' for step-by-step guidance", :yellow
        end

        # Handle unauthorized error
        def handle_unauthorized_error(api_url)
          say ''
          say '=' * 80, :red
          say '✗ Authentication Failed', :red
          say '=' * 80, :red
          say ''
          say 'Your API token is invalid or has been revoked.', :bold
          say ''
          say 'Common reasons:', :yellow
          say '  • Token was copied incorrectly (missing characters)'
          say '  • Token was revoked in the web dashboard'
          say '  • Token has expired'
          say "  • You're using the wrong API URL"
          say ''
          say 'To fix this:', :cyan
          say "  1. Go to: #{api_url}/organizations/YOUR_ORG/api_tokens"
          say '  2. Check if your token is still active'
          say '  3. If revoked or expired, create a new token'
          say '  4. Copy the NEW token carefully (entire string)'
          say "  5. Run 'mysigner login' again"
          say ''
          say "💡 Or run 'mysigner onboard' for guided setup", :yellow
          say ''
        end

        # Handle connection error
        def handle_connection_error(error, api_url)
          say ''
          say '=' * 80, :red
          say '✗ Connection Failed', :red
          say '=' * 80, :red
          say ''
          say "Error: #{error.message}", :red
          say ''
          say 'Possible causes:', :yellow
          say "  • My Signer API is not running at #{api_url}"
          say '  • Network connectivity issues'
          say '  • Firewall blocking the connection'
          say '  • Incorrect API URL'
          say ''
          say 'To fix this:', :cyan
          say ''
          if api_url.include?('localhost') && ENV['MYSIGNER_DEV']
            say '  For My Signer backend development:', :bold
            say '    1. Start the Rails server: cd path/to/my-signer && bin/rails server'
            say "    2. Verify it's accessible: curl #{api_url}/up"
          else
            say '  To fix:', :bold
            say '    1. Check your internet connection'
            say '    2. Verify the API URL is correct: mysigner config show'
            say "    3. Don't need a My Signer account? Run any command with --local-only"
            say '       to sign with your own Apple/Google credentials.'
          end
          say ''
          say '  Or set a custom API URL:', :bold
          say '    export MYSIGNER_API_URL=http://your-server.com'
          say ''
          say "💡 Run 'mysigner onboard' to reconfigure", :yellow
          say ''
        end

        # Handle unexpected error
        def handle_unexpected_error(error, api_url)
          say ''
          say '=' * 80, :red
          say '✗ Unexpected Error', :red
          say '=' * 80, :red
          say ''
          say "Error: #{error.message}", :red
          say "Type: #{error.class}", :red if ENV['DEBUG']
          say ''
          say 'This is unexpected. Please try:', :yellow
          say "  1. Run 'mysigner onboard' to reconfigure"
          say "  2. Check #{api_url} is accessible"
          say "  3. Run 'mysigner doctor' to check your environment"
          say ''
          if ENV['DEBUG']
            say 'Stack trace:', :red
            say error.backtrace.first(5).join("\n"), :red
          else
            say '💡 For more details, run with DEBUG=1', :yellow
          end
          say ''
        end

        # Handle Apple API errors with actionable suggestions
        def handle_apple_api_error(error, context: {})
          error_message = error.message.to_s

          say ''
          say '=' * 80, :red
          say "✗ #{context[:title] || 'Apple API Error'}", :red
          say '=' * 80, :red
          say ''
          say "Error: #{error_message}", :red
          say ''

          if error.respond_to?(:suggestion) && error.suggestion
            say "Suggestion: #{error.suggestion}", :yellow
            say ''
          end

          # Check for specific Apple error patterns
          if error_message =~ /no.*build.*found|build.*not.*found|no.*processed.*build/i
            show_build_not_found_suggestions(context)
          elsif error_message =~ /still.*processing|processing.*build/i
            show_build_processing_suggestions
          elsif error_message =~ /profile.*expired|provisioning.*expired|certificate.*expired/i
            show_expired_credential_suggestions
          elsif error_message =~ /profile.*not.*found|no.*provisioning.*profile|missing.*profile/i
            show_profile_not_found_suggestions
          elsif error_message =~ /certificate.*not.*found|no.*signing.*certificate/i
            show_certificate_not_found_suggestions
          elsif error_message =~ /app.*with.*bundle.*id.*not.*found|app.*not.*found/i
            show_app_not_found_suggestions(context[:bundle_id])
          elsif error_message =~ /missing.*required.*field|what's.*new.*required|cannot.*submit.*missing/i
            show_missing_metadata_suggestions
          elsif error_message =~ /archive.*not.*found|no.*xcarchive/i
            show_archive_not_found_suggestions
          elsif error_message =~ /ipa.*not.*found|no.*ipa.*file/i
            show_ipa_not_found_suggestions
          elsif show_actionable_suggestions(error, platform: :ios)
            # Suggestions already shown
          else
            show_generic_apple_suggestions
          end

          show_saved_files(context)
          show_debug_info(error)
        end

        # Handle Google Play API errors with actionable suggestions
        def handle_android_api_error(error, context: {})
          error_message = error.message.to_s

          say ''
          say '=' * 80, :red
          say "✗ #{context[:title] || 'Google Play API Error'}", :red
          say '=' * 80, :red
          say ''
          say "Error: #{error_message}", :red
          say ''

          if error.respond_to?(:suggestion) && error.suggestion
            say "Suggestion: #{error.suggestion}", :yellow
            say ''
          end

          # Check for specific Google Play error patterns
          if error_message =~ /keystore.*not.*found|no.*keystore|missing.*keystore/i
            show_keystore_not_found_suggestions
          elsif error_message =~ /keystore.*password|wrong.*password/i
            show_keystore_password_suggestions
          elsif error_message =~ /package.*not.*found|first.*build.*uploaded.*manually/i
            show_first_upload_suggestions(context[:package_name])
          elsif error_message =~ /version.*code.*already|already.*used/i
            show_version_code_conflict_suggestions
          elsif error_message =~ /service.*account.*not.*found|no.*credentials/i
            show_service_account_missing_suggestions
          elsif error_message =~ /not.*authorized|permission.*denied|forbidden/i
            show_permission_denied_suggestions
          elsif error_message =~ /precondition.*failed|track.*not.*ready/i
            show_track_not_setup_suggestions(context[:track])
          elsif error_message =~ /aab.*not.*found|no.*aab.*file/i
            show_aab_not_found_suggestions
          elsif show_actionable_suggestions(error, platform: :android)
            # Suggestions already shown
          else
            show_generic_android_suggestions
          end

          show_saved_files(context)
          show_debug_info(error)
        end

        private

        # iOS-specific suggestion helpers
        def show_build_not_found_suggestions(_context)
          say '💡 Build Not Found: How to fix', :cyan
          say ''
          say '   → Upload a build first: mysigner ship testflight', :yellow
          say '   → If already uploaded, wait 5-15 minutes for Apple to process', :yellow
          say '   → Use --wait flag to poll: mysigner ship appstore --wait', :yellow
          say '   → Sync your builds: mysigner sync ios', :yellow
          say ''
        end

        def show_build_processing_suggestions
          say '💡 Build Still Processing: How to fix', :cyan
          say ''
          say '   → Apple typically takes 5-15 minutes to process builds', :yellow
          say '   → Use --wait flag: mysigner ship appstore --wait', :yellow
          say '   → Check App Store Connect for processing status', :yellow
          say ''
        end

        def show_expired_credential_suggestions
          say '💡 Expired Profile or Certificate: How to fix', :cyan
          say ''
          say '   → List profiles with expiration dates: mysigner profiles', :yellow
          say '   → Check status in My Signer dashboard', :yellow
          say '   → Regenerate in Apple Developer Portal', :yellow
          say '   → Download fresh profile: mysigner profile download <ID>', :yellow
          say ''
        end

        def show_profile_not_found_suggestions
          say '💡 Provisioning Profile Not Found: How to fix', :cyan
          say ''
          say '   → List available profiles: mysigner profiles', :yellow
          say '   → Sync from Apple: mysigner sync ios', :yellow
          say '   → Create profile in Apple Developer Portal', :yellow
          say '   → Check if profile matches your Bundle ID', :yellow
          say ''
        end

        def show_certificate_not_found_suggestions
          say '💡 Signing Certificate Not Found: How to fix', :cyan
          say ''
          say '   → List certificates: mysigner certificates', :yellow
          say '   → Download and install: mysigner certificate download <ID>', :yellow
          say '   → Check Keychain Access for installed certificates', :yellow
          say '   → Run: mysigner doctor (diagnose signing issues)', :yellow
          say ''
        end

        def show_app_not_found_suggestions(bundle_id = nil)
          say '💡 App Not Found: How to fix', :cyan
          say ''
          say '   → Ensure app exists in App Store Connect', :yellow
          say '   → Create app in App Store Connect first', :yellow
          say '   → Verify Bundle ID matches your Xcode project', :yellow if bundle_id
          say '   → Sync from App Store Connect: mysigner sync ios', :yellow
          say ''
        end

        def show_missing_metadata_suggestions
          say '💡 Missing App Store Metadata: How to fix', :cyan
          say ''
          say '   → Configure release in My Signer dashboard', :yellow
          say "   → Provide What's New via CLI: --whats-new \"Your text\"", :yellow
          say '   → Ensure support URL is set in App Store Connect', :yellow
          say '   → Complete app information in App Store Connect', :yellow
          say ''
        end

        def show_archive_not_found_suggestions
          say '💡 Archive Not Found: How to fix', :cyan
          say ''
          say '   → Build first: mysigner build', :yellow
          say '   → Or use: mysigner ship testflight (handles build)', :yellow
          say '   → Check if Xcode build succeeded', :yellow
          say ''
        end

        def show_ipa_not_found_suggestions
          say '💡 IPA File Not Found: How to fix', :cyan
          say ''
          say '   → Export IPA: mysigner export <archive_path>', :yellow
          say '   → Or use: mysigner ship testflight (handles export)', :yellow
          say '   → Check export method matches profile type', :yellow
          say ''
        end

        def show_generic_apple_suggestions
          say '💡 General troubleshooting:', :cyan
          say ''
          say "   → Run 'mysigner doctor' to check your setup", :yellow
          say '   → Sync from Apple: mysigner sync ios', :yellow
          say '   → Check App Store Connect: https://appstoreconnect.apple.com', :yellow
          say ''
        end

        # Android-specific suggestion helpers
        def show_keystore_not_found_suggestions
          say '💡 Keystore Not Found: How to fix', :cyan
          say ''
          say '   → Upload keystore: mysigner keystore upload <path>', :yellow
          say '   → List keystores: mysigner keystore list', :yellow
          say '   → Download keystore: mysigner keystore download <ID>', :yellow
          say '   → Check keystore path in build.gradle', :yellow
          say ''
        end

        def show_keystore_password_suggestions
          say '💡 Keystore Password Issue: How to fix', :cyan
          say ''
          say '   → Verify keystore password is correct', :yellow
          say '   → Check password in My Signer dashboard', :yellow
          say '   → Update password: mysigner keystore update <ID>', :yellow
          say ''
        end

        def show_first_upload_suggestions(_package_name = nil)
          say '💡 First Upload Required: How to fix', :cyan
          say ''
          say '   Google Play requires the FIRST build to be uploaded manually:', :yellow
          say ''
          say '   1. Build AAB: mysigner android build', :yellow
          say '   2. Go to Play Console → Your App → Internal testing', :yellow
          say "   3. Click 'Create release' and upload the AAB", :yellow
          say '   4. Save the release (no need to roll out)', :yellow
          say ''
          say "   After that, 'mysigner ship' will work for future uploads.", :green
          say ''
        end

        def show_version_code_conflict_suggestions
          say '💡 Version Code Conflict: How to fix', :cyan
          say ''
          say '   → Version code already exists on Google Play', :yellow
          say '   → Run the command again - mysigner auto-increments', :yellow
          say '   → Or manually increment versionCode in build.gradle', :yellow
          say ''
        end

        def show_service_account_missing_suggestions
          say '💡 Service Account Not Found: How to fix', :cyan
          say ''
          say '   Set up Google Play credentials in My Signer dashboard:', :yellow
          say ''
          say '   1. Go to Play Console → API access → Service accounts', :yellow
          say '   2. Create a service account with Editor access', :yellow
          say '   3. Download the JSON key', :yellow
          say '   4. Upload to My Signer dashboard → Google Play Settings', :yellow
          say ''
        end

        def show_permission_denied_suggestions
          say '💡 Service Account Permission Denied: How to fix', :cyan
          say ''
          say '   In Play Console → API access:', :yellow
          say ''
          say '   1. Find your service account', :yellow
          say "   2. Click 'Manage Play Console permissions'", :yellow
          say "   3. Grant 'Admin' or 'Release manager' access", :yellow
          say ''
          say '   Note: Permission changes take ~15 minutes to propagate', :green
          say ''
        end

        def show_track_not_setup_suggestions(track = nil)
          track || 'this track'
          say '💡 Track Not Set Up in Play Console: How to fix', :cyan
          say ''
          say '   Complete track setup in Google Play Console:', :yellow
          say ''
          say '   For PRODUCTION:', :yellow
          say '     • Complete store listing, content rating, pricing', :yellow
          say ''
          say '   For BETA/ALPHA:', :yellow
          say '     • Create testing track and add testers', :yellow
          say ''
          say '   For INTERNAL:', :yellow
          say '     • Add internal testers', :yellow
          say ''
          say '   ✓ Your AAB was uploaded successfully!', :green
          say '   → Go to Play Console to finish track setup', :green
          say ''
        end

        def show_aab_not_found_suggestions
          say '💡 AAB File Not Found: How to fix', :cyan
          say ''
          say '   → Build your app first: mysigner android build', :yellow
          say '   → Or use: mysigner ship internal (handles build)', :yellow
          say '   → Check if Gradle build succeeded', :yellow
          say ''
        end

        def show_generic_android_suggestions
          say '💡 General troubleshooting:', :cyan
          say ''
          say "   → Run 'mysigner doctor' to check your setup", :yellow
          say '   → List keystores: mysigner keystore list', :yellow
          say '   → Check Play Console: https://play.google.com/console', :yellow
          say ''
        end

        # Helper to show saved file paths
        def show_saved_files(context)
          say "📦 Archive saved at: #{context[:archive_path]}", :yellow if context[:archive_path] && File.exist?(context[:archive_path])
          say "📦 IPA saved at: #{context[:ipa_path]}", :yellow if context[:ipa_path] && File.exist?(context[:ipa_path])
          return unless context[:aab_path] && File.exist?(context[:aab_path])

          say "📦 AAB saved at: #{context[:aab_path]}", :yellow
        end

        # Helper to show debug info
        def show_debug_info(error)
          say ''
          if ENV['DEBUG']
            say 'Debug info:', :yellow
            say "  Error class: #{error.class}", :yellow
            say '  Backtrace:', :yellow
            error.backtrace&.first(5)&.each do |line|
              say "    #{line}", :yellow
            end
          else
            say '💡 For more details, run with DEBUG=1', :yellow
          end
          say ''
        end
      end
    end
  end
end
