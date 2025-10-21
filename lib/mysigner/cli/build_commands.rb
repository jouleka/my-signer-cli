require 'json'
require 'yaml'

module Mysigner
  class CLI < Thor
    module BuildCommands
      MetadataFileError = Class.new(StandardError)

      def self.included(base)
        base.class_eval do
          desc "ship TARGET", "Build, export, and upload (testflight or appstore)"
          long_desc <<~DESC
            Build your project, export an IPA, and upload in one go.

            TARGETS
              testflight : Upload a beta build to TestFlight
              appstore   : Upload a production build to App Store Connect

            COMMON OPTIONS
              --wait                 Wait for Apple to finish processing the upload
              --team TEAM_ID         Override the detected development team
              --bundle-id ID         Override the bundle identifier pulled from the project

            APP STORE EXTRAS
              --submit-for-review    Kick off the post-upload submission helper
              --no-wait              Skip waiting for Apple build processing (automation only)
              --release-notes TEXT   Override “What’s New” directly from the CLI
              --metadata-file PATH   Merge JSON/YAML metadata into the dashboard configuration
              --no-auto-submit       Run automation but skip the final submission step
              --asc-poll-seconds N   Override polling interval while waiting for Apple
              --asc-timeout-seconds N  Override maximum wait time for Apple processing

            EXAMPLES
              mysigner ship testflight
              mysigner ship appstore --submit-for-review
              mysigner ship appstore --release-notes "Bug fixes" --metadata-file ./metadata.json
          DESC
          method_option :configuration, aliases: '-c', default: 'Release', desc: 'Build configuration'
          method_option :scheme, aliases: '-s', desc: 'Scheme to build (auto-detect if not specified)'
          method_option :wait, type: :boolean, default: false, desc: 'Wait for processing to complete'
          method_option :team, desc: 'Development team ID (overrides project setting)'
          method_option :bundle_id, aliases: '-b', desc: 'Bundle ID (overrides project setting)'
          method_option :submit_for_review, type: :boolean, default: false, desc: 'Submit for App Store review (appstore only)'
          method_option :release_notes, type: :string, desc: "Override 'What's New' text for App Store submission"
          method_option :metadata_file, type: :string, desc: 'Path to JSON or YAML file with App Store metadata overrides'
          method_option :asc_poll_seconds, type: :numeric, desc: 'Polling interval while waiting for App Store processing (seconds)'
          method_option :asc_timeout_seconds, type: :numeric, desc: 'Timeout while waiting for App Store processing (seconds)'
          method_option :no_auto_submit, type: :boolean, default: false, desc: 'Skip App Store submission even if auto-submit is enabled'
          def ship(target)
            unless ['testflight', 'appstore'].include?(target)
              error "Invalid target: #{target}"
              say "Valid targets: testflight, appstore", :yellow
              exit 1
            end
            
            is_appstore = (target == 'appstore')

            config = load_config
            client = create_client(config)
            
            overall_start = Time.now
            timings = {}
            archive_path = nil
            ipa_path = nil
            project_name = nil
            bundle_id = nil

            target_label = is_appstore ? "App Store" : "TestFlight"
            say "🚀 My Signer - Ship to #{target_label}", :cyan
            say "=" * 80, :cyan
            say ""
            say "This will:", :bold
            say "  1️⃣  Detect and build your project"
            say "  2️⃣  Export IPA for App Store"
            say "  3️⃣  Upload to #{target_label}"
            if is_appstore && options[:submit_for_review]
              say "  4️⃣  Submit for App Store review"
            end
            say ""
            say "⏱️  Estimated time: 3-7 minutes", :yellow
            say ""

            begin
              metadata_overrides = {}
              override_sources = []

              if is_appstore
                metadata_overrides, override_sources = build_metadata_overrides(options)

                override_sources.each do |source|
                  case source[:type]
                  when :file
                    keys = source[:keys]&.any? ? " (#{source[:keys].join(', ')})" : ''
                    say "🧾 Loaded metadata overrides from #{source[:path]}#{keys}", :cyan
                  when :inline
                    say "📝 Using release notes override from CLI flag", :cyan
                  end
                end

                say '' if override_sources.any?
              end

              # STEP 1: BUILD
              say "=" * 80, :cyan
              say "[1/3] Building Archive", :cyan
              say "=" * 80, :cyan
              say ""

              build_start = Time.now
              
              # Detect project
              project_info = Build::Detector.detect
              project_name = File.basename(project_info[:path], '.*')
              
              framework_label = case project_info[:framework]
              when :capacitor then "Capacitor/Ionic"
              when :react_native then "React Native"
              when :flutter then "Flutter"
              else "Native iOS"
              end
              
              say "✓ Found: #{File.basename(project_info[:path])} (#{framework_label})", :green
              say ""

              # Parse and build
              parser = Build::Parser.new(project_info)
              target_name = options[:target] || parser.main_target.name
              bundle_id = options[:bundle_id] || parser.bundle_id(target_name, options[:configuration])
              
              # Validate bundle ID format if overridden
              if options[:bundle_id]
                if bundle_id =~ /\$\(|\$\{/
                  error "Bundle ID cannot contain variables: #{bundle_id}"
                  exit 1
                elsif bundle_id !~ /^[a-zA-Z0-9.-]+$/
                  error "Invalid bundle ID format: #{bundle_id}"
                  say "Bundle IDs must contain only letters, numbers, hyphens, and periods", :yellow
                  exit 1
                end
              end
              
              say "🎯 Target: #{target_name}", :cyan
              say "📦 Bundle ID: #{bundle_id}#{options[:bundle_id] ? ' (overridden)' : ''}", :cyan
              say "⏱️  Estimated: 2-5 minutes", :yellow
              say ""
              
              # Auto-fetch team ID from API if not provided and project missing it
              team_id_to_use = options[:team]
              project_team_id = parser.team_id(target_name, options[:configuration])
              
              if !team_id_to_use && (project_team_id.nil? || project_team_id.empty?)
                say "🔍 No team set in project, fetching from My Signer...", :yellow
                
                begin
                  org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                  api_team_id = org_response.dig(:data, 'app_store_connect_team_id') || org_response['app_store_connect_team_id']
                  
                  if api_team_id && !api_team_id.empty?
                    team_id_to_use = api_team_id
                    say "✓ Using team from My Signer: #{api_team_id}", :green
                  else
                    say "⚠️  No team ID configured in My Signer", :yellow
                  end
                rescue => e
                  say "⚠️  Failed to fetch team from API: #{e.message}", :yellow
                end
              end
              say ""
              
              # Pre-build validation
              say "🔍 Validating signing setup...", :cyan
              validator = Signing::Validator.new(parser, target_name, options[:configuration], team_id: team_id_to_use)
              validator.validate!
              
              executor = Build::Executor.new(project_info, parser)
              archive_path = executor.build!(
                target_name, 
                options[:configuration], 
                scheme: options[:scheme],
                signing_style: parser.code_sign_style(target_name, options[:configuration]),
                team_id: team_id_to_use
              )

              timings[:build] = Time.now - build_start
              
              say ""
              say "✓ Build complete in #{format_duration(timings[:build])}", :green
              say ""

              # STEP 2: EXPORT
              say "=" * 80, :cyan
              say "[2/3] Exporting IPA", :cyan
              say "=" * 80, :cyan
              say ""
              say "⏱️  Estimated: 30-90 seconds", :yellow
              say ""

              export_start = Time.now
              
              exporter = Export::Exporter.new(archive_path)
              ipa_path = exporter.export!(
                method: :appstore,
                team_id: nil,
                signing_style: 'automatic'
              )

              timings[:export] = Time.now - export_start
              
              say ""
              say "✓ Export complete in #{format_duration(timings[:export])}", :green
              say "📦 IPA: #{ipa_path}", :cyan
              say ""

              # STEP 3: UPLOAD
              say "=" * 80, :cyan
              say "[3/#{is_appstore && options[:submit_for_review] ? '4' : '3'}] Uploading to #{target_label}", :cyan
              say "=" * 80, :cyan
              say ""
              say "⏱️  Estimated: 1-3 minutes", :yellow
              say ""
              
              upload_start = Time.now

              # Fetch App Store Connect credentials
              say "🔐 Fetching App Store Connect credentials...", :yellow
              
              org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
              org_data = org_response[:data]
              
              unless org_data['app_store_connect_configured']
                say ""
                say "✗ Error: App Store Connect credentials not configured", :red
                say ""
                say "Please configure your API key in the web dashboard first.", :yellow
                exit 1
              end
              
              api_key = org_data['app_store_connect_key_id']
              api_issuer = org_data['app_store_connect_issuer_id']
              private_key = org_data['app_store_connect_private_key']
              
              unless api_key && api_issuer && private_key
                say "✗ Error: Invalid credentials received from API", :red
                exit 1
              end
              
              say "✓ Credentials loaded", :green
              say ""

              # Upload
              uploader = Upload::Uploader.new(
                ipa_path,
                api_key: api_key,
                api_issuer: api_issuer,
                private_key: private_key
              )
              
              uploader.upload!(wait_for_processing: options[:wait])
              
              timings[:upload] = Time.now - upload_start
              
              # STEP 4 (Optional): Submit for App Store Review
              if is_appstore && options[:submit_for_review]
                say ""
                say "=" * 80, :cyan
                say "[4/4] Submitting for App Store Review", :cyan
                say "=" * 80, :cyan
                say ""
                
                submission_start = Time.now
                
                require_relative '../upload/app_store_submission'
                automation = Upload::AppStoreAutomation.new(
                  client: client,
                  organization_id: config.current_organization_id,
                  opts: {
                    wait: options[:wait],
                    timeout: options[:asc_timeout_seconds],
                    poll_interval: options[:asc_poll_seconds],
                    no_submit: options[:no_auto_submit]
                  }
                )

                submission = Upload::AppStoreSubmission.new(
                  client,
                  config.current_organization_id,
                  {
                    bundle_id: bundle_id,
                    version: parser.build_settings(target_name, options[:configuration])['MARKETING_VERSION'],
                    build_number: parser.build_settings(target_name, options[:configuration])['CURRENT_PROJECT_VERSION']
                  },
                  metadata_overrides: metadata_overrides,
                  override_sources: override_sources
                )
                
                submission_result = submission.submit_for_review!(automation: automation)
                report_automation_outcome(submission_result[:automation], override_sources)
                timings[:submission] = Time.now - submission_start
              end
              
              timings[:total] = Time.now - overall_start

              # SUCCESS SUMMARY!
              say ""
              say "=" * 80, :green
              if is_appstore
                say "🎉 SUCCESS! Your app is uploaded to App Store Connect!", :green
              else
                say "🎉 SUCCESS! Your app is on TestFlight!", :green
              end
              say "=" * 80, :green
              say ""
              
              # Summary table
              say "📊 Summary", :bold
              say ""
              say "  Project:     #{project_name}"
              say "  Bundle ID:   #{bundle_id}"
              say "  Target:      #{target_name}"
              say "  IPA Size:    #{format_bytes(File.size(ipa_path))}"
              say ""
              if is_appstore && options[:submit_for_review]
                poll_msg = options[:wait] ? "every #{automation.poll_interval}s" : 'skipped (--no-wait)'
                say "  ASC Polling: #{poll_msg}"
                say "  ASC Timeout: #{format_duration(options[:asc_timeout_seconds])}" if options[:asc_timeout_seconds]
              end
              
              # Timing breakdown
              say "⏱️  Time Breakdown", :bold
              say ""
              say "  Build:       #{format_duration(timings[:build])}"
              say "  Export:      #{format_duration(timings[:export])}"
              say "  Upload:      #{format_duration(timings[:upload])}"
              say "  " + "-" * 30
              say "  Total:       #{format_duration(timings[:total])}", :bold
              say ""
              
              # Files created
              say "📁 Files Created", :bold
              say ""
              say "  Archive:     #{archive_path}"
              say "  IPA:         #{ipa_path}"
              say ""
              
              # Next steps
              say "🔮 Next Steps", :bold
              say ""
              say "  1. Wait 5-15 minutes for Apple to process your build"
              say "  2. Open App Store Connect:"
              say "     https://appstoreconnect.apple.com/apps"
              if is_appstore
                if options[:submit_for_review]
                  say "  3. Your build is submitted for review!"
                  say "  4. Monitor review status in App Store Connect"
                else
                  say "  3. Select this build for a new version"
                  say "  4. Fill in required metadata (screenshots, description)"
                  say "  5. Submit for App Store review"
                end
              else
                say "  3. Add testers and distribute via TestFlight"
              end
              say ""
            rescue MetadataFileError => e
              say ""
              say "=" * 80, :red
              say "✗ Ship Failed", :red
              say "=" * 80, :red
              say ""
              say "Error: #{e.message}", :red
              say ""
              exit 1
            rescue => e
              say ""
              say "=" * 80, :red
              say "✗ Ship Failed", :red
              say "=" * 80, :red
              say ""
              say "Error: #{e.message}", :red
              say ""
              
              if archive_path && File.exist?(archive_path)
                say "Archive saved at: #{archive_path}", :yellow
              end
              if ipa_path && File.exist?(ipa_path)
                say "IPA saved at: #{ipa_path}", :yellow
              end
              
              exit 1
            end
          end

          no_commands do
            def build_metadata_overrides(opts)
              overrides = {}
              sources = []

              if opts[:metadata_file]
                file_overrides = load_metadata_file(opts[:metadata_file])
              overrides = deep_merge_hashes(overrides, file_overrides)
                sources << {
                  type: :file,
                  path: File.expand_path(opts[:metadata_file]),
                  keys: flatten_metadata_keys(file_overrides)
                }
              end

              if opts[:release_notes]
                overrides = deep_merge_hashes(overrides, { 'whats_new' => opts[:release_notes] })
                sources << {
                  type: :inline,
                  keys: ['whats_new']
                }
              end

              [overrides, sources]
            end

            def load_metadata_file(path)
              expanded = File.expand_path(path)

              unless File.exist?(expanded) && File.file?(expanded)
                raise MetadataFileError, "Metadata file not found: #{expanded}"
              end

              content = File.read(expanded)
              parsed = parse_metadata_content(content, expanded)

              unless parsed.is_a?(Hash)
                raise MetadataFileError, 'Metadata file must contain a JSON/YAML object at the top level'
              end

              stringify_keys(parsed)
            rescue Errno::EACCES => e
              raise MetadataFileError, "Cannot read metadata file #{expanded}: #{e.message}"
            end

            def parse_metadata_content(content, path)
              stripped = content.lstrip

              begin
                if stripped.start_with?('---') || stripped.start_with?('- ')
                  return YAML.safe_load(content, aliases: true) || {}
                end

                return JSON.parse(content)
              rescue JSON::ParserError
                begin
                  YAML.safe_load(content, aliases: true) || {}
                rescue Psych::Exception => e
                  raise MetadataFileError, "Failed to parse metadata file #{path}: #{e.message}"
                end
              rescue Psych::Exception => e
                raise MetadataFileError, "Failed to parse metadata file #{path}: #{e.message}"
              end
            end

            def deep_merge_hashes(base, overrides)
              base = stringify_keys(base || {})
              overrides = stringify_keys(overrides || {})

              merged = base.dup
              overrides.each do |key, value|
                merged[key] = if merged[key].is_a?(Hash) && value.is_a?(Hash)
                  deep_merge_hashes(merged[key], value)
                else
                  value
                end
              end
              merged
            end

            def flatten_metadata_keys(hash, prefix = nil, acc = [])
              hash.each do |key, value|
                current = prefix ? "#{prefix}.#{key}" : key
                if value.is_a?(Hash)
                  flatten_metadata_keys(value, current, acc)
                else
                  acc << current
                end
              end
              acc
            end

            def stringify_keys(object)
              case object
              when Hash
                object.each_with_object({}) do |(k, v), memo|
                  memo[k.to_s] = stringify_keys(v)
                end
              when Array
                object.map { |item| stringify_keys(item) }
              else
                object
              end
            end

            def report_automation_outcome(result, override_sources)
              return unless result.is_a?(Hash)

              wait = result[:wait] || {}
              if wait[:enabled]
                timeout_seconds = wait[:timeout_seconds] || Upload::AppStoreAutomation::DEFAULT_WAIT_TIMEOUT
                timeout_str = format_duration(timeout_seconds)
                say "   ASC Polling: every #{wait[:poll_seconds]}s (timeout #{timeout_str})"
                if wait[:timed_out]
                  say "   ⚠️  Build still processing after #{format_duration(wait[:elapsed_seconds])}", :yellow
                elsif wait[:elapsed_seconds].to_i.positive?
                  say "   ASC Polling: completed in #{format_duration(wait[:elapsed_seconds])}"
                end
              else
                say "   ASC Polling: skipped (--no-wait)", :yellow
              end

              if result[:submitted]
                say "   Submission: sent via #{result[:submission_source]}", :green
              elsif result[:skip_reason]
                say "   Submission: skipped (#{result[:skip_reason]})", :yellow
              end

              override_sources.each do |source|
                keys = Array(source[:keys]).join(', ')
                case source[:type]
                when :inline
                  say "   Overrides: CLI flag#{keys.empty? ? '' : " (#{keys})"}"
                when :file
                  say "   Overrides: #{File.basename(source[:path])}#{keys.empty? ? '' : " (#{keys})"}"
                end
              end
            end
          end

          desc "build", "Build iOS archive from current project"
          method_option :configuration, aliases: '-c', default: 'Release', desc: 'Build configuration (Debug, Release, etc.)'
          method_option :target, aliases: '-t', desc: 'Target to build (auto-detect if not specified)'
          method_option :scheme, aliases: '-s', desc: 'Scheme to build (defaults to target name)'
          method_option :type, default: 'appstore', desc: 'Build type: development, adhoc, appstore, enterprise'
          method_option :team, desc: 'Development team ID (overrides project setting)'
          method_option :bundle_id, aliases: '-b', desc: 'Bundle ID (overrides project setting)'
          def build
            config = load_config
            client = create_client(config)

            say "🔍 Detecting project...", :cyan
            say ""

            begin
              # Detect project
              project_info = Build::Detector.detect
              
              framework_label = case project_info[:framework]
              when :capacitor then "Capacitor/Ionic"
              when :react_native then "React Native"
              when :flutter then "Flutter"
              else "Native iOS"
              end
              
              say "✓ Found: #{File.basename(project_info[:path])} (#{framework_label})", :green
              say ""

              # Parse project
              parser = Build::Parser.new(project_info)
              
              # Check if this is a buildable app (not framework/library)
              main_product_type = parser.product_type
              unless [:app, :unknown].include?(main_product_type)
                error "Cannot build #{main_product_type} projects for TestFlight"
                say ""
                say "My Signer builds iOS/macOS/tvOS apps for distribution.", :yellow
                say "This project builds a #{main_product_type}, not an app.", :yellow
                say ""
                exit 1
              end
              
              # Check for multiple apps and prompt user if needed
              if parser.has_multiple_apps? && !options[:target]
                app_targets = parser.app_targets
                say "Multiple apps found in project:", :yellow
                app_targets.each_with_index do |target, i|
                  say "  #{i + 1}. #{target.name}", :cyan
                end
                say ""
                
                choice = ask("Select app to build (1-#{app_targets.count}):", limited_to: (1..app_targets.count).map(&:to_s))
                target_name = app_targets[choice.to_i - 1].name
              else
                target_name = options[:target] || parser.main_target.name
              end
              
              say "🎯 Target: #{target_name}", :cyan
              
              # Show platform if not iOS
              platform = parser.target_platform(target_name)
              unless platform == :ios
                platform_label = platform.to_s.upcase
                say "📱 Platform: #{platform_label}", :cyan
              end
              
              # Show extensions if any
              if parser.has_extensions?
                ext_count = parser.extension_targets.count
                say "🧩 Extensions: #{ext_count} (will be included in build)", :cyan
              end
              
              bundle_id = options[:bundle_id] || parser.bundle_id(target_name, options[:configuration])
              
              # Validate bundle ID format if overridden
              if options[:bundle_id]
                if bundle_id =~ /\$\(|\$\{/
                  error "Bundle ID cannot contain variables: #{bundle_id}"
                  exit 1
                elsif bundle_id !~ /^[a-zA-Z0-9.-]+$/
                  error "Invalid bundle ID format: #{bundle_id}"
                  say "Bundle IDs must contain only letters, numbers, hyphens, and periods", :yellow
                  exit 1
                end
              end
              
              say "📦 Bundle ID: #{bundle_id}#{options[:bundle_id] ? ' (overridden)' : ''}", :cyan
              say "⚙️  Configuration: #{options[:configuration]}", :cyan
              
              # Check signing style
              sign_style = parser.code_sign_style(target_name, options[:configuration])
              say "🔐 Signing: #{sign_style || 'Not Set'}", :cyan
              
              # Auto-fetch team ID from API if not provided and project missing it
              team_id_to_use = options[:team]
              project_team_id = parser.team_id(target_name, options[:configuration])
              
              if !team_id_to_use && (project_team_id.nil? || project_team_id.empty?)
                say "🔍 No team set in project, fetching from My Signer...", :yellow
                
                begin
                  org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                  api_team_id = org_response.dig(:data, 'app_store_connect_team_id') || org_response['app_store_connect_team_id']
                  
                  if api_team_id && !api_team_id.empty?
                    team_id_to_use = api_team_id
                    say "✓ Using team from My Signer: #{api_team_id}", :green
                  else
                    say "⚠️  No team ID configured in My Signer", :yellow
                  end
                rescue => e
                  say "⚠️  Failed to fetch team from API: #{e.message}", :yellow
                end
              end
              
              say ""

              # Handle signing based on style
              if sign_style == 'Automatic'
                say "ℹ️  Using Automatic signing (Xcode will manage profiles)", :yellow
                say ""
              elsif sign_style == 'Manual'
                # Check if manual signing is already configured
                if parser.signing_configured?(target_name, options[:configuration])
                  say "ℹ️  Manual signing already configured, using existing settings", :yellow
                  say ""
                else
                  say "⚠️  Manual signing enabled but not configured", :yellow
                  say "🔐 Configuring manual signing via My Signer API...", :cyan
                  
                  configurator = Build::Configurator.new(parser, client, config.current_organization_id)
                  build_type = options[:type].to_sym
                  
                  profile = configurator.configure!(target_name, options[:configuration], build_type: build_type)
                  
                  say "✓ Configured with profile: #{profile['name']}", :green
                  say ""
                end
              else
                # No signing style set, default to automatic signing for simplicity
                say "ℹ️  No signing style set, defaulting to Automatic signing", :yellow
                say "ℹ️  Xcode will manage profiles automatically", :yellow
                say ""
                say "💡 To use Manual signing instead, run: mysigner signing configure", :cyan
                say ""
              end

              # Pre-build validation
              say "🔍 Validating signing setup...", :cyan
              validator = Signing::Validator.new(parser, target_name, options[:configuration], team_id: team_id_to_use)
              validator.validate!

              # Build
              executor = Build::Executor.new(project_info, parser)
              archive_path = executor.build!(
                target_name, 
                options[:configuration], 
                scheme: options[:scheme],
                signing_style: sign_style,
                team_id: team_id_to_use,
                bundle_id: options[:bundle_id]
              )

              say ""
              say "=" * 80, :green
              say "✓ Build succeeded!", :green
              say "=" * 80, :green
              say ""
              say "📦 Archive: #{archive_path}", :cyan
              say ""
              say "Next steps:", :bold
              say "  mysigner export #{archive_path}"
              say "  mysigner ship testflight"
              say ""

            rescue Build::Detector::NoProjectError => e
              error e.message
              say ""
              say "Supported project types:", :yellow
              say "  - Native iOS (.xcodeproj, .xcworkspace)"
              say "  - Capacitor/Ionic (ionic project with ios/ folder)"
              say "  - React Native (RN project with ios/ folder)"
              say "  - Flutter (flutter project with ios/ folder)"
              exit 1
            rescue Build::Configurator::ProfileNotFoundError => e
              error e.message
              say ""
              say "Try:", :yellow
              say "  mysigner profiles                    # List available profiles"
              say "  mysigner profile create              # Create a new profile"
              exit 1
            rescue Build::Executor::BuildError => e
              error e.message
              exit 1
            rescue => e
              error "Build failed: #{e.message}"
              say ""
              say "Full error:", :yellow
              say e.full_message
              exit 1
            end
          end

          desc "export ARCHIVE_PATH", "Export .xcarchive to .ipa file"
          method_option :method, type: :string, default: 'appstore', desc: 'Export method (appstore, adhoc, enterprise, development)'
          method_option :output, type: :string, desc: 'Output directory for .ipa file'
          def export(archive_path)
            config = load_config
            
            begin
              say "📦 My Signer - Export", :cyan
              say "=" * 80, :cyan
              say ""
              
              # Validate archive path
              unless File.exist?(archive_path)
                say "✗ Error: Archive not found: #{archive_path}", :red
                exit 1
              end
              
              # Create exporter
              exporter = Export::Exporter.new(
                archive_path,
                output_dir: options[:output]
              )
              
              # Export
              method = options[:method].to_sym
              ipa_path = exporter.export!(
                method: method,
                team_id: nil,
                signing_style: 'automatic'
              )
              
              say ""
              say "=" * 80, :green
              say "✓ Export succeeded!", :green
              say "=" * 80, :green
              say ""
              say "📦 IPA: #{ipa_path}", :green
              say ""
              say "Next steps:", :cyan
              say "  mysigner upload testflight #{ipa_path}", :cyan
              say "  mysigner ship testflight", :cyan
              say ""
              
            rescue Export::Exporter::ExportError => e
              say ""
              say "✗ Error: #{e.message}", :red
              exit 1
            rescue StandardError => e
              say ""
              say "✗ Unexpected error: #{e.message}", :red
              say e.backtrace.first(5).join("\n"), :red if ENV['DEBUG']
              exit 1
            end
          end

          desc "upload testflight IPA_PATH", "Upload IPA to TestFlight"
          method_option :wait, type: :boolean, default: false, desc: 'Wait for processing to complete'
          def upload(target, ipa_path)
            unless target == 'testflight'
              error "Only 'testflight' target is supported currently"
              say "Usage: mysigner upload testflight IPA_PATH", :yellow
              exit 1
            end

            config = load_config
            client = create_client(config)
            
            begin
              say "☁️  My Signer - Upload to TestFlight", :cyan
              say "=" * 80, :cyan
              say ""
              
              # Validate IPA path
              unless File.exist?(ipa_path)
                say "✗ Error: IPA file not found: #{ipa_path}", :red
                exit 1
              end
              
              # Fetch App Store Connect credentials from API
              say "🔐 Fetching App Store Connect credentials...", :yellow
              
              begin
                org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                org_data = org_response[:data]
                
                # Check if credentials are configured
                unless org_data['app_store_connect_configured']
                  say ""
                  say "✗ Error: App Store Connect credentials not configured", :red
                  say ""
                  say "Please configure your App Store Connect API key in the web dashboard:", :yellow
                  say "  1. Go to your organization settings"
                  say "  2. Add your API Key ID, Issuer ID, and .p8 file"
                  say "  3. Run sync to verify credentials"
                  say ""
                  exit 1
                end
                
                # Get credentials (API will return the decrypted values)
                api_key = org_data['app_store_connect_key_id']
                api_issuer = org_data['app_store_connect_issuer_id']
                private_key = org_data['app_store_connect_private_key']
                
                unless api_key && api_issuer && private_key
                  say "✗ Error: Invalid credentials received from API", :red
                  exit 1
                end
                
                say "✓ Credentials loaded", :green
                say ""
              rescue Mysigner::ClientError => e
                say ""
                say "✗ Error fetching credentials: #{e.message}", :red
                exit 1
              end
              
              # Create uploader
              uploader = Upload::Uploader.new(
                ipa_path,
                api_key: api_key,
                api_issuer: api_issuer,
                private_key: private_key
              )
              
              # Upload
              result = uploader.upload!(wait_for_processing: options[:wait])
              
              say "🎉 Upload complete!", :green
              say ""
              say "Next steps:", :cyan
              say "  • Open App Store Connect to see your build"
              say "  • Wait for processing (5-15 minutes)"
              say "  • Distribute to TestFlight testers"
              say ""
              
            rescue Upload::Uploader::TransporterNotFoundError => e
              say ""
              say "✗ Error: #{e.message}", :red
              exit 1
            rescue Upload::Uploader::UploadError => e
              say ""
              say "✗ Upload Error: #{e.message}", :red
              exit 1
            rescue StandardError => e
              say ""
              say "✗ Unexpected error: #{e.message}", :red
              say e.backtrace.first(5).join("\n"), :red if ENV['DEBUG']
              exit 1
            end
          end
          
          desc "signing configure", "Interactive wizard to configure manual signing"
          long_desc <<~DESC
            Guides you through setting up manual code signing for your project:
            
            1. Detects your project and targets
            2. Shows current signing configuration
            3. Helps you select team ID and provisioning profile
            4. Applies configuration to your Xcode project
            5. Validates the setup
            
            This is useful when automatic signing doesn't work or you need specific profiles.
            
            OPTIONS:
              --target NAME       Configure specific target only
              --all-targets       Configure all app and extension targets
            
            EXAMPLES:
              mysigner signing configure                    # Configure main app (auto-detect)
              mysigner signing configure --target MyWidget  # Configure specific target
              mysigner signing configure --all-targets      # Configure all targets
          DESC
          method_option :target, aliases: '-t', desc: 'Target name to configure'
          method_option :all_targets, type: :boolean, default: false, desc: 'Configure all targets'
          def signing(action)
            unless action == 'configure'
              error "Unknown action: #{action}"
              say "Usage: mysigner signing configure", :yellow
              exit 1
            end
            
            config = load_config
            
            unless config.api_token
              error "Not logged in. Please run 'mysigner login' or 'mysigner onboard' first."
              exit 1
            end
            
            client = create_client(config)
            
            begin
              # Detect project
              project_info = Build::Detector.detect
              parser = Build::Parser.new(project_info)
              
              # Validate options
              if options[:target] && options[:all_targets]
                error "Cannot use both --target and --all-targets"
                exit 1
              end
              
              # Check current signing style
              target_name = options[:target] || parser.main_target.name
              signing_style = parser.code_sign_style(target_name)
              
              if signing_style == 'Automatic'
                say "⚠️  Project uses Automatic signing", :yellow
                say ""
                say "Your project is configured for Automatic signing, which means:", :cyan
                say "  • Xcode manages profiles automatically"
                say "  • No manual profile configuration needed"
                say "  • Team ID is all you need"
                say ""
                say "Current Team ID: #{parser.team_id(target_name) || '(not set)'}", :green
                say ""
                say "You can build with: mysigner build"
                say ""
                say "💡 To convert to Manual signing, use: mysigner signing configure --force-manual"
                return
              end
              
              # Run wizard for Manual signing
              require_relative '../signing/wizard'
              wizard_options = {
                target: options[:target],
                all_targets: options[:all_targets]
              }
              wizard = Signing::Wizard.new(parser, client, config.current_organization_id, wizard_options)
              wizard.run!
              
            rescue Build::Detector::NoProjectError => e
              error e.message
              exit 1
            rescue Signing::Wizard::WizardError => e
              error "Wizard failed: #{e.message}"
              exit 1
            rescue StandardError => e
              error "Unexpected error: #{e.message}"
              say e.backtrace.first(5).join("\n"), :red if ENV['DEBUG']
              exit 1
            end
          end
        end
      end
    end
  end
end
