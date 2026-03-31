# frozen_string_literal: true

module Mysigner
  module Build
    class ErrorAnalyzer
      attr_reader :issues

      def initialize(build_errors)
        @build_errors = build_errors || []
        @issues = []
        analyze!
      end

      def any_issues?
        @issues.any?
      end

      # Returns formatted suggestions for CLI output
      def format_suggestions
        return nil unless any_issues?

        lines = []
        lines << ''
        lines << ('=' * 70)
        lines << '  💡 SUGGESTIONS: How to fix these build errors'
        lines << ('=' * 70)
        lines << ''

        # Group issues by type for cleaner output
        profile_issues = @issues.select { |i| i[:type] == :profile_capability }
        cert_issues = @issues.select { |i| i[:type] == :certificate_mismatch }
        identifier_issues = @issues.select { |i| i[:type] == :missing_identifier }

        # Profile capability issues
        if profile_issues.any?
          lines << '  📋 PROVISIONING PROFILE ISSUES'
          lines << ''

          # Group by profile name
          by_profile = profile_issues.group_by { |i| i[:profile_name] }
          by_profile.each do |profile_name, issues|
            capabilities = issues.map { |i| i[:capability] }.compact.uniq
            lines << "  Profile: \"#{profile_name}\""
            lines << "  Missing capabilities: #{capabilities.join(', ')}"
            lines << ''
          end

          lines << '  How to fix:'
          lines << '    1. Go to Apple Developer Portal → Certificates, Identifiers & Profiles'
          lines << "    2. Select 'Identifiers' and find your Bundle ID"
          lines << '    3. Enable the missing capabilities (App Groups, Apple Pay, etc.)'
          lines << '    4. If adding App Groups or Merchant IDs, make sure to select the specific identifiers'
          lines << "    5. Go to 'Profiles' and regenerate the affected provisioning profiles"
          lines << '    6. Download new profiles: mysigner sync ios && mysigner profile download <ID>'
          lines << '    7. Install profiles to: ~/Library/MobileDevice/Provisioning Profiles/'
          lines << ''
        end

        # Missing specific identifiers (App Group ID, Merchant ID)
        if identifier_issues.any?
          lines << '  🔗 MISSING IDENTIFIERS'
          lines << ''

          identifier_issues.each do |issue|
            lines << "  Profile: \"#{issue[:profile_name]}\""
            lines << "  Missing: #{issue[:identifier_type]} - #{issue[:identifier]}"
            lines << ''
          end

          lines << '  How to fix:'
          lines << '    1. Go to Apple Developer Portal → Identifiers'
          lines << '    2. Find your Bundle ID and edit it'
          lines << '    3. Under the capability, add/select the specific identifier:'
          lines << '       • For App Groups: select your group.* identifier'
          lines << '       • For Apple Pay: select your merchant.* identifier'
          lines << '    4. Regenerate the provisioning profile'
          lines << ''
        end

        # Certificate mismatch
        if cert_issues.any?
          lines << '  🔐 CERTIFICATE MISMATCH'
          lines << ''
          lines << '  Your app and its extensions are signed with different certificates.'
          lines << ''
          lines << '  How to fix:'
          lines << '    1. Open your Xcode project'
          lines << '    2. For EACH target (main app AND extensions):'
          lines << '       • Select the target → Signing & Capabilities'
          lines << '       • Ensure all targets use the same signing identity:'
          lines << "         - For App Store: 'Apple Distribution'"
          lines << "         - For Development: 'Apple Development'"
          lines << '    3. Make sure all targets use matching profile types:'
          lines << '       • App Store profiles for App Store builds'
          lines << '       • Development profiles for development builds'
          lines << ''
          lines << '  Quick fix for App Store builds:'
          lines << '    In project.pbxproj, ensure Release configuration has:'
          lines << '      CODE_SIGN_IDENTITY = "Apple Distribution"'
          lines << '      PROVISIONING_PROFILE_SPECIFIER = "YourApp App Store"'
          lines << ''
        end

        lines << '  📚 More help:'
        lines << "    • Run 'mysigner doctor' to check your setup"
        lines << "    • Run 'mysigner profiles' to list available profiles"
        lines << '    • Check My Signer dashboard for Bundle ID capabilities'
        lines << ''

        lines.join("\n")
      end

      private

      def analyze!
        @build_errors.each do |error|
          analyze_error(error)
        end
      end

      def analyze_error(error)
        # Normalize curly quotes to straight quotes
        error = error.gsub('"', '"').gsub('\'', "'")

        # Pattern: Provisioning profile "X" doesn't include the Y capability
        if (match = error.match(/Provisioning profile "([^"]+)".*(?:doesn't|does not) include the (.+?) capability/i))
          @issues << {
            type: :profile_capability,
            profile_name: match[1],
            capability: match[2].strip
          }
        end

        # Pattern: Provisioning profile "X" doesn't support the Y App Group
        if (match = error.match(/Provisioning profile "([^"]+)".*(?:doesn't|does not) support the (.+?) App Group/i))
          @issues << {
            type: :missing_identifier,
            profile_name: match[1],
            identifier_type: 'App Group',
            identifier: match[2].strip
          }
        end

        # Pattern: Provisioning profile "X" doesn't support the Y Merchant ID
        if (match = error.match(/Provisioning profile "([^"]+)".*(?:doesn't|does not) support the (.+?) Merchant ID/i))
          @issues << {
            type: :missing_identifier,
            profile_name: match[1],
            identifier_type: 'Merchant ID',
            identifier: match[2].strip
          }
        end

        # Pattern: Provisioning profile "X" doesn't match the entitlements file's value
        if (match = error.match(/Provisioning profile "([^"]+)".*(?:doesn't|does not) match.*entitlements.*?for the (.+?) entitlement/i))
          capability = entitlement_to_capability(match[2])
          @issues << {
            type: :profile_capability,
            profile_name: match[1],
            capability: capability
          }
        end

        # Pattern: Embedded binary is not signed with the same certificate
        if error.include?('Embedded binary is not signed with the same certificate')
          @issues << {
            type: :certificate_mismatch,
            message: error
          }
        end

        # Pattern: Code Sign error
        return unless error.include?('Code Sign error')

        @issues << {
          type: :code_sign_error,
          message: error
        }
      end

      def entitlement_to_capability(entitlement)
        mappings = {
          'com.apple.security.application-groups' => 'App Groups',
          'com.apple.developer.in-app-payments' => 'Apple Pay',
          'aps-environment' => 'Push Notifications',
          'com.apple.developer.associated-domains' => 'Associated Domains',
          'com.apple.developer.applesignin' => 'Sign in with Apple',
          'com.apple.developer.icloud-services' => 'iCloud',
          'com.apple.developer.healthkit' => 'HealthKit'
        }
        mappings[entitlement] || entitlement
      end
    end
  end
end
