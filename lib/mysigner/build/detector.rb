# frozen_string_literal: true

require 'json'

module Mysigner
  module Build
    class Detector
      class NoProjectError < StandardError; end

      # Detect project in directory
      # Returns: { platform: :ios/:android, type: :workspace/:project/:gradle, path: String, framework: :capacitor/:react_native/:flutter/:native }
      # @param directory [String] Directory to search in
      # @param platform [Symbol, nil] Force detection for specific platform (:ios, :android, or nil for auto-detect iOS)
      # @param allow_prebuild [Boolean] when false (doctor/validate and other
      #   read-only callers), an Expo managed project with no native folder is
      #   CLASSIFIED (framework: :expo, needs_prebuild: true) instead of having
      #   `npx expo prebuild` run against it. Detection must never mutate the
      #   working tree from a diagnostic path.
      def self.detect(directory = Dir.pwd, platform: nil, allow_prebuild: true)
        # If platform is explicitly android, detect android
        return detect_android(directory, allow_prebuild: allow_prebuild) if platform == :android

        # Default behavior: detect iOS (backwards compatible)
        detect_ios(directory, allow_prebuild: allow_prebuild)
      end

      # ── Expo helpers ─────────────────────────────────────────────────────

      # True when this looks like an Expo project: an app.json/app.config.js
      # plus `expo` as an ACTUAL dependency in package.json. We parse the JSON
      # rather than substring-scanning the file so an unrelated package like
      # `eslint-config-expo`, or the word "expo" in a script, doesn't trip
      # detection (and the destructive prebuild it gates).
      def self.expo_managed?(directory)
        return false unless File.exist?("#{directory}/app.json") || File.exist?("#{directory}/app.config.js")
        return false unless File.exist?("#{directory}/package.json")

        pkg = begin
          JSON.parse(File.read("#{directory}/package.json"))
        rescue StandardError
          nil
        end
        return false unless pkg.is_a?(Hash)

        deps = {}
        deps.merge!(pkg['dependencies']) if pkg['dependencies'].is_a?(Hash)
        deps.merge!(pkg['devDependencies']) if pkg['devDependencies'].is_a?(Hash)
        deps.key?('expo')
      end

      # Non-mutating classification for an Expo managed project that has no
      # native folder yet. Callers must check :needs_prebuild before trying to
      # read gradle/xcode paths off the result.
      def self.expo_managed_result(directory, platform)
        {
          platform: platform,
          type: :expo_managed,
          framework: :expo,
          path: File.absolute_path(directory),
          directory: directory,
          needs_prebuild: true
        }
      end

      # Materialise the native project with `npx expo prebuild`, after a
      # precheck so the user gets an actionable message instead of expo's raw
      # ConfigError. Raises NoProjectError on any failure. The caller's
      # `!Dir.exist?(native/)` guard guarantees we never clobber an existing
      # native folder.
      def self.run_expo_prebuild!(directory, platform)
        ensure_expo_prereqs!(directory, platform)

        puts "\n📦 Expo managed workflow detected (no #{platform}/ folder)"
        puts "🔧 Running: npx expo prebuild --platform #{platform}\n\n"
        # Run via Dir.chdir + argv (no shell) so a project directory containing
        # a space or shell metacharacter isn't split/interpreted by /bin/sh.
        result = Dir.chdir(directory) { system('npx', 'expo', 'prebuild', '--platform', platform.to_s) }

        native_dir = platform == :android ? 'android' : 'ios'
        return if result && Dir.exist?("#{directory}/#{native_dir}")

        raise NoProjectError, expo_prebuild_failed_message(platform)
      end

      # Fail fast (before shelling out) for the two common prebuild blockers.
      def self.ensure_expo_prereqs!(directory, platform)
        unless Dir.exist?("#{directory}/node_modules/expo")
          install = install_command(detect_package_manager(directory))
          raise NoProjectError, expo_prebuild_failed_message(
            platform, hint: "JavaScript dependencies aren't installed. Run `#{install}` in the project first."
          )
        end

        major = node_major_version
        return unless major && major < 20

        raise NoProjectError, expo_prebuild_failed_message(
          platform, hint: "Node.js #{major}.x is too old for current Expo SDKs — " \
                          'install Node >= 20.19.4 (e.g. via nvm, mise, or nodejs.org).'
        )
      end

      def self.node_major_version
        out = `node --version 2>/dev/null`.to_s.strip
        m = out.match(/v?(\d+)\./)
        m && m[1].to_i
      rescue StandardError
        nil
      end

      # Detect the JS package manager from the lockfile so we suggest the EXACT
      # install command for this project. Running the wrong one (e.g. `npm
      # install` on a yarn/pnpm project) can corrupt the dependency tree, so we
      # never guess blindly.
      def self.detect_package_manager(directory)
        return :yarn if File.exist?("#{directory}/yarn.lock")
        return :pnpm if File.exist?("#{directory}/pnpm-lock.yaml")
        return :bun if File.exist?("#{directory}/bun.lockb") || File.exist?("#{directory}/bun.lock")

        :npm
      end

      def self.install_command(pkg_manager)
        { yarn: 'yarn install', pnpm: 'pnpm install', bun: 'bun install' }.fetch(pkg_manager, 'npm install')
      end

      def self.expo_prebuild_failed_message(platform, hint: nil)
        native = platform == :android ? 'Android' : 'iOS'
        parts = ["Failed to generate #{native} project with expo prebuild."]
        parts << hint if hint
        parts << <<~ERROR.strip
          Try running manually:
            npx expo prebuild --platform #{platform}

          Alternative: Use EAS Build (Expo's cloud service)
          Learn more: https://docs.expo.dev/bare/overview/
        ERROR
        parts.join("\n\n")
      end

      # Detect Android project in directory
      # Returns: { platform: :android, type: :gradle, path: String, framework: :capacitor/:react_native/:flutter/:native }
      def self.detect_android(directory = Dir.pwd, allow_prebuild: true)
        # 1. Check for Capacitor (most specific first)
        if File.exist?("#{directory}/capacitor.config.json") ||
           File.exist?("#{directory}/capacitor.config.ts")
          return detect_capacitor_android(directory)
        end

        # 2. Expo managed workflow (app.json/app.config.js + `expo` dependency,
        #    no android/ yet). Read-only callers pass allow_prebuild: false and
        #    get a non-mutating classification instead of a prebuild + possible
        #    raise.
        if expo_managed?(directory) && !Dir.exist?("#{directory}/android")
          return expo_managed_result(directory, :android) unless allow_prebuild

          run_expo_prebuild!(directory, :android)
          puts "\n✓ Android project generated successfully\n\n"
        end

        # 3. Check for React Native
        if File.exist?("#{directory}/package.json") && Dir.exist?("#{directory}/android")
          content = File.read("#{directory}/package.json")
          return detect_react_native_android(directory) if content.include?('react-native')
        end

        # 3. Check for Flutter
        return detect_flutter_android(directory) if File.exist?("#{directory}/pubspec.yaml")

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
      def self.detect_ios(directory = Dir.pwd, allow_prebuild: true)
        # 1. Check for Capacitor (most specific first)
        if File.exist?("#{directory}/capacitor.config.json") ||
           File.exist?("#{directory}/capacitor.config.ts")
          return detect_capacitor(directory)
        end

        # 2. Expo managed workflow (see detect_android for the allow_prebuild
        #    contract).
        if expo_managed?(directory) && !Dir.exist?("#{directory}/ios")
          return expo_managed_result(directory, :ios) unless allow_prebuild

          run_expo_prebuild!(directory, :ios)
          puts "\n✓ iOS project generated successfully\n\n"
        end

        # 3. Check for React Native
        if File.exist?("#{directory}/package.json") && Dir.exist?("#{directory}/ios")
          content = File.read("#{directory}/package.json")
          return detect_react_native(directory) if content.include?('react-native')
        end

        # 4. Check for Flutter
        return detect_flutter(directory) if File.exist?("#{directory}/pubspec.yaml")

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

        raise NoProjectError,
              "No Xcode project found in #{directory}. Run in a project directory or try 'mysigner init' first."
      end

      # Android detection for cross-platform frameworks

      def self.detect_capacitor_android(directory)
        android_dir = "#{directory}/android"

        unless Dir.exist?(android_dir)
          raise NoProjectError,
                "Capacitor project detected but no android/ folder found. Run 'npx cap add android' first."
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

        raise NoProjectError,
              "Capacitor project detected but no Android build.gradle found. Run 'npx cap sync android' first."
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

        raise NoProjectError, 'React Native project detected but no Android build.gradle found in android/ directory.'
      end

      def self.detect_flutter_android(directory)
        android_dir = "#{directory}/android"

        raise NoProjectError, "Flutter project detected but no android/ folder found. Run 'flutter create .' first." unless Dir.exist?(android_dir)

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

        raise NoProjectError,
              "Flutter project detected but no Android build.gradle found. Run 'flutter build apk' first."
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

        raise NoProjectError, 'React Native project detected but no Xcode project found in ios/ directory.'
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
