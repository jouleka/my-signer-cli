# frozen_string_literal: true

module Mysigner
  module Build
    class Configurator
      class ProfileNotFoundError < StandardError; end

      def initialize(parser, client, organization_id)
        @parser = parser
        @client = client
        @organization_id = organization_id
      end

      # Configure signing for a specific build type
      # build_type: :development, :adhoc, :appstore, :enterprise
      def configure!(target_name = nil, configuration = 'Release', build_type: :appstore)
        target = @parser.find_target(target_name)
        bundle_id = @parser.bundle_id(target_name, configuration)

        raise 'Bundle ID not found in project' if bundle_id.to_s.empty?

        # Map build type to profile type
        profile_type = map_build_type_to_profile_type(build_type)

        # Fetch matching profile from API
        profile = fetch_profile(bundle_id, profile_type)

        # Configure the target's build settings
        config = target.build_configurations.find { |c| c.name == configuration }
        raise "Configuration '#{configuration}' not found" unless config

        # Set manual signing
        config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
        config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = profile['name']

        # Set code sign identity based on type
        code_sign_identity = case build_type
                             when :development
                               'iPhone Developer'
                             else
                               'iPhone Distribution'
                             end
        config.build_settings['CODE_SIGN_IDENTITY'] = code_sign_identity

        # Ensure development team is set
        team_id = @parser.team_id(target_name, configuration)
        if team_id.to_s.empty? && profile['team_id']
          # Try to get from profile or use organization default
          config.build_settings['DEVELOPMENT_TEAM'] = profile['team_id']
        end

        # Save project
        @parser.project.save

        profile
      end

      # Check if profile is available without configuring
      def check_profile_available(target_name = nil, configuration = 'Release', build_type: :appstore)
        bundle_id = @parser.bundle_id(target_name, configuration)
        profile_type = map_build_type_to_profile_type(build_type)

        begin
          fetch_profile(bundle_id, profile_type)
          true
        rescue ProfileNotFoundError
          false
        end
      end

      private

      def map_build_type_to_profile_type(build_type)
        case build_type
        when :development, :dev
          'development'
        when :adhoc, :ad_hoc
          'adhoc'
        when :appstore, :app_store, :store
          'appstore'
        when :enterprise, :inhouse
          'inhouse'
        else
          'appstore' # Default to App Store
        end
      end

      def fetch_profile(bundle_id, profile_type)
        # Try to use profile matching API endpoint first
        begin
          response = @client.get(
            "/api/v1/organizations/#{@organization_id}/profiles/match",
            params: {
              bundle_id: bundle_id,
              type: profile_type
            }
          )

          return response[:profile] if response[:profile]
        rescue Mysigner::NotFoundError
          # Profile matching returned no match, fall through to manual search
        end

        # Fall back to listing all profiles and finding best match
        response = @client.get(
          "/api/v1/organizations/#{@organization_id}/profiles",
          params: {
            bundle_id: bundle_id,
            type: profile_type.upcase,
            state: 'ACTIVE'
          }
        )

        profiles = response[:profiles] || []

        if profiles.empty?
          raise ProfileNotFoundError,
                "No active #{profile_type} profile found for bundle ID '#{bundle_id}'. " \
                "Create one at the My Signer dashboard or run 'mysigner profiles'"
        end

        # Return the profile expiring furthest in the future
        profiles.max_by { |p| p['expires_at'] || '1970-01-01' }
      end
    end
  end
end
