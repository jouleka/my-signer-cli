module Mysigner
  module Build
    class Executor
      class BuildError < StandardError; end

      def initialize(project_info, parser)
        @project_info = project_info
        @parser = parser
      end

      # Build archive
      # Returns: path to .xcarchive
      # Options:
      #   - signing_style: 'Automatic', 'Manual', or nil (default: use project setting)
      #   - team_id: Development team ID to override project setting
      #   - bundle_id: Bundle ID to override project setting
      def build!(target_name = nil, configuration = 'Release', scheme: nil, signing_style: nil, team_id: nil, bundle_id: nil)
        target = target_name || @parser.main_target.name
        scheme_name = scheme || target
        @signing_style = signing_style
        @team_id = team_id
        @bundle_id = bundle_id

        # Create build directory
        build_dir = File.join(@project_info[:directory], 'build')
        FileUtils.mkdir_p(build_dir) unless Dir.exist?(build_dir)

        # Generate archive path with timestamp
        timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
        archive_name = "#{target}-#{timestamp}.xcarchive"
        archive_path = File.join(build_dir, archive_name)

        # Build command
        cmd = build_command(scheme_name, configuration, archive_path)

        # Execute build
        success = execute_with_output(cmd)

        unless success
          raise BuildError, "Build failed. Check output above for errors."
        end

        # Verify archive was created
        unless File.exist?(archive_path)
          raise BuildError, "Build reported success but archive not found at: #{archive_path}"
        end

        archive_path
      end

      private

      def build_command(scheme, configuration, archive_path)
        cmd = ['xcodebuild', 'archive']

        # Workspace or project
        if @project_info[:type] == :workspace
          cmd += ['-workspace', @project_info[:path]]
        else
          cmd += ['-project', @project_info[:path]]
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
          'iphoneos'  # default to iOS
        end
        cmd += ['-sdk', sdk]

        # Override team ID if provided
        if @team_id
          cmd += ["DEVELOPMENT_TEAM=#{@team_id}"]
        end
        
        # Override bundle ID if provided
        if @bundle_id
          cmd += ["PRODUCT_BUNDLE_IDENTIFIER=#{@bundle_id}"]
        end

        # Handle signing based on style
        case @signing_style
        when 'Automatic'
          # For automatic signing, allow Xcode to manage profiles
          cmd += ['-allowProvisioningUpdates']
        when 'Manual'
          # For manual signing, don't override - project already configured
          # No additional flags needed
        else
          # Default: let xcodebuild use project settings
          # May need -allowProvisioningUpdates if project uses Automatic signing
        end

        # Suppress verbose output
        cmd += [
          '-quiet'
        ]

        cmd.join(' ')
      end

      def execute_with_output(cmd)
        puts "🏗️  Running: xcodebuild archive..."
        puts ""

        # Run command and capture output in real-time
        IO.popen(cmd, err: [:child, :out]) do |io|
          io.each_line do |line|
            # Filter output to show only important messages
            next if line.strip.empty?
            
            # Show errors and warnings
            if line.include?('error:') || line.include?('warning:')
              puts line
            # Show progress markers
            elsif line.include?('Building') || line.include?('Compiling') || 
                  line.include?('Linking') || line.include?('Signing') ||
                  line.include?('Copying')
              print '.'
            end
          end
        end

        puts "" # New line after dots

        $?.success?
      end
    end
  end
end

