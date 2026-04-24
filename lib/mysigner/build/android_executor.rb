# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'tempfile'

module Mysigner
  module Build
    class AndroidExecutor
      class BuildError < StandardError; end

      def initialize(project_info, parser)
        @project_info = project_info
        @parser = parser
      end

      # Build AAB (Android App Bundle) for Play Store
      # Returns: path to .aab file
      # Options:
      #   - variant: Build variant (default: 'release')
      #   - keystore_path: Path to keystore file
      #   - keystore_password: Keystore password
      #   - key_alias: Key alias in keystore
      #   - key_password: Key password (defaults to keystore_password)
      #   - version_code: Override version code (passed via gradle property)
      def build_aab!(variant: 'release', keystore_path: nil, keystore_password: nil, key_alias: nil, key_password: nil,
                     version_code: nil)
        @variant = variant
        @keystore_path = keystore_path
        @keystore_password = keystore_password
        @key_alias = key_alias
        @key_password = key_password || keystore_password
        @version_code = version_code

        # Determine task name
        task = "bundle#{variant.capitalize}"

        # Build
        success = run_gradle_build(task)

        raise BuildError, 'Android build failed. Check output above for errors.' unless success

        # Find output AAB
        aab_path = find_aab_output(variant)

        unless aab_path && File.exist?(aab_path)
          raise BuildError, "Build reported success but AAB not found. Expected at: #{@parser.aab_output_path(variant)}"
        end

        aab_path
      end

      # Build APK
      # Returns: path to .apk file
      def build_apk!(variant: 'release', keystore_path: nil, keystore_password: nil, key_alias: nil, key_password: nil)
        @variant = variant
        @keystore_path = keystore_path
        @keystore_password = keystore_password
        @key_alias = key_alias
        @key_password = key_password || keystore_password

        # Determine task name
        task = "assemble#{variant.capitalize}"

        # Build
        success = run_gradle_build(task)

        raise BuildError, 'Android build failed. Check output above for errors.' unless success

        # Find output APK
        apk_path = find_apk_output(variant)

        unless apk_path && File.exist?(apk_path)
          raise BuildError, "Build reported success but APK not found. Expected at: #{@parser.apk_output_path(variant)}"
        end

        apk_path
      end

      # Clean build outputs
      def clean!
        run_gradle_command('clean')
      end

      private

      def run_gradle_build(task)
        # Ensure JAVA_HOME is valid
        ensure_java_home!

        # Handle framework-specific pre-build steps
        run_pre_build_steps

        # Phase 0: inject signing via Gradle init-script + env vars. Passwords
        # never appear in argv (no -Pandroid.injected.signing.*=PLAINTEXT).
        injector = nil
        if @keystore_path && File.exist?(@keystore_path)
          require 'mysigner/signing/gradle_signing_injector'
          injector = Mysigner::Signing::GradleSigningInjector.new
          @signing_init_script_path = injector.write_init_script!
        end

        begin
          # Build command with signing properties referencing the init script
          cmd = build_gradle_command(task)
          execute_with_output(cmd)
        ensure
          injector&.cleanup!
          @signing_init_script_path = nil
        end
      end

      def ensure_java_home!
        java_home = ENV.fetch('JAVA_HOME', nil)

        # Check if JAVA_HOME is set and valid
        if java_home && !java_home.empty? && Dir.exist?(java_home)
          # All good
        else
          # Try to detect valid JAVA_HOME
          detected = detect_java_home
          if detected
            puts "🔧 Auto-detected JAVA_HOME: #{detected}"
            ENV['JAVA_HOME'] = detected
          elsif java_home && !java_home.empty?
            raise BuildError, "JAVA_HOME is set to invalid directory: #{java_home}\n" \
                              "Run 'mysigner doctor' to fix, or set JAVA_HOME manually:\n  " \
                              'export JAVA_HOME=$(/usr/libexec/java_home -v 17)'
          end
        end

        # Also ensure ANDROID_HOME is set
        ensure_android_home!
      end

      def ensure_android_home!
        android_home = ENV['ANDROID_HOME'] || ENV.fetch('ANDROID_SDK_ROOT', nil)

        # Check if already valid
        return if android_home && !android_home.empty? && Dir.exist?(android_home)

        # Try to detect Android SDK
        detected = detect_android_home
        if detected
          puts "🔧 Auto-detected ANDROID_HOME: #{detected}"
          ENV['ANDROID_HOME'] = detected
          ENV['ANDROID_SDK_ROOT'] = detected
        else
          raise BuildError, "Android SDK not found.\n" \
                            "Run 'mysigner doctor' to diagnose, or set ANDROID_HOME:\n  " \
                            'export ANDROID_HOME=~/Library/Android/sdk'
        end
      end

      def detect_android_home
        # Common SDK locations
        candidates = [
          File.expand_path('~/Library/Android/sdk'),
          File.expand_path('~/Android/Sdk'),
          '/opt/homebrew/share/android-commandlinetools',
          '/usr/local/share/android-commandlinetools'
        ]

        candidates.each do |path|
          return path if Dir.exist?(path) && Dir.exist?(File.join(path, 'platform-tools'))
        end

        nil
      end

      def detect_java_home
        # Try macOS java_home utility first
        if system('which /usr/libexec/java_home > /dev/null 2>&1')
          java_home = `/usr/libexec/java_home 2>/dev/null`.strip
          return java_home if !java_home.empty? && Dir.exist?(java_home)
        end

        # Try Homebrew paths (Apple Silicon)
        %w[
          /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
          /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
          /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
        ].each { |p| return p if Dir.exist?(p) }

        # Try Homebrew paths (Intel)
        %w[
          /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
          /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
          /usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home
        ].each { |p| return p if Dir.exist?(p) }

        # Try system Java
        system_paths = Dir.glob('/Library/Java/JavaVirtualMachines/*/Contents/Home')
        return system_paths.first if system_paths.any?

        nil
      end

      def run_pre_build_steps
        case @project_info[:framework]
        when :capacitor
          # Capacitor: sync before build
          puts '🔄 Syncing Capacitor...'
          Dir.chdir(@project_info[:directory]) do
            system('npx cap sync android > /dev/null 2>&1')
          end
        when :react_native
          # React Native: might need to install dependencies
          if File.exist?(File.join(@project_info[:directory], 'node_modules'))
            # Dependencies already installed
          else
            puts '📦 Installing npm dependencies...'
            Dir.chdir(@project_info[:directory]) do
              system('npm install > /dev/null 2>&1') || system('yarn install > /dev/null 2>&1')
            end
          end
        when :flutter
          # Flutter: ensure dependencies are fetched
          puts '📦 Getting Flutter dependencies...'
          Dir.chdir(@project_info[:directory]) do
            system('flutter pub get > /dev/null 2>&1')
          end
        end
      end

      def build_gradle_command(task)
        android_dir = @parser.android_directory
        gradle_cmd = @parser.gradle_command

        cmd_parts = []

        # Export JAVA_HOME if we detected/fixed it
        java_home = ENV.fetch('JAVA_HOME', nil)
        if java_home && Dir.exist?(java_home)
          cmd_parts << "export JAVA_HOME=#{shell_escape(java_home)}"
          cmd_parts << '&&'
        end

        # Export ANDROID_HOME if we detected/fixed it
        android_home = ENV.fetch('ANDROID_HOME', nil)
        if android_home && Dir.exist?(android_home)
          cmd_parts << "export ANDROID_HOME=#{shell_escape(android_home)}"
          cmd_parts << '&&'
          cmd_parts << "export ANDROID_SDK_ROOT=#{shell_escape(android_home)}"
          cmd_parts << '&&'
        end

        # Phase 0: export signing env vars inline so they're only visible to
        # the child process, not in argv. The Gradle init script below reads
        # MYSIGNER_STORE_FILE / MYSIGNER_STORE_PASSWORD / MYSIGNER_KEY_ALIAS /
        # MYSIGNER_KEY_PASSWORD and configures signingConfigs.release.
        if @keystore_path && File.exist?(@keystore_path) && @signing_init_script_path
          cmd_parts << "export MYSIGNER_STORE_FILE=#{shell_escape(File.absolute_path(@keystore_path))}"
          cmd_parts << '&&'
          cmd_parts << "export MYSIGNER_STORE_PASSWORD=#{shell_escape(@keystore_password)}" if @keystore_password
          cmd_parts << '&&' if @keystore_password
          cmd_parts << "export MYSIGNER_KEY_ALIAS=#{shell_escape(@key_alias)}" if @key_alias
          cmd_parts << '&&' if @key_alias
          cmd_parts << "export MYSIGNER_KEY_PASSWORD=#{shell_escape(@key_password)}" if @key_password
          cmd_parts << '&&' if @key_password
        end

        # Change to android directory and run gradle
        cmd_parts << "cd #{shell_escape(android_dir)}"
        cmd_parts << '&&'
        cmd_parts << gradle_cmd

        # Reference the init script (contains the signing-config override)
        if @signing_init_script_path
          cmd_parts << '--init-script'
          cmd_parts << shell_escape(@signing_init_script_path)
        end

        cmd_parts << task

        # Add version code override if provided (no file modification needed)
        cmd_parts << "-PversionCode=#{@version_code}" if @version_code

        # Standard build options
        cmd_parts << '--no-daemon'  # Avoid daemon issues in CI
        cmd_parts << '-q'           # Quiet mode (less noise)

        cmd_parts.join(' ')
      end

      def run_gradle_command(task)
        android_dir = @parser.android_directory
        gradle_cmd = @parser.gradle_command

        exports = []
        java_home = ENV.fetch('JAVA_HOME', nil)
        exports << "export JAVA_HOME=#{shell_escape(java_home)}" if java_home && Dir.exist?(java_home)

        android_home = ENV.fetch('ANDROID_HOME', nil)
        if android_home && Dir.exist?(android_home)
          exports << "export ANDROID_HOME=#{shell_escape(android_home)}"
          exports << "export ANDROID_SDK_ROOT=#{shell_escape(android_home)}"
        end

        export_str = exports.any? ? "#{exports.join(' && ')} && " : ''
        cmd = "#{export_str}cd #{shell_escape(android_dir)} && #{gradle_cmd} #{task} --no-daemon -q"
        system(cmd)
      end

      def execute_with_output(cmd)
        puts "🏗️  Running: gradle #{@variant}..."
        puts ''

        # Run command and capture output in real-time
        IO.popen("#{cmd} 2>&1", 'r') do |io|
          io.each_line do |line|
            next if line.strip.empty?

            # Show errors and warnings
            if line.include?('FAILURE') || line.include?('ERROR') || line.include?('error:')
              puts line
            elsif line.include?('warning:') || line.include?('WARNING')
              puts line
            # Show task progress
            elsif line.include?('> Task') || line.include?('BUILD')
              print '.'
            # Show download progress
            elsif line.include?('Download')
              # Skip verbose download logs
            end
          end
        end

        puts '' # New line after dots

        $CHILD_STATUS.success?
      end

      def find_aab_output(variant)
        android_dir = @parser.android_directory

        # Search patterns for AAB files
        patterns = [
          File.join(android_dir, "app/build/outputs/bundle/#{variant}/*.aab"),
          File.join(android_dir, "app/build/outputs/bundle/#{variant.downcase}/*.aab"),
          File.join(android_dir, "build/outputs/bundle/#{variant}/*.aab"),
          # Flutter uses different naming
          File.join(android_dir, "app/build/outputs/bundle/#{variant}/app-#{variant}.aab"),
          File.join(android_dir, "build/app/outputs/bundle/#{variant}/*.aab")
        ]

        patterns.each do |pattern|
          matches = Dir.glob(pattern)
          return matches.first if matches.any?
        end

        nil
      end

      def find_apk_output(variant)
        android_dir = @parser.android_directory

        # Search patterns for APK files
        patterns = [
          File.join(android_dir, "app/build/outputs/apk/#{variant}/*.apk"),
          File.join(android_dir, "app/build/outputs/apk/#{variant.downcase}/*.apk"),
          File.join(android_dir, "build/outputs/apk/#{variant}/*.apk"),
          File.join(android_dir, "app/build/outputs/apk/#{variant}/app-#{variant}.apk"),
          # Unsigned APKs
          File.join(android_dir, "app/build/outputs/apk/#{variant}/app-#{variant}-unsigned.apk")
        ]

        patterns.each do |pattern|
          matches = Dir.glob(pattern)
          return matches.first if matches.any?
        end

        nil
      end

      def shell_escape(str)
        return "''" if str.nil? || str.empty?

        # If string contains no special characters, return as-is
        return str if str =~ %r{\A[a-zA-Z0-9_.\-/]+\z}

        # Otherwise, quote it
        "'#{str.gsub("'", "'\\''")}'"
      end
    end
  end
end
