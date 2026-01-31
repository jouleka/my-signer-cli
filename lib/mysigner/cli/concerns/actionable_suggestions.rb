module Mysigner
  class CLI < Thor
    module Concerns
      # Provides actionable error messages with specific suggestions
      # for common failure scenarios users encounter
      module ActionableSuggestions
        # Error categories for iOS/App Store Connect
        IOS_ERROR_PATTERNS = {
          # Build not found / processing
          build_not_found: {
            patterns: [
              /no.*build.*found/i,
              /build.*not.*found/i,
              /no.*processed.*build/i,
              /waiting.*for.*build/i
            ],
            title: "Build Not Found",
            suggestions: [
              "Upload a build first: mysigner ship testflight",
              "If already uploaded, wait 5-15 minutes for Apple to process it",
              "Use --wait flag to poll for processing: mysigner ship appstore --wait",
              "Sync your builds: mysigner sync ios"
            ]
          },

          # Build still processing
          build_processing: {
            patterns: [
              /still.*processing/i,
              /processing.*complete/i,
              /not.*ready/i
            ],
            title: "Build Still Processing",
            suggestions: [
              "Apple typically takes 5-15 minutes to process builds",
              "Use --wait flag to automatically wait: mysigner ship appstore --wait",
              "Check App Store Connect for processing status",
              "Increase timeout: mysigner ship appstore --wait --asc-timeout-seconds 1800"
            ]
          },

          # Profile issues
          profile_expired: {
            patterns: [
              /profile.*expired/i,
              /provisioning.*expired/i,
              /certificate.*expired/i
            ],
            title: "Expired Profile or Certificate",
            suggestions: [
              "List your profiles: mysigner profiles",
              "Check expiration dates in My Signer dashboard",
              "Regenerate expired profiles in Apple Developer Portal",
              "Download fresh profile: mysigner profile download <ID>"
            ]
          },

          profile_not_found: {
            patterns: [
              /profile.*not.*found/i,
              /no.*provisioning.*profile/i,
              /missing.*profile/i,
              /unable.*find.*profile/i
            ],
            title: "Provisioning Profile Not Found",
            suggestions: [
              "List available profiles: mysigner profiles",
              "Sync profiles from Apple: mysigner sync ios",
              "Create profile in Apple Developer Portal",
              "Check if profile is for correct Bundle ID"
            ]
          },

          # Certificate issues
          certificate_not_found: {
            patterns: [
              /certificate.*not.*found/i,
              /no.*signing.*certificate/i,
              /missing.*certificate/i
            ],
            title: "Signing Certificate Not Found",
            suggestions: [
              "List certificates: mysigner certificates",
              "Download and install: mysigner certificate download <ID>",
              "Check Keychain Access for installed certificates",
              "Run 'mysigner doctor' to diagnose signing issues"
            ]
          },

          # Bundle ID issues
          bundle_id_mismatch: {
            patterns: [
              /bundle.*id.*mismatch/i,
              /bundle.*identifier.*not.*match/i,
              /app.*id.*not.*found/i
            ],
            title: "Bundle ID Issue",
            suggestions: [
              "Verify Bundle ID in Xcode matches Apple Developer Portal",
              "List Bundle IDs: mysigner bundleids",
              "Register new Bundle ID: mysigner bundleids create <ID>",
              "Check My Signer dashboard for registered apps"
            ]
          },

          # App not found
          app_not_found: {
            patterns: [
              /app.*with.*bundle.*id.*not.*found/i,
              /app.*not.*found/i,
              /unable.*find.*app/i
            ],
            title: "App Not Found",
            suggestions: [
              "Ensure app exists in App Store Connect",
              "Create app in App Store Connect first",
              "Verify Bundle ID matches: check your Xcode project",
              "Sync from App Store Connect: mysigner sync ios"
            ]
          },

          # Version issues
          version_exists: {
            patterns: [
              /version.*already.*exists/i,
              /duplicate.*version/i
            ],
            title: "Version Already Exists",
            suggestions: [
              "Increment version in Xcode (CFBundleShortVersionString)",
              "Or increment build number (CFBundleVersion)",
              "Check existing versions in App Store Connect"
            ]
          },

          # Submission issues
          missing_metadata: {
            patterns: [
              /missing.*required.*field/i,
              /what's.*new.*required/i,
              /support.*url.*required/i,
              /cannot.*submit.*missing/i
            ],
            title: "Missing App Store Metadata",
            suggestions: [
              "Configure release in My Signer dashboard",
              "Provide What's New via CLI: --whats-new \"Your text\"",
              "Ensure support URL is set in App Store Connect",
              "Complete app information in App Store Connect"
            ]
          },

          # Archive issues
          archive_not_found: {
            patterns: [
              /archive.*not.*found/i,
              /no.*xcarchive/i,
              /.xcarchive.*not.*found/i
            ],
            title: "Archive Not Found",
            suggestions: [
              "Build your app first: mysigner build",
              "Or use: mysigner ship testflight (handles build automatically)",
              "Check if archive path is correct",
              "Verify Xcode build succeeded"
            ]
          },

          ipa_not_found: {
            patterns: [
              /ipa.*not.*found/i,
              /no.*ipa.*file/i
            ],
            title: "IPA File Not Found",
            suggestions: [
              "Export IPA from archive: mysigner export <archive_path>",
              "Or use: mysigner ship testflight (handles export automatically)",
              "Check if export succeeded",
              "Verify export method matches profile type"
            ]
          }
        }.freeze

        # Error categories for Android/Google Play
        ANDROID_ERROR_PATTERNS = {
          # Keystore issues
          keystore_not_found: {
            patterns: [
              /keystore.*not.*found/i,
              /no.*keystore/i,
              /missing.*keystore/i
            ],
            title: "Keystore Not Found",
            suggestions: [
              "Upload keystore: mysigner keystore upload <path>",
              "List keystores: mysigner keystores",
              "Download keystore: mysigner keystore download <ID>",
              "Check keystore path in build.gradle"
            ]
          },

          keystore_password: {
            patterns: [
              /keystore.*password/i,
              /wrong.*password/i,
              /incorrect.*password/i
            ],
            title: "Keystore Password Issue",
            suggestions: [
              "Verify keystore password is correct",
              "Check password in My Signer dashboard",
              "Update keystore password: mysigner keystore update <ID>"
            ]
          },

          # Package not found (first upload)
          package_not_found: {
            patterns: [
              /package.*not.*found/i,
              /first.*build.*uploaded.*manually/i
            ],
            title: "First Upload Required",
            suggestions: [
              "Google Play requires the FIRST build to be uploaded manually:",
              "  1. Build AAB: mysigner android build",
              "  2. Go to Play Console → Your App → Internal testing",
              "  3. Click 'Create release' and upload the AAB",
              "  4. Save the release (no need to roll out)",
              "After that, mysigner ship will work for future uploads"
            ]
          },

          # Version code conflict
          version_code_conflict: {
            patterns: [
              /version.*code.*already/i,
              /already.*used/i,
              /duplicate.*version.*code/i
            ],
            title: "Version Code Conflict",
            suggestions: [
              "Version code already exists on Google Play",
              "Run the command again - mysigner auto-increments the version",
              "Or manually increment versionCode in build.gradle"
            ]
          },

          # Service account issues
          service_account_missing: {
            patterns: [
              /service.*account.*not.*found/i,
              /service.*account.*json.*not.*found/i,
              /no.*credentials/i
            ],
            title: "Service Account Not Found",
            suggestions: [
              "Set up Google Play credentials in My Signer dashboard:",
              "  1. Go to Play Console → API access → Service accounts",
              "  2. Create a service account with Editor access",
              "  3. Download the JSON key",
              "  4. Upload to My Signer dashboard → Google Play Settings"
            ]
          },

          service_account_permission: {
            patterns: [
              /not.*authorized/i,
              /permission.*denied/i,
              /forbidden/i,
              /access.*denied/i
            ],
            title: "Service Account Permission Denied",
            suggestions: [
              "Service account lacks required permissions",
              "In Play Console → API access:",
              "  1. Find your service account",
              "  2. Click 'Manage Play Console permissions'",
              "  3. Grant 'Admin' or 'Release manager' access to the app",
              "Note: Permission changes take ~15 minutes to propagate"
            ]
          },

          # Track setup issues
          track_not_setup: {
            patterns: [
              /precondition.*failed/i,
              /precondition.*check.*failed/i,
              /track.*not.*ready/i
            ],
            title: "Track Not Set Up in Play Console",
            suggestions: [
              "Complete track setup in Google Play Console:",
              "  For PRODUCTION: Complete store listing, content rating, pricing",
              "  For BETA/ALPHA: Create testing track and add testers",
              "  For INTERNAL: Add internal testers",
              "Your AAB was uploaded - go to Play Console to finish setup"
            ]
          },

          # AAB issues
          aab_not_found: {
            patterns: [
              /aab.*not.*found/i,
              /no.*aab.*file/i,
              /app.*bundle.*not.*found/i
            ],
            title: "AAB File Not Found",
            suggestions: [
              "Build your Android app first: mysigner android build",
              "Or use: mysigner ship internal (handles build automatically)",
              "Check if Gradle build succeeded",
              "Verify AAB path in build output"
            ]
          },

          # Signing issues
          signing_mismatch: {
            patterns: [
              /signing.*key.*mismatch/i,
              /wrong.*key/i,
              /incorrect.*signature/i
            ],
            title: "Signing Key Mismatch",
            suggestions: [
              "AAB is signed with a different key than expected",
              "Verify keystore matches what's registered in Play Console",
              "Check active keystore: mysigner keystores --active",
              "If using Google Play App Signing, upload the correct upload key"
            ]
          }
        }.freeze

        # API/Connection error patterns
        API_ERROR_PATTERNS = {
          rate_limited: {
            patterns: [
              /rate.*limit/i,
              /too.*many.*requests/i,
              /429/
            ],
            title: "Rate Limited",
            suggestions: [
              "Too many API requests - wait a moment and try again",
              "If problem persists, check API status"
            ]
          },

          server_error: {
            patterns: [
              /server.*error/i,
              /internal.*error/i,
              /500|502|503|504/
            ],
            title: "Server Error",
            suggestions: [
              "My Signer server encountered an error",
              "Try again in a few moments",
              "If problem persists, check service status or contact support"
            ]
          },

          timeout: {
            patterns: [
              /timeout/i,
              /timed.*out/i
            ],
            title: "Request Timeout",
            suggestions: [
              "Request took too long to complete",
              "Check your network connection",
              "Try again - this may be temporary"
            ]
          }
        }.freeze

        # Find matching error pattern and return suggestions
        def find_suggestions_for_error(error_message, platform: nil)
          patterns = case platform
                     when :ios, :apple
                       IOS_ERROR_PATTERNS.merge(API_ERROR_PATTERNS)
                     when :android
                       ANDROID_ERROR_PATTERNS.merge(API_ERROR_PATTERNS)
                     else
                       IOS_ERROR_PATTERNS.merge(ANDROID_ERROR_PATTERNS).merge(API_ERROR_PATTERNS)
                     end

          patterns.each do |_key, error_info|
            if error_info[:patterns].any? { |pattern| error_message =~ pattern }
              return error_info
            end
          end

          nil
        end

        # Format actionable suggestions for display
        def format_actionable_suggestions(error_info)
          return nil unless error_info

          lines = []
          lines << ""
          lines << "=" * 70
          lines << "  💡 #{error_info[:title]}: How to fix"
          lines << "=" * 70
          lines << ""

          error_info[:suggestions].each do |suggestion|
            # Preserve indentation for multi-line suggestions
            if suggestion.start_with?("  ")
              lines << "  #{suggestion}"
            else
              lines << "    → #{suggestion}"
            end
          end

          lines << ""
          lines << "  📚 More help:"
          lines << "    • Run 'mysigner doctor' to check your setup"
          lines << "    • Run 'mysigner help <command>' for command options"
          lines << ""

          lines.join("\n")
        end

        # Display actionable suggestions for an error (helper for CLI commands)
        def show_actionable_suggestions(error_message, platform: nil)
          error_info = find_suggestions_for_error(error_message.to_s, platform: platform)
          return false unless error_info

          output = format_actionable_suggestions(error_info)
          say output, :cyan if output
          true
        end

        # Enhanced error display that includes suggestions
        def display_error_with_suggestions(error, platform: nil, context: {})
          say ""
          say "=" * 80, :red
          say "✗ #{context[:title] || 'Error'}", :red
          say "=" * 80, :red
          say ""
          say "Error: #{error.message}", :red
          say ""

          # Show actionable suggestions if available
          show_actionable_suggestions(error.message, platform: platform)

          # Show additional context
          if context[:archive_path] && File.exist?(context[:archive_path])
            say "Archive saved at: #{context[:archive_path]}", :yellow
          end

          if context[:ipa_path] && File.exist?(context[:ipa_path])
            say "IPA saved at: #{context[:ipa_path]}", :yellow
          end

          if context[:aab_path] && File.exist?(context[:aab_path])
            say "AAB saved at: #{context[:aab_path]}", :yellow
          end

          # Debug info
          if ENV['DEBUG']
            say ""
            say "Debug info:", :yellow
            say "  Error class: #{error.class}", :yellow
            say "  Backtrace:", :yellow
            error.backtrace&.first(5)&.each do |line|
              say "    #{line}", :yellow
            end
          else
            say "💡 For more details, run with DEBUG=1", :yellow
          end

          say ""
        end

        # Quick reference suggestions for common operations
        QUICK_REFERENCE = {
          sync: {
            ios: "mysigner sync ios",
            android: "mysigner sync android"
          },
          profiles: "mysigner profiles",
          certificates: "mysigner certificates",
          keystores: "mysigner keystores",
          doctor: "mysigner doctor",
          onboard: "mysigner onboard",
          login: "mysigner login"
        }.freeze

        # Get quick reference command
        def quick_ref(operation, platform: nil)
          ref = QUICK_REFERENCE[operation]
          return ref unless ref.is_a?(Hash)
          platform ? ref[platform] : ref[:ios]
        end
      end
    end
  end
end
