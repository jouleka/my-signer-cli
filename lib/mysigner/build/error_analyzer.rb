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
        # Build logs are untrusted input. Keep parsing linear and bounded so a
        # malicious project cannot feed the CLI a pathological regular
        # expression input.
        error = error.to_s.byteslice(0, 65_536).to_s
                     .tr("\u201c\u201d", '""').tr("\u2018\u2019", "''")
        profile_name, details = provisioning_profile_details(error)

        # Pattern: Provisioning profile "X" doesn't include the Y capability
        if profile_name && (capability = extract_detail(details, ["doesn't include the ", 'does not include the '],
                                                        ' capability'))
          @issues << {
            type: :profile_capability,
            profile_name: profile_name,
            capability: capability
          }
        end

        # Pattern: Provisioning profile "X" doesn't support the Y App Group
        if profile_name && (identifier = extract_detail(details, ["doesn't support the ", 'does not support the '],
                                                        ' App Group'))
          @issues << {
            type: :missing_identifier,
            profile_name: profile_name,
            identifier_type: 'App Group',
            identifier: identifier
          }
        end

        # Pattern: Provisioning profile "X" doesn't support the Y Merchant ID
        if profile_name && (identifier = extract_detail(details, ["doesn't support the ", 'does not support the '],
                                                        ' Merchant ID'))
          @issues << {
            type: :missing_identifier,
            profile_name: profile_name,
            identifier_type: 'Merchant ID',
            identifier: identifier
          }
        end

        # Pattern: Provisioning profile "X" doesn't match the entitlements file's value
        mismatch = details.to_s.downcase.include?("doesn't match") || details.to_s.downcase.include?('does not match')
        entitlement = extract_detail(details, ['for the '], ' entitlement') if mismatch &&
                                                                               details.to_s.downcase.include?('entitlements')
        if profile_name && entitlement
          capability = entitlement_to_capability(entitlement)
          @issues << {
            type: :profile_capability,
            profile_name: profile_name,
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

      def provisioning_profile_details(error)
        marker = 'Provisioning profile "'
        marker_index = error.downcase.index(marker.downcase)
        return [nil, nil] unless marker_index

        name_start = marker_index + marker.length
        name_end = error.index('"', name_start)
        return [nil, nil] unless name_end

        [error[name_start...name_end], error[(name_end + 1)..]]
      end

      def extract_detail(text, markers, terminator)
        source = text.to_s
        folded = source.downcase
        marker, marker_index = markers.filter_map do |candidate|
          index = folded.index(candidate.downcase)
          [candidate, index] if index
        end.min_by { |_candidate, index| index }
        return nil unless marker

        value_start = marker_index + marker.length
        value_end = folded.index(terminator.downcase, value_start)
        return nil unless value_end

        value = source[value_start...value_end].strip
        value.empty? ? nil : value
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
