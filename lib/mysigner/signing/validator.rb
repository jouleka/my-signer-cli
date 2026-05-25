# frozen_string_literal: true

module Mysigner
  module Signing
    class Validator
      class ValidationError < StandardError; end

      # local_only: when true, omit user-facing fix-suggestions that point
      # at the MySigner web dashboard (mysigner-22). A user who passed
      # `--local-only` (or set MYSIGNER_LOCAL_ONLY=1) has explicitly opted
      # out of MySigner; suggesting they log in there to fix an error is
      # nonsense and was a real point of confusion in the Phase 6 ship test.
      def initialize(parser, target_name, configuration = 'Release', team_id: nil, local_only: false)
        @parser = parser
        @target_name = target_name
        @configuration = configuration
        @team_id_override = team_id
        @local_only = local_only
      end

      # Validates signing setup before build
      # Returns: { valid: true/false, errors: [], warnings: [] }
      def validate
        result = { valid: true, errors: [], warnings: [] }

        # Check 1: Development Team
        team_id = @team_id_override || @parser.team_id(@target_name, @configuration)
        if team_id.nil? || team_id.empty?
          result[:errors] << "No development team set for target '#{@target_name}'"
          result[:errors] << ''
          option_number = 1
          unless @local_only
            result[:errors] << "Fix Option #{option_number}: Add team to My Signer"
            result[:errors] << '  1. Open https://mysigner.dev'
            result[:errors] << '  2. Go to Settings → App Store Connect'
            result[:errors] << '  3. Add your Team ID'
            result[:errors] << '  4. Run: mysigner build (team will auto-fetch)'
            result[:errors] << ''
            option_number += 1
          end
          result[:errors] << "Fix Option #{option_number}: Pass team via CLI"
          result[:errors] << '  mysigner build --team YOUR_TEAM_ID'
          result[:errors] << ''
          option_number += 1
          result[:errors] << "Fix Option #{option_number}: Set in Xcode"
          result[:errors] << '  Open Xcode → Select target → Signing & Capabilities → Select a team'
          result[:errors] << ''
          result[:errors] << 'Find your team ID at: https://developer.apple.com/account/#!/membership/'
          result[:valid] = false
        elsif @team_id_override && @parser.team_id(@target_name, @configuration).nil?
          result[:warnings] << "Using team from My Signer: #{@team_id_override}"
        elsif @team_id_override
          result[:warnings] << "Using team override: #{@team_id_override} (overriding project setting)"
        end

        # Check 2: Code signing style
        signing_style = @parser.code_sign_style(@target_name, @configuration)
        result[:warnings] << 'Code signing style not explicitly set (will use Xcode default)' if signing_style.nil?

        # Check 3: Bundle ID
        bundle_id = @parser.bundle_id(@target_name, @configuration)
        if bundle_id.nil? || bundle_id.empty? || bundle_id.include?('$(')
          result[:errors] << "Bundle ID not set or contains variables: #{bundle_id}"
          result[:errors] << 'Fix: Open Xcode → Select target → General → Bundle Identifier'
          result[:valid] = false
        end

        # Check 4: Certificates (if manual signing)
        if signing_style == 'Manual'
          cert_result = check_certificates
          result[:errors].concat(cert_result[:errors])
          result[:warnings].concat(cert_result[:warnings])
          result[:valid] = false if cert_result[:errors].any?
        end

        # Check 5: Provisioning Profiles (if manual signing)
        if signing_style == 'Manual'
          profile_result = check_provisioning_profiles
          result[:errors].concat(profile_result[:errors])
          result[:warnings].concat(profile_result[:warnings])
          result[:valid] = false if profile_result[:errors].any?
        end

        result
      end

      # Run validation and display results
      # Raises ValidationError if not valid
      def validate!
        result = validate

        if result[:warnings].any?
          puts ''
          puts '⚠️  Warnings:'
          result[:warnings].each { |w| puts "  • #{w}" }
        end

        if result[:errors].any?
          puts ''
          puts '❌ Validation Failed:'
          puts ''
          result[:errors].each { |e| puts "  • #{e}" }
          puts ''
          raise ValidationError, 'Pre-build validation failed. Fix the errors above and try again.'
        end

        puts '✓ Pre-build validation passed' if result[:warnings].empty?
        puts '' if result[:warnings].any?
      end

      private

      def check_certificates
        result = { errors: [], warnings: [] }

        # Check for valid iOS distribution certificates in keychain
        output = `security find-identity -v -p codesigning 2>&1`

        if output.include?('0 valid identities found')
          result[:errors] << 'No code signing certificates found in keychain'
          result[:errors] << 'Fix: Install your distribution certificate (.p12 file)'
        else
          # Count valid certificates
          cert_count = output.scan(/\d+\)\s+[A-F0-9]+/).count
          result[:warnings] << "Found #{cert_count} code signing certificate(s) in keychain"

          # Check for expired certificates
          result[:warnings] << 'Some certificates may be invalid or expired' if output.include?('CSSMERR')
        end

        result
      end

      def check_provisioning_profiles
        result = { errors: [], warnings: [] }

        # Check provisioning profile directory
        profiles_dir = File.expand_path('~/Library/MobileDevice/Provisioning Profiles')

        unless Dir.exist?(profiles_dir)
          result[:warnings] << 'No provisioning profiles directory found'
          result[:warnings] << 'Profiles will be downloaded automatically if using automatic signing'
          return result
        end

        profiles = Dir.glob("#{profiles_dir}/*.mobileprovision")

        if profiles.empty?
          result[:warnings] << 'No provisioning profiles found'
          result[:warnings] << 'Profiles will be downloaded automatically if using automatic signing'
        else
          result[:warnings] << "Found #{profiles.count} provisioning profile(s) installed"
        end

        result
      end
    end
  end
end
