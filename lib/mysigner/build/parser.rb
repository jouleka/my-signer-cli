# frozen_string_literal: true

require 'xcodeproj'

module Mysigner
  module Build
    class Parser
      attr_reader :project, :project_info

      def initialize(project_info)
        @project_info = project_info
        @project = open_project
      end

      # Get all target names
      def targets
        @project.targets.map(&:name)
      end

      # Get all application targets (main apps only, no extensions)
      def app_targets
        @project.targets.select do |target|
          target.product_type == 'com.apple.product-type.application'
        end
      end

      # Get main app target (exclude test targets, extensions, etc.)
      def main_target
        # Return first app target, or first target if no app targets found
        app_targets.first || @project.targets.first
      end

      # Get all extension targets (widgets, share extensions, etc.)
      def extension_targets
        @project.targets.select do |target|
          target.product_type&.include?('app-extension') ||
            target.product_type&.include?('widget-extension') ||
            target.product_type == 'com.apple.product-type.watchkit2-extension'
        end
      end

      # Get all app + extension targets (everything that needs signing)
      def all_app_targets
        app_targets + extension_targets
      end

      # Check if project has extensions
      def has_extensions?
        extension_targets.any?
      end

      # Check if project has multiple apps
      def has_multiple_apps?
        app_targets.count > 1
      end

      # Get detailed info about a target
      def target_info(target_name, configuration = 'Release')
        target = find_target(target_name)

        {
          name: target.name,
          type: product_type(target_name),
          platform: target_platform(target_name),
          bundle_id: bundle_id(target_name, configuration),
          team_id: team_id(target_name, configuration),
          signing_style: code_sign_style(target_name, configuration),
          product_type: target.product_type
        }
      end

      # Get a list of all signable targets with their info
      def signable_targets(configuration = 'Release')
        all_app_targets.map do |target|
          target_info(target.name, configuration)
        end
      end

      # Detect target platform (iOS, macOS, tvOS, watchOS)
      def target_platform(target_name = nil)
        target = find_target(target_name)
        sdk = target.sdk

        return :macos if sdk&.include?('macosx')
        return :tvos if sdk&.include?('appletvos')
        return :watchos if sdk&.include?('watchos')

        :ios # default
      end

      # Detect product type (app, framework, library)
      def product_type(target_name = nil)
        target = find_target(target_name)

        case target.product_type
        when 'com.apple.product-type.application'
          :app
        when /framework/
          :framework
        when /library/
          :library
        when /app-extension/
          :extension
        else
          :unknown
        end
      end

      # Get schemes (simplified - assume scheme name matches target name)
      def schemes
        # In reality, schemes are in xcshareddata/xcschemes/
        # For now, return target names as potential schemes
        targets
      end

      # Get build settings for a target and configuration
      def build_settings(target_name = nil, configuration = 'Release')
        target = find_target(target_name)
        config = target.build_configurations.find { |c| c.name == configuration }

        raise "Configuration '#{configuration}' not found" unless config

        config.build_settings
      end

      # Get bundle identifier
      def bundle_id(target_name = nil, configuration = 'Release')
        settings = build_settings(target_name, configuration)
        settings['PRODUCT_BUNDLE_IDENTIFIER']
      end

      # Get development team
      def team_id(target_name = nil, configuration = 'Release')
        settings = build_settings(target_name, configuration)
        settings['DEVELOPMENT_TEAM']
      end

      # Get code sign identity
      def code_sign_identity(target_name = nil, configuration = 'Release')
        settings = build_settings(target_name, configuration)
        settings['CODE_SIGN_IDENTITY']
      end

      # Get provisioning profile specifier
      def provisioning_profile(target_name = nil, configuration = 'Release')
        settings = build_settings(target_name, configuration)
        settings['PROVISIONING_PROFILE_SPECIFIER']
      end

      # Get code sign style (Automatic or Manual)
      def code_sign_style(target_name = nil, configuration = 'Release')
        settings = build_settings(target_name, configuration)
        settings['CODE_SIGN_STYLE']
      end

      # Get all configurations
      def configurations(target_name = nil)
        target = find_target(target_name)
        target.build_configurations.map(&:name)
      end

      # Check if signing is configured
      def signing_configured?(target_name = nil, configuration = 'Release')
        profile = provisioning_profile(target_name, configuration)
        identity = code_sign_identity(target_name, configuration)

        !profile.to_s.empty? && !identity.to_s.empty?
      end

      # Get product name
      def product_name(target_name = nil, configuration = 'Release')
        settings = build_settings(target_name, configuration)
        settings['PRODUCT_NAME'] || find_target(target_name).name
      end

      # Find a target by name (public method for use by other classes)
      def find_target(target_name)
        return main_target if target_name.nil?

        target = @project.targets.find { |t| t.name == target_name }
        raise "Target '#{target_name}' not found" unless target

        target
      end

      def open_project
        if @project_info[:type] == :workspace
          # Workspace contains multiple projects
          # Get the main project (not Pods)
          workspace = Xcodeproj::Workspace.new_from_xcworkspace(@project_info[:path])

          project_ref = workspace.file_references.find do |ref|
            !ref.path.include?('Pods') && ref.path.end_with?('.xcodeproj')
          end

          raise 'No main project found in workspace' unless project_ref

          project_path = File.join(File.dirname(@project_info[:path]), project_ref.path)
          Xcodeproj::Project.open(project_path)
        else
          Xcodeproj::Project.open(@project_info[:path])
        end
      end
    end
  end
end
