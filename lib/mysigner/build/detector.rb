module Mysigner
  module Build
    class Detector
      class NoProjectError < StandardError; end

      # Detect project in directory
      # Returns: { platform: :ios/:android, type: :workspace/:project/:gradle, path: String, framework: :capacitor/:react_native/:flutter/:native }
      # @param directory [String] Directory to search in
      # @param platform [Symbol, nil] Force detection for specific platform (:ios, :android, or nil for auto-detect iOS)
      def self.detect(directory = Dir.pwd, platform: nil)
        # If platform is explicitly android, detect android
        if platform == :android
          return detect_android(directory)
        end

        # Default behavior: detect iOS (backwards compatible)
        detect_ios(directory)
      end

      # Detect Android project in directory
      # Returns: { platform: :android, type: :gradle, path: String, framework: :capacitor/:react_native/:flutter/:native }
      def self.detect_android(directory = Dir.pwd)
        # 1. Check for Capacitor (most specific first)
        if File.exist?("#{directory}/capacitor.config.json") || 
           File.exist?("#{directory}/capacitor.config.ts")
          return detect_capacitor_android(directory)
        end

        # 2. Check for Expo (managed workflow - no android folder)
        if (File.exist?("#{directory}/app.json") || File.exist?("#{directory}/app.config.js")) &&
           File.exist?("#{directory}/package.json")
          content = File.read("#{directory}/package.json")
          if content.include?('expo') && !Dir.exist?("#{directory}/android")
            # Auto-run expo prebuild
            puts "\n📦 Expo managed workflow detected (no android/ folder)"
            puts "🔧 Running: npx expo prebuild --platform android\n\n"
            
            result = system("cd #{directory} && npx expo prebuild --platform android")
            
            unless result && Dir.exist?("#{directory}/android")
              raise NoProjectError, <<~ERROR
                Failed to generate Android project with expo prebuild.
                
                Try running manually:
                  npx expo prebuild --platform android
                
                Alternative: Use EAS Build (Expo's cloud service)
                Learn more: https://docs.expo.dev/bare/overview/
              ERROR
            end
            
            puts "\n✓ Android project generated successfully\n\n"
          end
        end

        # 3. Check for React Native
        if File.exist?("#{directory}/package.json") && Dir.exist?("#{directory}/android")
          content = File.read("#{directory}/package.json")
          if content.include?('react-native')
            return detect_react_native_android(directory)
          end
        end

        # 3. Check for Flutter
        if File.exist?("#{directory}/pubspec.yaml")
          return detect_flutter_android(directory)
        end

        # 4. Check for .NET MAUI / Xamarin
        maui_project = Dir.glob("#{directory}/*.csproj").first
        if maui_project
          content = File.read(maui_project)
          if content.include?('Maui') || content.include?('Xamarin.Forms') || content.include?('Xamarin.Android')
            return detect_dotnet_android(directory, maui_project)
          end
        end

        # 5. Check for native Android project
        # Look for app/build.gradle (standard Android project structure)
        app_gradle = "#{directory}/app/build.gradle"
        app_gradle_kts = "#{directory}/app/build.gradle.kts"
        root_gradle = "#{directory}/build.gradle"
        root_gradle_kts = "#{directory}/build.gradle.kts"
        settings_gradle = "#{directory}/settings.gradle"
        settings_gradle_kts = "#{directory}/settings.gradle.kts"

        if File.exist?(app_gradle) || File.exist?(app_gradle_kts)
          return {
            platform: :android,
            type: :gradle,
            path: File.absolute_path(directory),
            framework: :native,
            directory: directory,
            android_directory: directory,
            app_build_gradle: File.exist?(app_gradle) ? app_gradle : app_gradle_kts
          }
        end

        # Check for single-module project (build.gradle at root with android block)
        if File.exist?(root_gradle) || File.exist?(root_gradle_kts)
          gradle_file = File.exist?(root_gradle) ? root_gradle : root_gradle_kts
          content = File.read(gradle_file)
          if content.include?('android {') || content.include?('android{')
            return {
              platform: :android,
              type: :gradle,
              path: File.absolute_path(directory),
              framework: :native,
              directory: directory,
              android_directory: directory,
              app_build_gradle: gradle_file
            }
          end
        end

        raise NoProjectError, "No Android project found in #{directory}. Run in an Android project directory."
      end

      # Detect iOS project in directory (original detect behavior)
      def self.detect_ios(directory = Dir.pwd)
        # 1. Check for Capacitor (most specific first)
        if File.exist?("#{directory}/capacitor.config.json") || 
           File.exist?("#{directory}/capacitor.config.ts")
          return detect_capacitor(directory)
        end

        # 2. Check for Expo (managed workflow)
        if (File.exist?("#{directory}/app.json") || File.exist?("#{directory}/app.config.js")) &&
           File.exist?("#{directory}/package.json")
          content = File.read("#{directory}/package.json")
          if content.include?('expo') && !Dir.exist?("#{directory}/ios")
            # Auto-run expo prebuild
            puts "\n📦 Expo managed workflow detected (no ios/ folder)"
            puts "🔧 Running: npx expo prebuild --platform ios\n\n"
            
            result = system("cd #{directory} && npx expo prebuild --platform ios")
            
            unless result && Dir.exist?("#{directory}/ios")
              raise NoProjectError, <<~ERROR
                Failed to generate iOS project with expo prebuild.
                
                Try running manually:
                  npx expo prebuild --platform ios
                
                Alternative: Use EAS Build (Expo's cloud service)
                Learn more: https://docs.expo.dev/bare/overview/
              ERROR
            end
            
            puts "\n✓ iOS project generated successfully\n\n"
          end
        end

        # 3. Check for React Native
        if File.exist?("#{directory}/package.json") && Dir.exist?("#{directory}/ios")
          content = File.read("#{directory}/package.json")
          if content.include?('react-native')
            return detect_react_native(directory)
          end
        end

        # 4. Check for Flutter
        if File.exist?("#{directory}/pubspec.yaml")
          return detect_flutter(directory)
        end

        # 5. Check for native iOS project (workspace first, then project)
        workspace = Dir.glob("#{directory}/*.xcworkspace").first
        if workspace
          return {
            platform: :ios,
            type: :workspace,
            path: File.absolute_path(workspace),
            framework: :native,
            directory: directory
          }
        end

        project = Dir.glob("#{directory}/*.xcodeproj").first
        if project
          return {
            platform: :ios,
            type: :project,
            path: File.absolute_path(project),
            framework: :native,
            directory: directory
          }
        end

        raise NoProjectError, "No Xcode project found in #{directory}. Run in a project directory or try 'mysigner init' first."
      end

      private

      # Android detection for cross-platform frameworks

      def self.detect_capacitor_android(directory)
        android_dir = "#{directory}/android"
        
        unless Dir.exist?(android_dir)
          raise NoProjectError, "Capacitor project detected but no android/ folder found. Run 'npx cap add android' first."
        end

        app_gradle = "#{android_dir}/app/build.gradle"
        app_gradle_kts = "#{android_dir}/app/build.gradle.kts"

        if File.exist?(app_gradle) || File.exist?(app_gradle_kts)
          return {
            platform: :android,
            type: :gradle,
            path: File.absolute_path(android_dir),
            framework: :capacitor,
            directory: directory,
            android_directory: android_dir,
            app_build_gradle: File.exist?(app_gradle) ? app_gradle : app_gradle_kts
          }
        end

        raise NoProjectError, "Capacitor project detected but no Android build.gradle found. Run 'npx cap sync android' first."
      end

      def self.detect_react_native_android(directory)
        android_dir = "#{directory}/android"

        app_gradle = "#{android_dir}/app/build.gradle"
        app_gradle_kts = "#{android_dir}/app/build.gradle.kts"

        if File.exist?(app_gradle) || File.exist?(app_gradle_kts)
          return {
            platform: :android,
            type: :gradle,
            path: File.absolute_path(android_dir),
            framework: :react_native,
            directory: directory,
            android_directory: android_dir,
            app_build_gradle: File.exist?(app_gradle) ? app_gradle : app_gradle_kts
          }
        end

        raise NoProjectError, "React Native project detected but no Android build.gradle found in android/ directory."
      end

      def self.detect_flutter_android(directory)
        android_dir = "#{directory}/android"

        unless Dir.exist?(android_dir)
          raise NoProjectError, "Flutter project detected but no android/ folder found. Run 'flutter create .' first."
        end

        app_gradle = "#{android_dir}/app/build.gradle"
        app_gradle_kts = "#{android_dir}/app/build.gradle.kts"

        if File.exist?(app_gradle) || File.exist?(app_gradle_kts)
          return {
            platform: :android,
            type: :gradle,
            path: File.absolute_path(android_dir),
            framework: :flutter,
            directory: directory,
            android_directory: android_dir,
            app_build_gradle: File.exist?(app_gradle) ? app_gradle : app_gradle_kts
          }
        end

        raise NoProjectError, "Flutter project detected but no Android build.gradle found. Run 'flutter build apk' first."
      end

      def self.detect_dotnet_android(directory, csproj_path)
        content = File.read(csproj_path)
        
        framework_type = if content.include?('Maui')
          :maui
        elsif content.include?('Xamarin.Forms')
          :xamarin_forms
        else
          :xamarin
        end

        {
          platform: :android,
          type: :dotnet,
          path: File.absolute_path(csproj_path),
          framework: framework_type,
          directory: directory,
          android_directory: directory,
          csproj_path: csproj_path
        }
      end

      # iOS detection for cross-platform frameworks (existing methods)

      def self.detect_capacitor(directory)
        ios_dir = "#{directory}/ios/App"
        
        # Capacitor always creates App.xcworkspace
        workspace = "#{ios_dir}/App.xcworkspace"
        project = "#{ios_dir}/App.xcodeproj"

        if File.exist?(workspace)
          return {
            platform: :ios,
            type: :workspace,
            path: File.absolute_path(workspace),
            framework: :capacitor,
            directory: directory,
            ios_directory: ios_dir
          }
        elsif File.exist?(project)
          return {
            platform: :ios,
            type: :project,
            path: File.absolute_path(project),
            framework: :capacitor,
            directory: directory,
            ios_directory: ios_dir
          }
        end

        raise NoProjectError, "Capacitor project detected but no Xcode project found. Run 'npx cap sync ios' first."
      end

      def self.detect_react_native(directory)
        ios_dir = "#{directory}/ios"

        # Look for workspace first (CocoaPods)
        workspace = Dir.glob("#{ios_dir}/*.xcworkspace").first
        if workspace
          return {
            platform: :ios,
            type: :workspace,
            path: File.absolute_path(workspace),
            framework: :react_native,
            directory: directory,
            ios_directory: ios_dir
          }
        end

        # Fall back to project
        project = Dir.glob("#{ios_dir}/*.xcodeproj").first
        if project
          return {
            platform: :ios,
            type: :project,
            path: File.absolute_path(project),
            framework: :react_native,
            directory: directory,
            ios_directory: ios_dir
          }
        end

        raise NoProjectError, "React Native project detected but no Xcode project found in ios/ directory."
      end

      def self.detect_flutter(directory)
        ios_dir = "#{directory}/ios"

        # Flutter typically uses Runner.xcworkspace
        workspace = "#{ios_dir}/Runner.xcworkspace"
        if File.exist?(workspace)
          return {
            platform: :ios,
            type: :workspace,
            path: File.absolute_path(workspace),
            framework: :flutter,
            directory: directory,
            ios_directory: ios_dir
          }
        end

        # Fall back to Runner.xcodeproj
        project = "#{ios_dir}/Runner.xcodeproj"
        if File.exist?(project)
          return {
            platform: :ios,
            type: :project,
            path: File.absolute_path(project),
            framework: :flutter,
            directory: directory,
            ios_directory: ios_dir
          }
        end

        raise NoProjectError, "Flutter project detected but no Xcode project found. Run 'flutter build ios' first."
      end
    end
  end
end

