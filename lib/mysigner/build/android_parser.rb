module Mysigner
  module Build
    class AndroidParser
      attr_reader :project_info

      def initialize(project_info)
        @project_info = project_info
        @gradle_content = read_gradle_file
        @manifest_content = read_manifest_file
      end

      # Get the application ID (package name)
      def application_id
        # Try to extract from build.gradle
        app_id = extract_from_gradle('applicationId')
        return app_id if app_id

        # Try namespace (newer Gradle)
        namespace = extract_from_gradle('namespace')
        return namespace if namespace

        # Try Expo app.json (for Expo projects)
        expo_package = extract_from_expo_config
        return expo_package if expo_package

        # Fallback to AndroidManifest.xml
        extract_package_from_manifest
      end

      alias package_name application_id

      # Get version code
      def version_code
        extract_from_gradle('versionCode')&.to_i
      end

      # Get version name
      def version_name
        extract_from_gradle('versionName')
      end

      # Get minimum SDK version
      def min_sdk_version
        extract_from_gradle('minSdk') || extract_from_gradle('minSdkVersion')
      end

      # Get target SDK version
      def target_sdk_version
        extract_from_gradle('targetSdk') || extract_from_gradle('targetSdkVersion')
      end

      # Get compile SDK version
      def compile_sdk_version
        extract_from_gradle('compileSdk') || extract_from_gradle('compileSdkVersion')
      end

      # Get all build types (debug, release, etc.)
      def build_types
        types = []
        
        # Match buildTypes block
        if @gradle_content =~ /buildTypes\s*\{(.*?)\n\s*\}/m
          block = $1
          # Find all type names (e.g., "release {" or "debug {")
          block.scan(/(\w+)\s*\{/) do |match|
            types << match[0] unless %w[debug release].include?(match[0]) && types.include?(match[0])
            types << match[0]
          end
        end
        
        # Default build types if none found
        types = ['debug', 'release'] if types.empty?
        types.uniq
      end

      # Get all product flavors
      def product_flavors
        flavors = []
        
        if @gradle_content =~ /productFlavors\s*\{(.*?)\n\s{4}\}/m
          block = $1
          block.scan(/(\w+)\s*\{/) do |match|
            flavors << match[0]
          end
        end
        
        flavors
      end

      # Get signing config for a build type
      def signing_config(build_type = 'release')
        # Look for signingConfig in the build type block
        if @gradle_content =~ /#{build_type}\s*\{[^}]*signingConfig\s*(?:=\s*)?signingConfigs\.(\w+)/m
          return $1
        end
        nil
      end

      # Check if signing is configured for release builds
      def signing_configured?(build_type = 'release')
        signing_config(build_type) != nil
      end

      # Get signing configs defined in the project
      def signing_configs
        configs = []
        
        if @gradle_content =~ /signingConfigs\s*\{(.*?)\n\s{4}\}/m
          block = $1
          block.scan(/(\w+)\s*\{/) do |match|
            configs << match[0]
          end
        end
        
        configs
      end

      # Get keystore path from signing config
      def keystore_path(config_name = 'release')
        if @gradle_content =~ /#{config_name}\s*\{[^}]*storeFile\s*(?:=\s*)?(?:file\()?"?([^")\n]+)"?\)?/m
          return $1
        end
        nil
      end

      # Get keystore alias from signing config
      def keystore_alias(config_name = 'release')
        if @gradle_content =~ /#{config_name}\s*\{[^}]*keyAlias\s*(?:=\s*)?["']?([^"'\n]+)["']?/m
          return $1.strip
        end
        nil
      end

      # Get the app name from strings.xml or manifest
      def app_name
        # Try strings.xml first
        strings_path = File.join(android_directory, 'app/src/main/res/values/strings.xml')
        if File.exist?(strings_path)
          content = File.read(strings_path)
          if content =~ /<string\s+name="app_name"[^>]*>([^<]+)<\/string>/
            return $1
          end
        end

        # Fallback to manifest label
        if @manifest_content && @manifest_content =~ /android:label="([^"]+)"/
          return $1
        end

        # Fallback to directory name
        File.basename(@project_info[:directory])
      end

      # Check if project uses Kotlin DSL
      def kotlin_dsl?
        @project_info[:app_build_gradle]&.end_with?('.kts')
      end

      # Get the gradle wrapper command
      def gradle_command
        wrapper_path = File.join(android_directory, 'gradlew')
        File.exist?(wrapper_path) ? './gradlew' : 'gradle'
      end

      # Check if gradle wrapper exists
      def gradle_wrapper_exists?
        File.exist?(File.join(android_directory, 'gradlew'))
      end

      # Get available build variants (build type + flavor combinations)
      def build_variants
        flavors = product_flavors
        types = build_types

        if flavors.empty?
          types.map { |t| t }
        else
          flavors.flat_map do |flavor|
            types.map { |type| "#{flavor}#{type.capitalize}" }
          end
        end
      end

      # Get AAB output path for a variant
      def aab_output_path(variant = 'release')
        # Standard output location
        File.join(android_directory, "app/build/outputs/bundle/#{variant}/app-#{variant}.aab")
      end

      # Get APK output path for a variant
      def apk_output_path(variant = 'release')
        File.join(android_directory, "app/build/outputs/apk/#{variant}/app-#{variant}.apk")
      end

      # Get Android directory
      def android_directory
        @project_info[:android_directory] || @project_info[:path]
      end

      # Get project summary
      def summary
        {
          application_id: application_id,
          version_code: version_code,
          version_name: version_name,
          min_sdk: min_sdk_version,
          target_sdk: target_sdk_version,
          build_types: build_types,
          product_flavors: product_flavors,
          signing_configured: signing_configured?,
          kotlin_dsl: kotlin_dsl?,
          gradle_wrapper: gradle_wrapper_exists?
        }
      end

      private

      def read_gradle_file
        gradle_path = @project_info[:app_build_gradle]
        
        unless gradle_path && File.exist?(gradle_path)
          # Try to find it
          android_dir = android_directory
          gradle_path = File.join(android_dir, 'app/build.gradle')
          gradle_path = File.join(android_dir, 'app/build.gradle.kts') unless File.exist?(gradle_path)
          gradle_path = File.join(android_dir, 'build.gradle') unless File.exist?(gradle_path)
          gradle_path = File.join(android_dir, 'build.gradle.kts') unless File.exist?(gradle_path)
        end

        return '' unless File.exist?(gradle_path)
        File.read(gradle_path)
      end

      def read_manifest_file
        manifest_path = File.join(android_directory, 'app/src/main/AndroidManifest.xml')
        return nil unless File.exist?(manifest_path)
        File.read(manifest_path)
      end

      def extract_from_gradle(property)
        # Handle both Groovy and Kotlin DSL syntax
        # Groovy: applicationId "com.example.app" or applicationId = "com.example.app"
        # Kotlin: applicationId = "com.example.app"
        
        patterns = [
          /#{property}\s*=?\s*["']([^"']+)["']/,
          /#{property}\s+["']([^"']+)["']/,
          /#{property}\s*=\s*(\d+)/,
          /#{property}\s+(\d+)/
        ]

        patterns.each do |pattern|
          if @gradle_content =~ pattern
            return $1
          end
        end

        nil
      end

      def extract_package_from_manifest
        return nil unless @manifest_content
        
        if @manifest_content =~ /package="([^"]+)"/
          return $1
        end
        
        nil
      end

      def extract_from_expo_config
        # Check for app.json in project root
        project_dir = @project_info[:directory]
        app_json_path = File.join(project_dir, 'app.json')
        
        return nil unless File.exist?(app_json_path)
        
        begin
          require 'json'
          config = JSON.parse(File.read(app_json_path))
          
          # Expo config can be nested under 'expo' key or at root
          expo_config = config['expo'] || config
          
          # Get Android package name
          expo_config.dig('android', 'package')
        rescue
          nil
        end
      end
    end
  end
end
