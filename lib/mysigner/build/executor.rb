# frozen_string_literal: true

require 'English'
module Mysigner
  module Build
    class Executor
      class BuildError < StandardError; end

      attr_reader :build_errors

      def initialize(project_info, parser)
        @project_info = project_info
        @parser = parser
        @build_errors = []
      end

      # Build archive
      # Returns: path to .xcarchive
      # Options:
      #   - signing_style: 'Automatic', 'Manual', or nil (default: use project setting)
      #   - team_id: Development team ID to override project setting
      #   - bundle_id: Bundle ID to override project setting
      #   - skip_extensions: If true, disable code signing for extension targets
      def build!(target_name = nil, configuration = 'Release', scheme: nil, signing_style: nil, team_id: nil,
                 bundle_id: nil, skip_extensions: false)
        target = target_name || @parser.main_target.name
        scheme_name = scheme || target
        @signing_style = signing_style
        @team_id = team_id
        @bundle_id = bundle_id
        @skip_extensions = skip_extensions

        # Use Xcode's default DerivedData location to keep project clean
        # This matches Xcode's behavior and avoids polluting the project directory
        output_dir = File.join(@project_info[:directory], 'build')
        FileUtils.mkdir_p(output_dir)

        # Generate archive path with timestamp
        timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
        archive_name = "#{target}-#{timestamp}.xcarchive"
        archive_path = File.join(output_dir, archive_name)

        # Build command
        cmd = build_command(scheme_name, configuration, archive_path)

        # Execute build
        success = execute_with_output(cmd)

        unless success
          msg = +'Build failed.'
          msg << " Full log: #{@last_build_log}" if @last_build_log
          raise BuildError, msg
        end

        # Verify archive was created
        raise BuildError, "Build reported success but archive not found at: #{archive_path}" unless File.exist?(archive_path)

        archive_path
      end

      private

      def build_command(scheme, configuration, archive_path)
        cmd = %w[xcodebuild archive]

        # Workspace or project
        cmd += if @project_info[:type] == :workspace
                 ['-workspace', @project_info[:path]]
               else
                 ['-project', @project_info[:path]]
               end

        # Scheme and configuration
        cmd += [
          '-scheme', scheme,
          '-configuration', configuration,
          '-archivePath', archive_path
        ]

        # SDK selection based on platform
        platform = @parser.target_platform(scheme)
        sdk = case platform
              when :macos
                'macosx'
              when :tvos
                'appletvos'
              when :watchos
                'watchos'
              else
                'iphoneos' # default to iOS
              end
        cmd += ['-sdk', sdk]

        # Override team ID if provided
        cmd += ["DEVELOPMENT_TEAM=#{@team_id}"] if @team_id

        # Override bundle ID if provided
        cmd += ["PRODUCT_BUNDLE_IDENTIFIER=#{@bundle_id}"] if @bundle_id

        # Handle signing based on style
        case @signing_style
        when 'Automatic'
          # For automatic signing, allow Xcode to manage profiles
          cmd += ['-allowProvisioningUpdates']
        when 'Manual'
          # For manual signing, don't override - project already configured
          # No additional flags needed
        else
          # Default to automatic signing for simplicity
          cmd += ['-allowProvisioningUpdates']
        end

        # Skip extension signing if requested
        # This disables code signing for extension targets while keeping it enabled for the main app
        if @skip_extensions && @parser.has_extensions?
          @parser.extension_targets.each do |ext_target|
            ext_name = ext_target.name
            # Disable code signing for this extension target
            cmd += ["CODE_SIGNING_ALLOWED[target=#{ext_name}]=NO"]
          end
        end

        # Suppress verbose output
        cmd += [
          '-quiet'
        ]

        cmd.join(' ')
      end

      def execute_with_output(cmd)
        puts '🏗️  Running: xcodebuild archive...'
        puts ''

        @build_errors = []
        @last_build_log = log_path_for_run

        # Capture every line so we can replay it on failure. xcodebuild's
        # `-quiet` plus our keyword filter happily hides framework-loader
        # errors, license issues, and anything that doesn't say "error:" —
        # leaving the user with "Build failed" and nothing actionable. The
        # log file (and tail dump on failure) keeps the full output recoverable.
        File.open(@last_build_log, 'w') do |log|
          # Run command and capture output in real-time
          IO.popen(cmd, err: %i[child out]) do |io|
            io.each_line do |line|
              log.write(line)

              # Filter output to show only important messages
              next if line.strip.empty?

              # Detect error lines (case-insensitive for error:)
              # Check for various error patterns including curly quotes from Xcode
              is_error = line.downcase.include?('error:') ||
                         line.include?('Provisioning profile') ||
                         line.include?('Code Sign error') ||
                         line.include?("doesn't support") ||
                         line.include?("doesn\u2019t support") ||
                         line.include?('capability')

              is_warning = line.downcase.include?('warning:')

              # Show and capture errors and warnings
              if is_error || is_warning
                puts line
                @build_errors << line if is_error
              # Show progress markers
              elsif line.include?('Building') || line.include?('Compiling') ||
                    line.include?('Linking') || line.include?('Signing') ||
                    line.include?('Copying')
                print '.'
              end
            end
          end
        end

        puts '' # New line after dots

        success = $CHILD_STATUS.success?
        dump_log_tail(@last_build_log) unless success
        success
      end

      def log_path_for_run
        log_dir = File.join(@project_info[:directory], 'build')
        FileUtils.mkdir_p(log_dir)
        File.join(log_dir, 'last-build.log')
      end

      def dump_log_tail(path, lines: 80)
        return unless File.exist?(path)

        tail = File.foreach(path).each_with_object([]) do |line, buf|
          buf << line
          buf.shift if buf.size > lines
        end
        return if tail.empty?

        puts ''
        puts '─' * 80
        puts "Build output (last #{tail.size} lines):"
        puts '─' * 80
        puts tail.join
        puts '─' * 80
        puts "Full log: #{path}"
      end
    end
  end
end
