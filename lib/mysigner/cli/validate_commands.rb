# frozen_string_literal: true

module Mysigner
  class CLI < Thor
    module ValidateCommands
      def self.included(base)
        base.class_eval do
          desc 'validate', 'Validate signing configuration on the server'
          long_desc <<~DESC
            Check if your bundle ID, certificate, and provisioning profile exist and
            are valid on the My Signer server.

            WHY VALIDATE?

            The CLI does local keychain/certificate validation, but doesn't check if
            your signing assets exist on the server. This catches "forgot to sync"
            or "profile expired" errors before a build starts.

            OPTIONS:

              --bundle-id / -b   Bundle identifier (e.g., com.example.app)
                                 Auto-detected from Xcode project if not provided

              --type / -t        Signing type: development, appstore, adhoc, inhouse

            EXAMPLES:

              # Validate development signing for an app
              mysigner validate --bundle-id com.example.app --type development

              # Validate App Store signing
              mysigner validate -b com.example.app -t appstore

              # Auto-detect bundle ID from current project
              mysigner validate --type development
          DESC
          method_option :bundle_id, type: :string, aliases: '-b', desc: 'Bundle identifier (e.g., com.example.app)'
          method_option :type, type: :string, aliases: '-t', desc: 'Signing type: development, appstore, adhoc, inhouse'
          def validate
            return validate_local_only if local_only?

            config = load_config
            client = create_client(config)

            bundle_id = options[:bundle_id] || detect_bundle_id_from_project
            signing_type = options[:type]

            unless bundle_id
              error 'Bundle ID is required. Use --bundle-id or run from an Xcode project directory.'
              say ''
              say 'Example: mysigner validate --bundle-id com.example.app --type development', :yellow
              exit 1
            end

            unless signing_type
              error 'Signing type is required. Use --type with one of: development, appstore, adhoc, inhouse'
              say ''
              say "Example: mysigner validate --bundle-id #{bundle_id} --type development", :yellow
              exit 1
            end

            valid_types = %w[development appstore adhoc inhouse]
            unless valid_types.include?(signing_type)
              error "Invalid signing type: #{signing_type}"
              say "Valid types: #{valid_types.join(', ')}", :yellow
              exit 1
            end

            say '🔍 Validating signing configuration...', :cyan
            say ''
            say "  Bundle ID: #{bundle_id}", :white
            say "  Type:      #{signing_type}", :white
            say ''

            begin
              response = client.post(
                "/api/v1/organizations/#{config.current_organization_id}/validate",
                body: {
                  bundle_id: bundle_id,
                  type: signing_type
                }
              )

              result = response[:data]
              checks = result['checks'] || {}
              valid = result['valid']

              # Display each check
              %w[bundle_id certificate profile].each do |check_name|
                check = checks[check_name]
                next unless check

                if check['status'] == 'pass'
                  say "  ✓ #{check_name.tr('_', ' ').capitalize}: #{check['message']}", :green
                else
                  say "  ✗ #{check_name.tr('_', ' ').capitalize}: #{check['message']}", :red
                end
              end

              say ''

              if valid
                say '✓ All checks passed! Signing configuration is valid.', :green
              else
                say '✗ Validation failed. Some checks did not pass.', :red

                suggestions = result['suggestions'] || []
                if suggestions.any?
                  say ''
                  say '💡 Suggestions:', :cyan
                  suggestions.each do |suggestion|
                    say "   → #{suggestion}", :yellow
                  end
                end

                exit 1
              end
            rescue Mysigner::NotFoundError => e
              error "Not found: #{e.message}"
              say ''
              say '💡 Make sure your bundle ID is synced:', :cyan
              say "   → Run 'mysigner sync ios' to sync from Apple Developer Portal", :yellow
              say "   → Run 'mysigner bundleid list' to list registered bundle IDs", :yellow
              exit 1
            rescue Mysigner::ValidationError => e
              error "Validation error: #{e.message}"
              e.details&.each do |field, errors|
                errors_text = errors.is_a?(Array) ? errors.join(', ') : errors.to_s
                say "  #{field}: #{errors_text}", :red
              end
              exit 1
            rescue Mysigner::ClientError => e
              error "Validation request failed: #{e.message}"
              say ''
              say '💡 Try these steps:', :cyan
              say '   → Check your network connection', :yellow
              say '   → Verify API token: mysigner status', :yellow
              exit 1
            end
          end

          no_commands do
            def validate_local_only
              say 'Local-only validation', :cyan
              say '=' * 50, :cyan
              say ''
              say 'Running local Signing::Validator (server checks skipped in local-only mode).', :yellow
              say ''

              project_info = Mysigner::Build::Detector.detect
              parser = Mysigner::Build::Parser.new(project_info)
              target_name = parser.main_target.name

              validator = Mysigner::Signing::Validator.new(
                parser, target_name, options[:configuration] || 'Release',
                team_id: options[:team], local_only: true
              )
              validator.validate!

              say 'Local validation passed.', :green
            end
          end

          private

          def detect_bundle_id_from_project
            # Try to find bundle ID from Xcode project in current directory
            pbxproj_files = Dir.glob('**/*.pbxproj')
            return nil if pbxproj_files.empty?

            pbxproj_files.each do |file|
              content = File.read(file)
              match = content.match(/PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([^;"]+)"?/)
              return match[1].strip if match
            end

            nil
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
