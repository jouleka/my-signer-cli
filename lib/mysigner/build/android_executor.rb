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
        @build_started_at = Time.now

        # Determine task name
        task = "bundle#{variant_suffix(variant)}"

        # Build
        success = run_gradle_build(task)

        unless success
          raise BuildError, 'Android build failed — the details are in the Gradle output above. ' \
                            'Common causes: signing rejected (check keystore password/alias), a ' \
                            "missing SDK component (run 'mysigner doctor'), or a compile error in " \
                            "your app (look for 'error:' lines). Re-run with DEBUG=1 for more."
        end

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
        @build_started_at = Time.now

        # Determine task name
        task = "assemble#{variant_suffix(variant)}"

        # Build
        success = run_gradle_build(task)

        unless success
          raise BuildError, 'Android build failed — the details are in the Gradle output above. ' \
                            'Common causes: signing rejected (check keystore password/alias), a ' \
                            "missing SDK component (run 'mysigner doctor'), or a compile error in " \
                            "your app (look for 'error:' lines). Re-run with DEBUG=1 for more."
        end

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
        # Write the Gradle init script when we need to inject EITHER signing or
        # a versionCode override (a bare -PversionCode is ignored by stock
        # build.gradle, so versionCode must also flow through the init script).
        injector = nil
        if (@keystore_path && File.exist?(@keystore_path)) || @version_code
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
                              "Run 'mysigner doctor' to fix, or set JAVA_HOME to a valid JDK 17+ home\n  " \
                              '(macOS: $(/usr/libexec/java_home -v 17), Linux: a dir under /usr/lib/jvm).'
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
                            "Run 'mysigner doctor' to diagnose, or set ANDROID_HOME to your SDK path\n  " \
                            '(macOS: ~/Library/Android/sdk, Linux: ~/Android/Sdk).'
        end
      end

      def detect_android_home
        # Common SDK locations across macOS, Linux/WSL and Android Studio.
        candidates = [
          ENV.fetch('ANDROID_HOME', nil),
          ENV.fetch('ANDROID_SDK_ROOT', nil),
          File.expand_path('~/Library/Android/sdk'),   # macOS (Android Studio)
          File.expand_path('~/Android/Sdk'),           # Linux (Android Studio)
          File.expand_path('~/.android/sdk'),
          '/usr/lib/android-sdk',                      # Debian/Ubuntu package
          '/opt/android-sdk',
          '/opt/homebrew/share/android-commandlinetools',
          '/usr/local/share/android-commandlinetools'
        ].compact

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

        # Try system Java (macOS)
        system_paths = Dir.glob('/Library/Java/JavaVirtualMachines/*/Contents/Home')
        return system_paths.first if system_paths.any?

        # Linux / WSL: resolve from the javac/java symlink, then /usr/lib/jvm.
        detect_java_home_linux
      end

      # JAVA_HOME detection for Linux/WSL. Follows the real javac/java binary to
      # its JDK home, then falls back to the newest /usr/lib/jvm install.
      def detect_java_home_linux
        %w[javac java].each do |bin|
          path = `command -v #{bin} 2>/dev/null`.to_s.strip
          next if path.empty?

          real = begin
            File.realpath(path)
          rescue StandardError
            path
          end
          # .../<jdk>/bin/java -> JAVA_HOME is two levels up
          home = File.expand_path('../..', real)
          return home if Dir.exist?(File.join(home, 'bin'))
        end

        homes = Dir.glob('/usr/lib/jvm/*/bin/java').map { |p| File.expand_path('../..', p) }
        homes.select! { |h| Dir.exist?(h) }
        homes.max
      rescue StandardError
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
          # React Native: install JS deps if missing. Use the project's OWN
          # package manager (blindly running `npm install` on a yarn/pnpm project
          # corrupts the lockfile), keep output visible, and fail loud — a silent
          # install failure otherwise surfaces as a cryptic Gradle autolink error.
          dir = @project_info[:directory]
          unless File.exist?(File.join(dir, 'node_modules'))
            require 'mysigner/build/detector'
            cmd = Detector.install_command(Detector.detect_package_manager(dir))
            puts "📦 Installing JavaScript dependencies (#{cmd})..."
            ok = Dir.chdir(dir) { system(*cmd.split) }
            raise BuildError, "`#{cmd}` failed — install dependencies manually, then re-run." unless ok
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

        # M3: pass the signing secrets to the build via an env hash on the
        # spawn (execute_with_output → IO.popen(env, …)) rather than an
        # `export VAR=… &&` shell string, which would expose the keystore/key
        # passwords on the process table (ps, /proc/<pid>/cmdline) for the
        # build's lifetime. The Gradle init script reads them from ENV either
        # way; argv-form already kept them off the -P flags.
        @signing_env = {}
        if @keystore_path && File.exist?(@keystore_path) && @signing_init_script_path
          @signing_env['MYSIGNER_STORE_FILE'] = File.absolute_path(@keystore_path)
          @signing_env['MYSIGNER_STORE_PASSWORD'] = @keystore_password if @keystore_password
          @signing_env['MYSIGNER_KEY_ALIAS'] = @key_alias if @key_alias
          @signing_env['MYSIGNER_KEY_PASSWORD'] = @key_password if @key_password
        end
        # The versionCode override also flows to the init script via ENV.
        @signing_env['MYSIGNER_VERSION_CODE'] = @version_code.to_s if @version_code && @signing_init_script_path

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

        # Belt-and-suspenders: also pass -PversionCode for any build.gradle that
        # opts into reading it. The init-script injection above is what makes it
        # reliable for stock projects.
        cmd_parts << "-PversionCode=#{@version_code}" if @version_code

        # Standard build options. NOTE: do NOT add -q — quiet level suppresses the
        # `> Task …` / `BUILD …` lifecycle lines that execute_with_output parses
        # for progress, and hides the FAILURE block on errors.
        cmd_parts << '--no-daemon' # Avoid daemon issues in CI

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

        # Run command and capture output in real-time. The signing secrets ride
        # in the env hash (M3), never the command string / process table.
        IO.popen(@signing_env || {}, "#{cmd} 2>&1", 'r') do |io|
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

        newest_matching(patterns)
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

        newest_matching(patterns)
      end

      # Pick the freshest artifact across all candidate globs. Prefer files
      # produced by THIS build (mtime at/after build start, minus a small skew)
      # so a leftover artifact from a previous or wrong-flavor build is never
      # returned; fall back to the newest overall if none look fresh.
      def newest_matching(patterns)
        candidates = patterns.flat_map { |p| Dir.glob(p) }.uniq.select { |f| File.file?(f) }
        return nil if candidates.empty?

        fresh = if @build_started_at
                  candidates.select { |f| File.mtime(f) >= @build_started_at - 2 }
                else
                  candidates
                end
        pool = fresh.empty? ? candidates : fresh
        pool.max_by { |f| File.mtime(f) }
      end

      # Build the Gradle task suffix from a variant. Only the first character is
      # upcased — String#capitalize would downcase the rest and break camelCase
      # flavored variants (e.g. "demoRelease" -> "Demorelease").
      def variant_suffix(variant)
        v = variant.to_s
        return v if v.empty?

        v[0].upcase + v[1..]
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
