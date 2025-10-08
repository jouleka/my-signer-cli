module Mysigner
  module Build
    class Detector
      class NoProjectError < StandardError; end

      # Detect Xcode project in directory
      # Returns: { type: :workspace/:project, path: String, framework: :capacitor/:react_native/:flutter/:native }
      def self.detect(directory = Dir.pwd)
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
            raise NoProjectError, <<~ERROR
              Expo managed workflow detected.
              
              My Signer requires a native Xcode project to build locally.
              
              Options:
              1. Convert to bare workflow: expo prebuild
              2. Use EAS Build (Expo's cloud service)
              3. Use React Native bare or Capacitor instead
              
              Learn more: https://docs.expo.dev/bare/overview/
            ERROR
          end
        end

        # 3. Check for React Native
        if File.exist?("#{directory}/package.json") && Dir.exist?("#{directory}/ios")
          content = File.read("#{directory}/package.json")
          if content.include?('react-native')
            return detect_react_native(directory)
          end
        end

        # 3. Check for Flutter
        if File.exist?("#{directory}/pubspec.yaml")
          return detect_flutter(directory)
        end

        # 4. Check for native iOS project (workspace first, then project)
        workspace = Dir.glob("#{directory}/*.xcworkspace").first
        if workspace
          return {
            type: :workspace,
            path: File.absolute_path(workspace),
            framework: :native,
            directory: directory
          }
        end

        project = Dir.glob("#{directory}/*.xcodeproj").first
        if project
          return {
            type: :project,
            path: File.absolute_path(project),
            framework: :native,
            directory: directory
          }
        end

        raise NoProjectError, "No Xcode project found in #{directory}. Run in a project directory or try 'mysigner init' first."
      end

      private

      def self.detect_capacitor(directory)
        ios_dir = "#{directory}/ios/App"
        
        # Capacitor always creates App.xcworkspace
        workspace = "#{ios_dir}/App.xcworkspace"
        project = "#{ios_dir}/App.xcodeproj"

        if File.exist?(workspace)
          return {
            type: :workspace,
            path: File.absolute_path(workspace),
            framework: :capacitor,
            directory: directory,
            ios_directory: ios_dir
          }
        elsif File.exist?(project)
          return {
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

