# frozen_string_literal: true

require 'json'
require 'yaml'
require 'time'
require_relative '../upload/play_store_uploader'
require_relative '../upload/app_store_automation'
require_relative '../upload/app_store_submission'

module Mysigner
  class CLI < Thor
    module BuildCommands
      class MetadataFileError < StandardError
      end

      def self.included(base)
        base.class_eval do
          desc 'ship TARGET', '🚀 Build + upload (iOS: testflight/appstore, Android: internal/alpha/beta/production)'
          long_desc <<~DESC
            Build your project, sign it, and upload in one go.

            iOS TARGETS
              testflight : Upload a beta build to TestFlight
              appstore   : Upload a production build to App Store Connect

            ANDROID TARGETS
              internal   : Upload to internal testing track
              alpha      : Upload to alpha (closed testing) track
              beta       : Upload to beta (open testing) track
              production : Upload to production track

            PLATFORM OPTIONS
              --platform ios       Force iOS build (auto-detected by default)
              --platform android   Force Android build

            iOS OPTIONS
              --wait                 Wait for Apple to finish processing the upload
              --team TEAM_ID         Override the detected development team
              --bundle-id ID         Override the bundle identifier pulled from the project

            ANDROID OPTIONS
              --release-notes TEXT   Release notes for Play Store
              --package-name PKG     Override the detected package name

            WORKFLOW
              For iOS TestFlight:
                mysigner ship testflight              # Build → Upload → Done!
            #{'  '}
              For Android Internal Testing:
                mysigner ship internal --platform android  # Build → Upload → Done!

            EXAMPLES
              mysigner ship testflight                     # iOS to TestFlight
              mysigner ship appstore                       # iOS to App Store
              mysigner ship internal --platform android    # Android internal track
              mysigner ship beta --platform android        # Android beta track
              mysigner ship production --platform android  # Android production
          DESC
          method_option :configuration, aliases: '-c', default: 'Release', desc: 'Build configuration'
          method_option :scheme, aliases: '-s', desc: 'Scheme to build (auto-detect if not specified)'
          method_option :wait, type: :boolean, default: false, desc: 'Wait for processing to complete'
          method_option :team, desc: 'Development team ID (overrides project setting)'
          method_option :bundle_id, aliases: '-b', desc: 'Bundle ID (overrides project setting)'
          method_option :platform, type: :string, desc: 'Platform: ios or android (auto-detect if not specified)'
          method_option :package_name, type: :string, desc: 'Android package name (overrides project setting)'
          method_option :release_notes, type: :string, desc: 'Release notes for Android Play Store'
          method_option :version, type: :string, desc: 'Set version name for Android (e.g., 1.2.0)'
          method_option :release_type, type: :string, enum: %w[AFTER_APPROVAL MANUAL SCHEDULED],
                                       desc: 'Release type for App Store: AFTER_APPROVAL, MANUAL, or SCHEDULED'
          method_option :scheduled_date, type: :string, banner: 'ISO8601',
                                         desc: 'Scheduled release date (ISO 8601, e.g., 2026-02-01T10:00:00Z)'
          def ship(target)
            ios_targets = %w[testflight appstore]
            android_targets = %w[internal alpha beta production]

            # Determine platform from option or target
            platform = options[:platform]&.to_sym

            if platform.nil?
              # Auto-detect from target
              if ios_targets.include?(target)
                platform = :ios
              elsif android_targets.include?(target)
                platform = :android
              else
                error "Invalid target: #{target}"
                say "Valid iOS targets: #{ios_targets.join(', ')}", :yellow
                say "Valid Android targets: #{android_targets.join(', ')}", :yellow
                exit 1
              end
            end

            # Validate target matches platform
            if platform == :ios && !ios_targets.include?(target)
              error "Invalid iOS target: #{target}"
              say "Valid iOS targets: #{ios_targets.join(', ')}", :yellow
              exit 1
            elsif platform == :android && !android_targets.include?(target)
              error "Invalid Android target: #{target}"
              say "Valid Android targets: #{android_targets.join(', ')}", :yellow
              exit 1
            end

            # Route to platform-specific handler
            if platform == :android
              ship_android(target)
              return
            end

            # iOS flow continues below...

            is_appstore = (target == 'appstore')

            config = load_config
            client = create_client(config)

            overall_start = Time.now
            timings = {}
            archive_path = nil
            ipa_path = nil
            nil
            bundle_id = nil

            target_label = is_appstore ? 'App Store' : 'TestFlight'
            say "🚀 My Signer - Ship to #{target_label}", :cyan
            say '=' * 80, :cyan
            say ''
            say 'This will:', :bold
            say '  1️⃣  Detect and build your project'
            say '  2️⃣  Export IPA for App Store'
            say "  3️⃣  Upload to #{target_label}"
            if is_appstore
              say '  4️⃣  Wait for Apple to process build'
              say '  5️⃣  Submit for App Store review'
            end
            say ''
            say "⏱️  Estimated time: #{is_appstore ? '15-30 minutes' : '3-7 minutes'}", :yellow
            say ''

            begin
              # STEP 1: BUILD
              say '=' * 80, :cyan
              say '[1/3] Building Archive', :cyan
              say '=' * 80, :cyan
              say ''

              build_start = Time.now

              # Detect project
              project_info = Build::Detector.detect
              project_name = File.basename(project_info[:path], '.*')

              framework_label = case project_info[:framework]
                                when :capacitor then 'Capacitor/Ionic'
                                when :react_native then 'React Native'
                                when :flutter then 'Flutter'
                                else 'Native iOS'
                                end

              say "✓ Found: #{File.basename(project_info[:path])} (#{framework_label})", :green
              say ''

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
                  say 'Bundle IDs must contain only letters, numbers, hyphens, and periods', :yellow
                  exit 1
                end
              end

              say "🎯 Target: #{target_name}", :cyan
              say "📦 Bundle ID: #{bundle_id}#{' (overridden)' if options[:bundle_id]}", :cyan
              say '⏱️  Estimated: 2-5 minutes', :yellow
              say ''

              # Auto-fetch team ID from API if not provided and project missing it
              team_id_to_use = options[:team]
              project_team_id = parser.team_id(target_name, options[:configuration])

              if !team_id_to_use && (project_team_id.nil? || project_team_id.empty?)
                say '🔍 No team set in project, fetching from My Signer...', :yellow

                begin
                  org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                  api_team_id = org_response.dig(:data,
                                                 'app_store_connect_team_id') || org_response['app_store_connect_team_id']

                  if api_team_id && !api_team_id.empty?
                    team_id_to_use = api_team_id
                    say "✓ Using team from My Signer: #{api_team_id}", :green
                  else
                    say '⚠️  No team ID configured in My Signer', :yellow
                  end
                rescue StandardError => e
                  say "⚠️  Failed to fetch team from API: #{e.message}", :yellow
                end
              end
              say ''

              # Pre-build validation
              say '🔍 Validating signing setup...', :cyan
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

              say ''
              say "✓ Build complete in #{format_duration(timings[:build])}", :green
              say ''

              # STEP 2: EXPORT
              say '=' * 80, :cyan
              say '[2/3] Exporting IPA', :cyan
              say '=' * 80, :cyan
              say ''
              say '⏱️  Estimated: 30-90 seconds', :yellow
              say ''

              export_start = Time.now

              exporter = Export::Exporter.new(archive_path)
              ipa_path = exporter.export!(
                method: :appstore,
                team_id: nil,
                signing_style: 'automatic'
              )

              timings[:export] = Time.now - export_start

              say ''
              say "✓ Export complete in #{format_duration(timings[:export])}", :green
              say "📦 IPA: #{ipa_path}", :cyan
              say ''

              # STEP 2.5: Get current latest build (BEFORE upload) - App Store only
              latest_build_before_upload = nil
              if is_appstore
                say '=' * 80, :cyan
                say 'Getting Current Latest Build', :cyan
                say '=' * 80, :cyan
                say ''

                say '🔄 Syncing from App Store Connect...', :yellow
                begin
                  client.post("/api/v1/organizations/#{config.current_organization_id}/sync", body: { force: true })
                  sleep 15
                  say '✓ Sync complete', :green
                rescue StandardError => e
                  say "⚠️  Sync failed: #{e.message}", :yellow
                end
                say ''

                begin
                  app_response = client.get("/api/v1/organizations/#{config.current_organization_id}/apple_apps",
                                            params: { bundle_id: bundle_id })
                  app = Array(app_response.dig(:data, 'data', 'apps')).first

                  if app
                    builds_response = client.get("/api/v1/organizations/#{config.current_organization_id}/builds",
                                                 params: { app_id: app['id'] })
                    latest = Array(builds_response.dig(:data, 'data', 'builds')).first
                    if latest
                      latest_build_before_upload = latest['build_number'].to_i
                      say "✓ Current latest build: ##{latest_build_before_upload}", :green
                    else
                      say '✓ No builds yet', :green
                      latest_build_before_upload = 0
                    end
                  end
                rescue StandardError => e
                  say "⚠️  Could not fetch builds: #{e.message}", :yellow
                  latest_build_before_upload = 0
                end
                say ''
              end

              # STEP 3: UPLOAD
              say '=' * 80, :cyan
              say "[3/#{is_appstore ? '5' : '3'}] Uploading to #{target_label}", :cyan
              say '=' * 80, :cyan
              say ''
              say '⏱️  Estimated: 1-3 minutes', :yellow
              say ''

              upload_start = Time.now

              # Fetch App Store Connect credentials
              say '🔐 Fetching App Store Connect credentials...', :yellow

              org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
              org_data = org_response[:data]

              unless org_data['app_store_connect_configured']
                say ''
                say '✗ App Store Connect credentials not configured', :red
                say ''
                say 'Quick fix:', :cyan
                say '  mysigner doctor    # Auto-configure now', :green
                say ''
                say 'Or manually:', :cyan
                say '  1. Run: mysigner onboard'
                say '  2. Follow Step 5 to add credentials'
                say ''
                exit 1
              end

              api_key = org_data['app_store_connect_key_id']
              api_issuer = org_data['app_store_connect_issuer_id']
              private_key = org_data['app_store_connect_private_key']

              unless api_key && api_issuer && private_key
                say '✗ Error: Invalid credentials received from API', :red
                exit 1
              end

              say '✓ Credentials loaded', :green
              say ''

              # Upload
              uploader = Upload::Uploader.new(
                ipa_path,
                api_key: api_key,
                api_issuer: api_issuer,
                private_key: private_key
              )

              uploader.upload!(wait_for_processing: options[:wait])

              timings[:upload] = Time.now - upload_start

              # STEP 4: Submit for App Store Review (appstore only)
              if is_appstore
                say ''
                say '=' * 80, :cyan
                say '[4/5] Waiting for Apple to Process Build', :cyan
                say '=' * 80, :cyan
                say ''

                submission_start = Time.now

                # Poll sync every 3 minutes until we find a newer build
                say "⏳ Waiting for build ##{latest_build_before_upload + 1} to sync (polls every 3min)...", :yellow
                timeout = 1800 # 30 minutes
                poll_interval = 180 # 3 minutes
                start_time = Time.now
                new_build = nil
                poll_count = 0

                loop do
                  poll_count += 1
                  elapsed = Time.now - start_time

                  # Run sync
                  begin
                    client.post("/api/v1/organizations/#{config.current_organization_id}/sync", body: { force: true })
                    sleep 15
                  rescue StandardError => e
                    # Ignore
                  end

                  # Check for new build
                  begin
                    app_response = client.get("/api/v1/organizations/#{config.current_organization_id}/apple_apps",
                                              params: { bundle_id: bundle_id })
                    app = Array(app_response.dig(:data, 'data', 'apps')).first

                    if app
                      builds_response = client.get("/api/v1/organizations/#{config.current_organization_id}/builds",
                                                   params: { app_id: app['id'] })
                      latest = Array(builds_response.dig(:data, 'data', 'builds')).first

                      current_build_num = latest ? latest['build_number'].to_i : 0

                      if current_build_num > latest_build_before_upload
                        new_build = latest
                        say "✅ Build ##{new_build['build_number']} synced! (#{new_build['processing_state']})", :green
                        break
                      else
                        # Show progress
                        print "\r   [#{(elapsed / 60).to_i}m] Latest: ##{current_build_num}, waiting for ##{latest_build_before_upload + 1}..."
                        $stdout.flush
                      end
                    end
                  rescue StandardError => e
                    say "   ⚠️  Could not check builds: #{e.message}", :yellow
                  end

                  # Check timeout
                  if elapsed >= timeout
                    say ''
                    say "✗ Timeout after #{(elapsed / 60).to_i} minutes", :red
                    say "   Latest build is still ##{latest_build_before_upload}", :yellow
                    exit 1
                  end

                  # Wait before next poll
                  sleep poll_interval unless new_build
                end
                say ''

                # Step 3: Now wait for the new build to be processed
                require_relative '../upload/app_store_submission'
                require_relative '../upload/app_store_automation'

                automation = Upload::AppStoreAutomation.new(
                  client: client,
                  organization_id: config.current_organization_id,
                  opts: {
                    wait: true,
                    timeout: 1800,
                    poll_interval: 15,
                    no_submit: false
                  }
                )

                # Submit the new build (use its specific build number)
                # Build metadata overrides from CLI options
                ship_overrides = { 'auto_submit' => true }
                ship_override_keys = ['auto_submit']

                if options[:release_type]
                  # Validate release_type
                  valid_types = %w[AFTER_APPROVAL MANUAL SCHEDULED]
                  rt = options[:release_type].upcase
                  unless valid_types.include?(rt)
                    error "Invalid release type: #{options[:release_type]}"
                    say "Valid options: #{valid_types.join(', ')}", :yellow
                    exit 1
                  end
                  ship_overrides['release_type'] = rt
                  ship_override_keys << 'release_type'

                  # Validate scheduled_date is provided when SCHEDULED
                  if rt == 'SCHEDULED' && !options[:scheduled_date]
                    error 'Scheduled release date is required when --release-type=SCHEDULED'
                    say 'Use: --scheduled-date 2026-02-01T10:00:00Z', :yellow
                    exit 1
                  end
                end

                if options[:scheduled_date]
                  begin
                    parsed_date = Time.parse(options[:scheduled_date])
                    if parsed_date < Time.now + 3600 # At least 1 hour in the future
                      error 'Scheduled date must be at least 1 hour in the future'
                      exit 1
                    end
                    ship_overrides['earliest_release_date'] = parsed_date.utc.iso8601
                    ship_override_keys << 'earliest_release_date'
                    # Auto-set release_type to SCHEDULED if not already set
                    unless ship_overrides['release_type']
                      ship_overrides['release_type'] = 'SCHEDULED'
                      ship_override_keys << 'release_type'
                    end
                  rescue ArgumentError
                    error "Invalid date format: #{options[:scheduled_date]}"
                    say 'Use ISO 8601 format, e.g., 2026-02-01T10:00:00Z', :yellow
                    exit 1
                  end
                end

                submission = Upload::AppStoreSubmission.new(
                  client,
                  config.current_organization_id,
                  {
                    bundle_id: bundle_id,
                    build_number: new_build['build_number'] # Use the specific build we found
                  },
                  metadata_overrides: ship_overrides,
                  override_sources: [{ type: :inline, keys: ship_override_keys }]
                )

                submission_result = submission.submit_for_review!(automation: automation)
                timings[:submission] = Time.now - submission_start
              end

              timings[:total] = Time.now - overall_start

              # SUCCESS SUMMARY!
              say ''
              say '=' * 80, :green
              if is_appstore
                if submission_result && submission_result[:automation][:submitted]
                  say '🎉 SUCCESS! Your app is submitted for App Store review!', :green
                else
                  say '🎉 SUCCESS! Your app is uploaded to App Store Connect!', :green
                end
              else
                say '🎉 SUCCESS! Your app is on TestFlight!', :green
              end
              say '=' * 80, :green
              say ''

              # Summary table
              say '📊 Summary', :bold
              say ''
              say "  Project:     #{project_name}"
              say "  Bundle ID:   #{bundle_id}"
              say "  Target:      #{target_name}"
              say "  IPA Size:    #{format_bytes(File.size(ipa_path))}"
              say ''
              if is_appstore && options[:submit_for_review]
                poll_msg = options[:wait] ? "every #{automation.poll_interval}s" : 'skipped (--no-wait)'
                say "  ASC Polling: #{poll_msg}"
                say "  ASC Timeout: #{format_duration(options[:asc_timeout_seconds])}" if options[:asc_timeout_seconds]
              end

              # Timing breakdown
              say '⏱️  Time Breakdown', :bold
              say ''
              say "  Build:       #{format_duration(timings[:build])}"
              say "  Export:      #{format_duration(timings[:export])}"
              say "  Upload:      #{format_duration(timings[:upload])}"
              say "  Submission:  #{format_duration(timings[:submission])}" if timings[:submission]
              say "  #{'-' * 30}"
              say "  Total:       #{format_duration(timings[:total])}", :bold
              say ''

              # Files created
              say '📁 Files Created', :bold
              say ''
              say "  Archive:     #{archive_path}"
              say "  IPA:         #{ipa_path}"
              say ''

              # Next steps
              say '🔮 Next Steps', :bold
              say ''
              if is_appstore
                if submission_result && submission_result[:automation][:submitted]
                  say '  ✓ Your build is submitted for App Store review!', :green
                  say ''
                  say '  Monitor review status:', :cyan
                  say '     https://appstoreconnect.apple.com/apps', :green
                else
                  say '  ⚠️  Submission completed but not submitted', :yellow
                  say '     (May need release config in My Signer dashboard)', :yellow
                  say ''
                  say '  Or submit manually:', :cyan
                  say '     mysigner submit', :green
                end
              else
                say '  1. Wait 5-15 minutes for Apple to process your build'
                say '  2. Open App Store Connect:'
                say '     https://appstoreconnect.apple.com/apps'
                say '  3. Add testers and distribute via TestFlight'
              end
              say ''
            rescue MetadataFileError => e
              say ''
              say '=' * 80, :red
              say '✗ Ship Failed', :red
              say '=' * 80, :red
              say ''
              say "Error: #{e.message}", :red
              say ''
              exit 1
            rescue Build::Executor::BuildError => e
              # Analyze build errors and show helpful suggestions
              say ''

              if defined?(executor) && executor.respond_to?(:build_errors)
                require_relative '../build/error_analyzer'
                analyzer = Build::ErrorAnalyzer.new(executor.build_errors)

                say analyzer.format_suggestions, :cyan if analyzer.any_issues?
              end

              say '=' * 80, :red
              say '✗ Ship Failed', :red
              say '=' * 80, :red
              say ''
              say "Error: #{e.message}", :red
              say ''

              say "Archive saved at: #{archive_path}", :yellow if archive_path && File.exist?(archive_path)

              exit 1
            rescue Upload::AppStoreAutomation::AutomationError => e
              # Use enhanced error handler for App Store automation errors
              handle_apple_api_error(e, context: {
                                       title: 'App Store Automation Failed',
                                       archive_path: archive_path,
                                       ipa_path: ipa_path,
                                       bundle_id: defined?(bundle_id) ? bundle_id : nil
                                     })
              exit 1
            rescue Mysigner::ClientError => e
              # Handle API client errors with actionable suggestions
              handle_apple_api_error(e, context: {
                                       title: 'API Error',
                                       archive_path: archive_path,
                                       ipa_path: ipa_path
                                     })
              exit 1
            rescue StandardError => e
              say ''
              say '=' * 80, :red
              say '✗ Ship Failed', :red
              say '=' * 80, :red
              say ''
              say "Error: #{e.message}", :red
              say ''

              # Try to show actionable suggestions for unknown errors
              show_actionable_suggestions(e.message, platform: :ios)

              say "Archive saved at: #{archive_path}", :yellow if archive_path && File.exist?(archive_path)
              say "IPA saved at: #{ipa_path}", :yellow if ipa_path && File.exist?(ipa_path)

              show_debug_info(e) if ENV['DEBUG']
              exit 1
            end
          end

          no_commands do
            # Ship Android to Google Play
            def ship_android(track)
              config = load_config
              client = create_client(config)

              overall_start = Time.now
              timings = {}
              aab_path = nil
              package_name = nil

              track_labels = {
                'internal' => 'Internal Testing',
                'alpha' => 'Closed Testing (Alpha)',
                'beta' => 'Open Testing (Beta)',
                'production' => 'Production'
              }
              track_label = track_labels[track] || track.capitalize

              say "🤖 My Signer - Ship to Google Play (#{track_label})", :cyan
              say '=' * 80, :cyan
              say ''
              say 'This will:', :bold
              say '  1️⃣  Detect and build your Android project'
              say '  2️⃣  Sign with your keystore'
              say "  3️⃣  Upload to Google Play (#{track} track)"
              say ''
              say '⏱️  Estimated time: 3-10 minutes', :yellow
              say ''

              begin
                # STEP 1: Detect and build
                say '=' * 80, :cyan
                say '[1/3] Building Android App Bundle (AAB)', :cyan
                say '=' * 80, :cyan
                say ''

                build_start = Time.now

                # Detect Android project
                project_info = Build::Detector.detect_android

                framework_label = case project_info[:framework]
                                  when :capacitor then 'Capacitor/Ionic'
                                  when :react_native then 'React Native'
                                  when :flutter then 'Flutter'
                                  else 'Native Android'
                                  end

                say "✓ Found: Android project (#{framework_label})", :green
                say ''

                # Parse project
                require_relative '../build/android_parser'
                parser = Build::AndroidParser.new(project_info)

                package_name = options[:package_name] || parser.application_id
                local_version_code = parser.version_code.to_i
                version_name = parser.version_name

                # Check highest version code from API and auto-increment if needed
                highest_version_code = fetch_android_highest_version_code(client, config, package_name)
                version_code = local_version_code
                version_code_override = nil

                if highest_version_code && local_version_code <= highest_version_code
                  version_code = highest_version_code + 1
                  version_code_override = version_code
                  say "📦 Package: #{package_name}", :cyan
                  say "🔢 Version: #{version_name} (#{local_version_code} → #{version_code})", :cyan
                  say "   ↳ Auto-incremented (#{highest_version_code} already on Play Store)", :yellow

                  # For Expo projects, need to regenerate android folder with new versionCode
                  # since versionCode is hardcoded by expo prebuild
                  if expo_project?(Dir.pwd)
                    say ''
                    say "🔄 Regenerating android folder with version code #{version_code}...", :yellow
                    regenerate_expo_android(Dir.pwd, version_code)
                    # Re-detect after regeneration
                    project_info = Build::Detector.detect_android
                    parser = Build::AndroidParser.new(project_info)
                    version_code_override = nil # No longer need override, it's baked in
                    say '✓ Android folder regenerated', :green
                  end
                else
                  say "📦 Package: #{package_name}", :cyan
                  say "🔢 Version: #{version_name} (#{version_code})", :cyan
                end
                say '⏱️  Estimated: 2-5 minutes', :yellow
                say ''

                # STEP 2: Get keystore and sign
                say '=' * 80, :cyan
                say '[2/3] Signing with Keystore', :cyan
                say '=' * 80, :cyan
                say ''

                # Fetch keystore from API (prefer app-specific, fallback to org-wide)
                say '🔐 Fetching keystore from My Signer...', :yellow

                require_relative '../signing/keystore_manager'
                keystore_manager = Signing::KeystoreManager.new(client, config.current_organization_id)

                # Try to find the app to get app-specific + org-wide keystores
                app_id = nil
                begin
                  response = client.get("/api/v1/organizations/#{config.current_organization_id}/android_apps")
                  apps = response[:data]['android_apps'] || []
                  app = apps.find { |a| a['package_name'] == package_name }
                  app_id = app['id'] if app
                rescue StandardError
                  # Continue without app ID
                end

                active_keystore = keystore_manager.active_keystore(android_app_id: app_id, include_secrets: true)
                unless active_keystore
                  say ''
                  say '✗ No active keystore found', :red
                  say ''
                  say 'Quick fix:', :cyan
                  say '  1. Upload a keystore: mysigner keystore upload', :green
                  say '  2. Or configure in My Signer dashboard', :green
                  say ''
                  exit 1
                end

                say "✓ Using keystore: #{active_keystore['name']}", :green

                # Download keystore
                keystore_info = keystore_manager.get_or_download(active_keystore['id'])
                say "✓ Keystore ready at: #{keystore_info[:path]}", :green
                say ''

                # Get keystore credentials from API response
                keystore_password = active_keystore['keystore_password'] || ENV.fetch('MYSIGNER_KEYSTORE_PASSWORD', nil)
                key_password = active_keystore['key_password'] || ENV['MYSIGNER_KEY_PASSWORD'] || keystore_password
                key_alias = active_keystore['key_alias']

                unless keystore_password
                  say '⚠️  Keystore password not found in My Signer', :yellow
                  say '    Upload your keystore with password: mysigner keystore upload FILE', :yellow
                  keystore_password = ask('Keystore password:', echo: false)
                  say ''
                  key_password ||= keystore_password
                end

                # Build AAB
                require_relative '../build/android_executor'
                executor = Build::AndroidExecutor.new(project_info, parser)

                aab_path = executor.build_aab!(
                  variant: 'release',
                  keystore_path: keystore_info[:path],
                  keystore_password: keystore_password,
                  key_alias: key_alias,
                  key_password: key_password,
                  version_code: version_code_override
                )

                timings[:build] = Time.now - build_start

                say ''
                say "✓ Build complete in #{format_duration(timings[:build])}", :green
                say "📦 AAB: #{aab_path}", :cyan
                say ''

                # STEP 3: Upload to Google Play
                say '=' * 80, :cyan
                say '[3/3] Uploading to Google Play', :cyan
                say '=' * 80, :cyan
                say ''

                upload_start = Time.now

                # Fetch Google Play credentials from API
                say '🔐 Fetching Google Play credentials...', :yellow

                org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                org_data = org_response[:data]

                unless org_data['google_play_configured']
                  say ''
                  say '✗ Google Play credentials not configured', :red
                  say ''
                  say 'Quick fix:', :cyan
                  say '  Configure Google Play credentials in My Signer dashboard', :green
                  say ''
                  say 'Or configure in My Signer dashboard', :yellow
                  say ''
                  exit 1
                end

                service_account_json = org_data['google_play_service_account']

                unless service_account_json
                  say '✗ Error: Service account JSON not found', :red
                  exit 1
                end

                say '✓ Credentials loaded', :green
                say ''

                # Upload to Google Play
                require_relative '../upload/play_store_uploader'

                release_notes = nil
                release_notes = { 'en-US' => options[:release_notes] } if options[:release_notes]

                uploader = Upload::PlayStoreUploader.new(
                  aab_path: aab_path,
                  service_account_json: service_account_json,
                  package_name: package_name
                )

                uploader.upload!(
                  track: track,
                  release_notes: release_notes
                )

                timings[:upload] = Time.now - upload_start
                timings[:total] = Time.now - overall_start

                # Link keystore to app in MySigner (so dashboard shows it)
                if active_keystore && active_keystore['id']
                  begin
                    client.post(
                      "/api/v1/organizations/#{config.current_organization_id}/android_keystores/#{active_keystore['id']}/link_to_app",
                      body: { package_name: package_name }
                    )
                  rescue StandardError => e
                    # Non-fatal, continue
                  end
                end

                # Save build record to MySigner (for version tracking)
                save_android_build_record(client, config, package_name, version_code, version_name)

                # SUCCESS SUMMARY
                say ''
                say '=' * 80, :green
                say "🎉 SUCCESS! Your app is on Google Play (#{track} track)!", :green
                say '=' * 80, :green
                say ''

                say '📊 Summary', :bold
                say ''
                say "  Package:      #{package_name}"
                say "  Version:      #{version_name} (#{version_code})"
                say "  Track:        #{track}"
                say "  AAB Size:     #{format_bytes(File.size(aab_path))}"
                say ''

                say '⏱️  Time Breakdown', :bold
                say ''
                say "  Build:       #{format_duration(timings[:build])}"
                say "  Upload:      #{format_duration(timings[:upload])}"
                say "  #{'-' * 30}"
                say "  Total:       #{format_duration(timings[:total])}", :bold
                say ''

                say '📁 Files Created', :bold
                say ''
                say "  AAB:         #{aab_path}"
                say ''

                say '🔮 Next Steps', :bold
                say ''
                case track
                when 'internal'
                  say '  1. Add internal testers in Google Play Console'
                  say '  2. Testers will receive the build automatically'
                when 'alpha', 'beta'
                  say '  1. Review the build in Google Play Console'
                  say "  2. Promote to #{'beta or ' if track == 'alpha'}production when ready"
                when 'production'
                  say '  1. Review is pending in Google Play Console'
                  say '  2. Once approved, users will receive the update'
                end
                say ''
                say '  Google Play Console: https://play.google.com/console', :green
                say ''
              rescue Build::Detector::NoProjectError => e
                say ''
                say '=' * 80, :red
                say '✗ Ship Failed', :red
                say '=' * 80, :red
                say ''
                say "Error: #{e.message}", :red
                say ''
                say '💡 No Android Project Found: How to fix', :cyan
                say ''
                say "   → Make sure you're in an Android project directory", :yellow
                say '   → Check for build.gradle or build.gradle.kts file', :yellow
                say '   → For React Native: cd android && check build.gradle exists', :yellow
                say '   → For Flutter: check android/app/build.gradle exists', :yellow
                say ''
                exit 1
              rescue Upload::PlayStoreUploader::PartialUploadError => e
                # AAB was uploaded but track assignment/commit failed
                # Save build record to prevent version conflicts on retry
                say ''
                say '=' * 80, :red
                say '✗ Partial Upload - Track Assignment Failed', :red
                say '=' * 80, :red
                say ''
                say "Error: #{e.message}", :red
                say ''

                # Save build record even on partial failure (AAB is on Play Store)
                if e.version_code
                  save_android_build_record(client, config, package_name, e.version_code, version_name)
                  say "📝 Build v#{e.version_code} recorded (prevents version conflicts on retry)", :yellow
                  say ''
                end

                # Show track setup suggestions
                show_track_not_setup_suggestions(track)

                say "📦 AAB saved at: #{aab_path}", :yellow if aab_path && File.exist?(aab_path)
                say ''
                exit 1
              rescue Upload::PlayStoreUploader::UploadError => e
                # Use enhanced error handler for Google Play errors
                handle_android_api_error(e, context: {
                                           title: 'Google Play Upload Failed',
                                           aab_path: aab_path,
                                           package_name: package_name,
                                           track: track
                                         })
                exit 1
              rescue Mysigner::ClientError => e
                # Handle My Signer API client errors
                handle_android_api_error(e, context: {
                                           title: 'API Error',
                                           aab_path: aab_path,
                                           package_name: package_name
                                         })
                exit 1
              rescue StandardError => e
                say ''
                say '=' * 80, :red
                say '✗ Ship Failed', :red
                say '=' * 80, :red
                say ''
                say "Error: #{e.message}", :red
                say ''

                # Try to show actionable suggestions for unknown errors
                show_actionable_suggestions(e.message, platform: :android)

                say "📦 AAB saved at: #{aab_path}", :yellow if aab_path && File.exist?(aab_path)

                show_debug_info(e) if ENV['DEBUG']
                exit 1
              end
            end

            # Fetch highest version code from API
            def fetch_android_highest_version_code(client, config, package_name)
              response = client.get("/api/v1/organizations/#{config.current_organization_id}/android_apps")
              apps = response[:data]['android_apps'] || []
              app = apps.find { |a| a['package_name'] == package_name }

              return app['highest_version_code'].to_i if app && app['highest_version_code']

              nil
            rescue StandardError
              # Silently fail - we'll use local version
              nil
            end

            # Save build record to MySigner backend for version tracking
            def save_android_build_record(client, config, package_name, version_code, version_name)
              # First, find the app ID
              response = client.get("/api/v1/organizations/#{config.current_organization_id}/android_apps")
              apps = response[:data]['android_apps'] || []
              app = apps.find { |a| a['package_name'] == package_name }

              unless app
                # App doesn't exist in MySigner yet - create it with a friendly name
                friendly_name = generate_app_name_from_package(package_name)
                create_response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/android_apps",
                  body: { android_app: { package_name: package_name, name: friendly_name } }
                )
                app = create_response[:data]['android_app']
              end

              # Now save the build record
              client.post(
                "/api/v1/organizations/#{config.current_organization_id}/android_apps/#{app['id']}/android_builds",
                body: { android_build: { version_code: version_code, version_name: version_name, status: 'completed' } }
              )
            rescue StandardError => e
              # Non-fatal - just log for debugging
              say "⚠️  Could not save build record: #{e.message}", :yellow if options[:verbose]
            end

            # Generate a friendly app name from package name
            # e.g., "com.oopsfee.app" → "Oopsfee"
            # e.g., "com.example.myapp" → "Myapp"
            def generate_app_name_from_package(package_name)
              parts = package_name.to_s.split('.')
              # Take the most meaningful part (usually 2nd or 3rd segment)
              # Skip common prefixes like "com", "org", "io", "app"
              meaningful_part = parts.reject { |p| %w[com org io net app apps android].include?(p.downcase) }.first
              meaningful_part ||= parts.last
              # Capitalize first letter
              meaningful_part.to_s.capitalize
            end

            # Submit/promote existing Android build to a track
            def submit_android(track)
              config = load_config
              client = create_client(config)

              valid_tracks = %w[internal alpha beta production]
              unless valid_tracks.include?(track)
                error "Invalid Android track: #{track}"
                say "Valid tracks: #{valid_tracks.join(', ')}", :yellow
                exit 1
              end

              track_labels = {
                'internal' => 'Internal Testing',
                'alpha' => 'Closed Testing (Alpha)',
                'beta' => 'Open Testing (Beta)',
                'production' => 'Production'
              }
              track_label = track_labels[track]

              say "📤 Promote to Google Play #{track_label}", :cyan
              say '=' * 80, :cyan
              say ''

              begin
                # Get package name
                package_name = options[:package_name]

                unless package_name
                  begin
                    project_info = Build::Detector.detect_android
                    require_relative '../build/android_parser'
                    parser = Build::AndroidParser.new(project_info)
                    package_name = parser.application_id
                    say "✓ Detected package: #{package_name}", :green
                  rescue StandardError
                    error 'Could not detect package name from project'
                    say ''
                    say 'Please specify manually:', :yellow
                    say "  mysigner submit #{track} --platform android --package-name com.your.app", :cyan
                    exit 1
                  end
                end

                say ''
                say "📦 Package: #{package_name}", :cyan
                say "🎯 Target Track: #{track_label}", :cyan
                say ''

                # Fetch Google Play credentials
                say '🔐 Fetching Google Play credentials...', :yellow

                org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                org_data = org_response[:data]

                unless org_data['google_play_configured']
                  say ''
                  say '✗ Google Play credentials not configured', :red
                  say ''
                  say 'Configure Google Play credentials in My Signer dashboard', :cyan
                  exit 1
                end

                service_account_json = org_data['google_play_service_account']
                say '✓ Credentials loaded', :green
                say ''

                # Get the latest build from the API
                say '🔍 Finding builds in My Signer...', :yellow

                apps_response = client.get(
                  "/api/v1/organizations/#{config.current_organization_id}/android_apps",
                  params: { q: package_name }
                )
                apps = apps_response[:data]['android_apps'] || []
                app = apps.find { |a| a['package_name'] == package_name }

                unless app
                  say ''
                  say '⚠️  App not found in My Signer', :yellow
                  say ''
                  say 'The app may not be synced yet. Try:', :cyan
                  say '  mysigner sync android', :green
                  say ''
                end

                # Use version code from option or prompt for it
                version_code = options[:version_code]

                unless version_code
                  say ''
                  say "Enter the version code to promote to #{track}:", :yellow
                  version_code = ask('Version code:')
                end

                say ''
                say "📤 Promoting version #{version_code} to #{track} track...", :cyan
                say ''

                # Use PlayStoreUploader to assign to track
                require_relative '../upload/play_store_uploader'

                release_notes = nil
                release_notes = { 'en-US' => options[:release_notes] } if options[:release_notes]

                # Create a minimal uploader just for track assignment
                # We need to use the Google API directly for this
                require 'googleauth'
                require 'google/apis/androidpublisher_v3'
                require 'stringio'

                auth = Google::Auth::ServiceAccountCredentials.make_creds(
                  json_key_io: StringIO.new(service_account_json),
                  scope: 'https://www.googleapis.com/auth/androidpublisher'
                )

                service = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
                service.authorization = auth

                # Create edit
                edit = service.insert_edit(package_name, Google::Apis::AndroidpublisherV3::AppEdit.new)

                # Build release
                release = Google::Apis::AndroidpublisherV3::TrackRelease.new(
                  version_codes: [version_code.to_s],
                  status: 'completed'
                )

                if release_notes
                  release.release_notes = release_notes.map do |lang, text|
                    Google::Apis::AndroidpublisherV3::LocalizedText.new(language: lang, text: text)
                  end
                end

                # Update track
                track_obj = Google::Apis::AndroidpublisherV3::Track.new(
                  track: track,
                  releases: [release]
                )
                service.update_edit_track(package_name, edit.id, track, track_obj)

                # Commit
                service.commit_edit(package_name, edit.id, changes_not_sent_for_review: true)

                say ''
                say '=' * 80, :green
                say "✓ Successfully promoted to #{track} track!", :green
                say '=' * 80, :green
                say ''
                say "📦 Package: #{package_name}"
                say "🔢 Version Code: #{version_code}"
                say "🎯 Track: #{track_label}"
                say ''
                say 'View in Google Play Console:', :cyan
                say '  https://play.google.com/console', :green
                say ''
              rescue Google::Apis::ClientError => e
                say ''
                say '=' * 80, :red
                say '✗ Promotion Failed', :red
                say '=' * 80, :red
                say ''
                say "Google Play API error: #{e.message}", :red
                exit 1
              rescue StandardError => e
                say ''
                say '=' * 80, :red
                say '✗ Promotion Failed', :red
                say '=' * 80, :red
                say ''
                say "Error: #{e.message}", :red
                exit 1
              end
            end

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

              raise MetadataFileError, "Metadata file not found: #{expanded}" unless File.exist?(expanded) && File.file?(expanded)

              content = File.read(expanded)
              parsed = parse_metadata_content(content, expanded)

              raise MetadataFileError, 'Metadata file must contain a JSON/YAML object at the top level' unless parsed.is_a?(Hash)

              stringify_keys(parsed)
            rescue Errno::EACCES => e
              raise MetadataFileError, "Cannot read metadata file #{expanded}: #{e.message}"
            end

            def parse_metadata_content(content, path)
              stripped = content.lstrip

              begin
                return YAML.safe_load(content, aliases: true) || {} if stripped.start_with?('---') || stripped.start_with?('- ')

                JSON.parse(content)
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
                say '   ASC Polling: skipped (--no-wait)', :yellow
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
                  say "   Overrides: CLI flag#{" (#{keys})" unless keys.empty?}"
                when :file
                  say "   Overrides: #{File.basename(source[:path])}#{" (#{keys})" unless keys.empty?}"
                end
              end
            end
          end

          desc 'build', "Build .xcarchive only (advanced - most users should use 'ship')"
          method_option :configuration, aliases: '-c', default: 'Release',
                                        desc: 'Build configuration (Debug, Release, etc.)'
          method_option :target, aliases: '-t', desc: 'Target to build (auto-detect if not specified)'
          method_option :scheme, aliases: '-s', desc: 'Scheme to build (defaults to target name)'
          method_option :type, default: 'appstore', desc: 'Build type: development, adhoc, appstore, enterprise'
          method_option :team, desc: 'Development team ID (overrides project setting)'
          method_option :bundle_id, aliases: '-b', desc: 'Bundle ID (overrides project setting)'
          method_option :skip_extensions, type: :boolean, default: false,
                                          desc: 'Skip extension targets (useful when extensions are not configured)'
          def build
            config = load_config
            client = create_client(config)

            say '🔍 Detecting project...', :cyan
            say ''

            begin
              # Detect project
              project_info = Build::Detector.detect

              framework_label = case project_info[:framework]
                                when :capacitor then 'Capacitor/Ionic'
                                when :react_native then 'React Native'
                                when :flutter then 'Flutter'
                                else 'Native iOS'
                                end

              say "✓ Found: #{File.basename(project_info[:path])} (#{framework_label})", :green
              say ''

              # Parse project
              parser = Build::Parser.new(project_info)

              # Check if this is a buildable app (not framework/library)
              main_product_type = parser.product_type
              unless %i[app unknown].include?(main_product_type)
                error "Cannot build #{main_product_type} projects for TestFlight"
                say ''
                say 'My Signer builds iOS/macOS/tvOS apps for distribution.', :yellow
                say "This project builds a #{main_product_type}, not an app.", :yellow
                say ''
                exit 1
              end

              # Check for multiple apps and prompt user if needed
              if parser.has_multiple_apps? && !options[:target]
                app_targets = parser.app_targets
                say 'Multiple apps found in project:', :yellow
                app_targets.each_with_index do |target, i|
                  say "  #{i + 1}. #{target.name}", :cyan
                end
                say ''

                choice = ask("Select app to build (1-#{app_targets.count}):",
                             limited_to: (1..app_targets.count).map(&:to_s))
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
                if options[:skip_extensions]
                  say "🧩 Extensions: #{ext_count} (will be SKIPPED - signing disabled)", :yellow
                else
                  say "🧩 Extensions: #{ext_count} (will be included in build)", :cyan
                end
              end

              bundle_id = options[:bundle_id] || parser.bundle_id(target_name, options[:configuration])

              # Validate bundle ID format if overridden
              if options[:bundle_id]
                if bundle_id =~ /\$\(|\$\{/
                  error "Bundle ID cannot contain variables: #{bundle_id}"
                  exit 1
                elsif bundle_id !~ /^[a-zA-Z0-9.-]+$/
                  error "Invalid bundle ID format: #{bundle_id}"
                  say 'Bundle IDs must contain only letters, numbers, hyphens, and periods', :yellow
                  exit 1
                end
              end

              say "📦 Bundle ID: #{bundle_id}#{' (overridden)' if options[:bundle_id]}", :cyan
              say "⚙️  Configuration: #{options[:configuration]}", :cyan

              # Check signing style
              sign_style = parser.code_sign_style(target_name, options[:configuration])
              say "🔐 Signing: #{sign_style || 'Not Set'}", :cyan

              # Auto-fetch team ID from API if not provided and project missing it
              team_id_to_use = options[:team]
              project_team_id = parser.team_id(target_name, options[:configuration])

              if !team_id_to_use && (project_team_id.nil? || project_team_id.empty?)
                say '🔍 No team set in project, fetching from My Signer...', :yellow

                begin
                  org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                  api_team_id = org_response.dig(:data,
                                                 'app_store_connect_team_id') || org_response['app_store_connect_team_id']

                  if api_team_id && !api_team_id.empty?
                    team_id_to_use = api_team_id
                    say "✓ Using team from My Signer: #{api_team_id}", :green
                  else
                    say '⚠️  No team ID configured in My Signer', :yellow
                  end
                rescue StandardError => e
                  say "⚠️  Failed to fetch team from API: #{e.message}", :yellow
                end
              end

              say ''

              # Handle signing based on style
              if sign_style == 'Automatic'
                say 'ℹ️  Using Automatic signing (Xcode will manage profiles)', :yellow
              elsif sign_style == 'Manual'
                # Check if manual signing is already configured
                if parser.signing_configured?(target_name, options[:configuration])
                  say 'ℹ️  Manual signing already configured, using existing settings', :yellow
                else
                  say '⚠️  Manual signing enabled but not configured', :yellow
                  say '🔐 Configuring manual signing via My Signer API...', :cyan

                  configurator = Build::Configurator.new(parser, client, config.current_organization_id)
                  build_type = options[:type].to_sym

                  profile = configurator.configure!(target_name, options[:configuration], build_type: build_type)

                  say "✓ Configured with profile: #{profile['name']}", :green
                end
              else
                # No signing style set, default to automatic signing for simplicity
                say 'ℹ️  No signing style set, defaulting to Automatic signing', :yellow
                say 'ℹ️  Xcode will manage profiles automatically', :yellow
                say ''
                say '💡 To use Manual signing instead, run: mysigner signing configure', :cyan
              end
              say ''

              # Pre-build validation
              say '🔍 Validating signing setup...', :cyan
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
                bundle_id: options[:bundle_id],
                skip_extensions: options[:skip_extensions]
              )

              say ''
              say '=' * 80, :green
              say '✓ Build succeeded!', :green
              say '=' * 80, :green
              say ''
              say "📦 Archive: #{archive_path}", :cyan
              say ''
              say 'Next steps:', :bold
              say "  mysigner export #{archive_path}"
              say '  mysigner ship testflight'
              say ''
            rescue Build::Detector::NoProjectError => e
              error e.message
              say ''
              say 'Supported project types:', :yellow
              say '  - Native iOS (.xcodeproj, .xcworkspace)'
              say '  - Capacitor/Ionic (ionic project with ios/ folder)'
              say '  - React Native (RN project with ios/ folder)'
              say '  - Flutter (flutter project with ios/ folder)'
              exit 1
            rescue Build::Configurator::ProfileNotFoundError => e
              error e.message
              say ''
              say 'Try:', :yellow
              say '  mysigner profiles                    # List available profiles'
              say '  mysigner doctor                      # Auto-create or repair profiles'
              exit 1
            rescue Build::Executor::BuildError => e
              # Analyze build errors and show helpful suggestions
              say ''

              if executor.respond_to?(:build_errors)
                require_relative '../build/error_analyzer'
                analyzer = Build::ErrorAnalyzer.new(executor.build_errors)

                say analyzer.format_suggestions, :cyan if analyzer.any_issues?
              end

              error e.message
              exit 1
            rescue StandardError => e
              error "Build failed: #{e.message}"
              say ''
              say 'Full error:', :yellow
              say e.full_message
              exit 1
            end
          end

          desc 'export ARCHIVE_PATH', "Export .xcarchive to .ipa (advanced - most users should use 'ship')"
          method_option :method, type: :string, default: 'appstore',
                                 desc: 'Export method (appstore, adhoc, enterprise, development)'
          method_option :output, type: :string, desc: 'Output directory for .ipa file'
          def export(archive_path)
            load_config

            begin
              say '📦 My Signer - Export', :cyan
              say '=' * 80, :cyan
              say ''

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

              say ''
              say '=' * 80, :green
              say '✓ Export succeeded!', :green
              say '=' * 80, :green
              say ''
              say "📦 IPA: #{ipa_path}", :green
              say ''
              say 'Next steps:', :cyan
              say "  mysigner upload testflight #{ipa_path}", :cyan
              say '  mysigner ship testflight', :cyan
              say ''
            rescue Export::Exporter::ExportError => e
              say ''
              say "✗ Error: #{e.message}", :red
              exit 1
            rescue StandardError => e
              say ''
              say "✗ Unexpected error: #{e.message}", :red
              say e.backtrace.first(5).join("\n"), :red if ENV['DEBUG']
              exit 1
            end
          end

          desc 'upload testflight IPA_PATH',
               "Upload existing .ipa to TestFlight (advanced - most users should use 'ship')"
          method_option :wait, type: :boolean, default: false, desc: 'Wait for processing to complete'
          def upload(target, ipa_path)
            unless target == 'testflight'
              error "Only 'testflight' target is supported currently"
              say 'Usage: mysigner upload testflight IPA_PATH', :yellow
              exit 1
            end

            config = load_config
            client = create_client(config)

            begin
              say '☁️  My Signer - Upload to TestFlight', :cyan
              say '=' * 80, :cyan
              say ''

              # Validate IPA path
              unless File.exist?(ipa_path)
                say "✗ Error: IPA file not found: #{ipa_path}", :red
                exit 1
              end

              # Fetch App Store Connect credentials from API
              say '🔐 Fetching App Store Connect credentials...', :yellow

              begin
                org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                org_data = org_response[:data]

                # Check if credentials are configured
                unless org_data['app_store_connect_configured']
                  say ''
                  say '✗ App Store Connect credentials not configured', :red
                  say ''
                  say 'Quick fix:', :cyan
                  say '  mysigner doctor    # Auto-configure now', :green
                  say ''
                  say 'Or manually:', :cyan
                  say '  1. Run: mysigner onboard'
                  say '  2. Follow Step 5 to add credentials'
                  say ''
                  exit 1
                end

                # Get credentials (API will return the decrypted values)
                api_key = org_data['app_store_connect_key_id']
                api_issuer = org_data['app_store_connect_issuer_id']
                private_key = org_data['app_store_connect_private_key']

                unless api_key && api_issuer && private_key
                  say '✗ Error: Invalid credentials received from API', :red
                  exit 1
                end

                say '✓ Credentials loaded', :green
                say ''
              rescue Mysigner::ClientError => e
                say ''
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
              uploader.upload!(wait_for_processing: options[:wait])

              say '🎉 Upload complete!', :green
              say ''
              say 'Next steps:', :cyan
              say '  • Open App Store Connect to see your build'
              say '  • Wait for processing (5-15 minutes)'
              say '  • Distribute to TestFlight testers'
              say ''
            rescue Upload::Uploader::TransporterNotFoundError => e
              say ''
              say "✗ Error: #{e.message}", :red
              exit 1
            rescue Upload::Uploader::UploadError => e
              say ''
              say "✗ Upload Error: #{e.message}", :red
              exit 1
            rescue StandardError => e
              say ''
              say "✗ Unexpected error: #{e.message}", :red
              say e.backtrace.first(5).join("\n"), :red if ENV['DEBUG']
              exit 1
            end
          end

          desc 'submit [TRACK]', '📤 Submit existing build for store review (no upload)'
          long_desc <<~DESC
            Submit an existing build for review without building/uploading.

            iOS (App Store):
              mysigner submit                           # Submit latest iOS build
              mysigner submit --bundle-id com.app.id    # Specify bundle ID
              mysigner submit --build-number 12         # Submit specific build

            Android (Google Play):
              mysigner submit production --platform android   # Promote to production
              mysigner submit beta --platform android         # Promote to beta track

            ANDROID TRACKS (optional argument):
              internal   : Move to internal testing
              alpha      : Move to closed testing (alpha)
              beta       : Move to open testing (beta)
              production : Move to production

            iOS OPTIONS:
              --bundle-id ID          Specify bundle ID (auto-detect from project if not provided)
              --build-number NUM      Submit specific build number (defaults to latest)
              --version STRING        Create version with specific version string

            ANDROID OPTIONS:
              --package-name PKG      Android package name
              --version-code NUM      Specific version code to promote
              --release-notes TEXT    Release notes for the track

            COMMON OPTIONS:
              --platform              ios or android (auto-detect if not specified)
          DESC
          method_option :bundle_id, aliases: '-b', desc: 'Bundle ID (auto-detect from project)'
          method_option :build_number, type: :string, desc: 'Specific build number to submit'
          method_option :version, type: :string, desc: 'Version string for App Store version'
          method_option :whats_new, type: :string, banner: 'TEXT', desc: "What's New text (required for submission)"
          method_option :support_url, type: :string, banner: 'URL', desc: 'Support URL (required for submission)'
          method_option :marketing_url, type: :string, banner: 'URL', desc: 'Marketing URL (optional)'
          method_option :privacy_url, type: :string, banner: 'URL', desc: 'Privacy Policy URL (optional)'
          method_option :release_type, type: :string, enum: %w[AFTER_APPROVAL MANUAL SCHEDULED],
                                       desc: 'Release type: AFTER_APPROVAL (auto-release), MANUAL (hold for manual release), or SCHEDULED'
          method_option :scheduled_date, type: :string, banner: 'ISO8601',
                                         desc: 'Scheduled release date (ISO 8601 format, e.g., 2026-02-01T10:00:00Z). Required when --release-type=SCHEDULED'
          method_option :platform, type: :string, desc: 'Platform: ios or android'
          method_option :package_name, type: :string, desc: 'Android package name'
          method_option :version_code, type: :string, desc: 'Android version code to promote'
          method_option :release_notes, type: :string, desc: 'Release notes for Android'
          def submit(track = nil)
            config = load_config
            client = create_client(config)

            # Determine platform
            android_tracks = %w[internal alpha beta production]
            platform = options[:platform]&.to_sym

            # Auto-detect platform from track argument or option
            if platform.nil?
              platform = if track && android_tracks.include?(track)
                           :android
                         else
                           :ios
                         end
            end

            # Route to Android submit if needed
            if platform == :android
              submit_android(track || 'production')
              return
            end

            # iOS submit flow continues below...
            say '📤 Submit for App Store Review', :cyan
            say '=' * 80, :cyan
            say ''

            # Get bundle ID from project or option
            bundle_id = options[:bundle_id]

            unless bundle_id
              begin
                project_info = Build::Detector.detect
                parser = Build::Parser.new(project_info)
                target_name = parser.main_target.name
                bundle_id = parser.bundle_id(target_name, 'Release')
                say "✓ Detected bundle ID from project: #{bundle_id}", :green
              rescue StandardError
                error 'Could not detect bundle ID from project'
                say ''
                say 'Please specify manually:', :yellow
                say '  mysigner submit --bundle-id com.your.app.id', :cyan
                exit 1
              end
            end

            say ''
            say "📱 Bundle ID: #{bundle_id}", :cyan
            say ''

            begin
              require_relative '../upload/app_store_submission'
              require_relative '../upload/app_store_automation'

              automation = Upload::AppStoreAutomation.new(
                client: client,
                organization_id: config.current_organization_id,
                opts: {
                  wait: false, # No need to wait - only using already-processed builds
                  no_submit: false
                }
              )

              # Get version from project or option
              version_string = options[:version]
              unless version_string
                begin
                  project_info ||= Build::Detector.detect
                  parser ||= Build::Parser.new(project_info)
                  target_name ||= parser.main_target.name
                  version_string = parser.build_settings(target_name, 'Release')['MARKETING_VERSION']
                rescue StandardError
                  version_string = nil
                end
              end

              build_info = {
                bundle_id: bundle_id,
                version: version_string || '1.0',
                build_number: options[:build_number]
              }

              # Force submission when running 'mysigner submit' explicitly
              # Build metadata overrides from CLI options
              metadata_overrides = { 'auto_submit' => true }
              override_keys = ['auto_submit']

              if options[:whats_new]
                metadata_overrides['whats_new'] = options[:whats_new]
                override_keys << 'whats_new'
              end

              if options[:support_url]
                metadata_overrides['support_url'] = options[:support_url]
                override_keys << 'support_url'
              end

              if options[:marketing_url]
                metadata_overrides['marketing_url'] = options[:marketing_url]
                override_keys << 'marketing_url'
              end

              if options[:privacy_url]
                metadata_overrides['privacy_policy_url'] = options[:privacy_url]
                override_keys << 'privacy_policy_url'
              end

              if options[:release_type]
                # Validate release_type
                valid_types = %w[AFTER_APPROVAL MANUAL SCHEDULED]
                rt = options[:release_type].upcase
                unless valid_types.include?(rt)
                  error "Invalid release type: #{options[:release_type]}"
                  say "Valid options: #{valid_types.join(', ')}", :yellow
                  exit 1
                end
                metadata_overrides['release_type'] = rt
                override_keys << 'release_type'

                # Validate scheduled_date is provided when SCHEDULED
                if rt == 'SCHEDULED' && !options[:scheduled_date]
                  error 'Scheduled release date is required when --release-type=SCHEDULED'
                  say 'Use: --scheduled-date 2026-02-01T10:00:00Z', :yellow
                  exit 1
                end
              end

              if options[:scheduled_date]
                begin
                  parsed_date = Time.parse(options[:scheduled_date])
                  if parsed_date < Time.now + 3600 # At least 1 hour in the future
                    error 'Scheduled date must be at least 1 hour in the future'
                    exit 1
                  end
                  metadata_overrides['earliest_release_date'] = parsed_date.utc.iso8601
                  override_keys << 'earliest_release_date'

                  # Auto-set release_type to SCHEDULED if not already set
                  unless metadata_overrides['release_type']
                    metadata_overrides['release_type'] = 'SCHEDULED'
                    override_keys << 'release_type'
                  end
                rescue ArgumentError => e
                  error "Invalid date format: #{options[:scheduled_date]}"
                  say 'Use ISO 8601 format, e.g., 2026-02-01T10:00:00Z', :yellow
                  exit 1
                end
              end

              submission = Upload::AppStoreSubmission.new(
                client,
                config.current_organization_id,
                build_info,
                metadata_overrides: metadata_overrides,
                override_sources: [{ type: :inline, keys: override_keys }]
              )

              result = submission.submit_for_review!(automation: automation)

              say ''
              say '=' * 80, :green
              say '✓ Submission Complete!', :green
              say '=' * 80, :green
              say ''

              if result[:automation][:submitted]
                say '🎉 Your app is submitted for App Store review!', :green
                say ''
                say 'Monitor status:', :cyan
                say '  https://appstoreconnect.apple.com/apps', :green
              else
                say "⚠️  Submission skipped: #{result[:automation][:skip_reason]}", :yellow
              end
              say ''
            rescue Upload::AppStoreAutomation::AutomationError => e
              # Use enhanced error handler for App Store automation errors
              handle_apple_api_error(e, context: {
                                       title: 'Submission Failed',
                                       bundle_id: options[:bundle_id]
                                     })
              exit 1
            rescue Mysigner::ClientError => e
              # Handle API client errors with actionable suggestions
              handle_apple_api_error(e, context: {
                                       title: 'API Error'
                                     })
              exit 1
            rescue StandardError => e
              say ''
              say '=' * 80, :red
              say '✗ Submission Failed', :red
              say '=' * 80, :red
              say ''
              say "Error: #{e.message}", :red
              say ''

              # Try to show actionable suggestions for unknown errors
              show_actionable_suggestions(e.message, platform: :ios)

              show_debug_info(e) if ENV['DEBUG']
              exit 1
            end
          end

          desc 'signing configure', '🧙 Wizard: Configure manual code signing in your Xcode project'
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
              say 'Usage: mysigner signing configure', :yellow
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
                error 'Cannot use both --target and --all-targets'
                exit 1
              end

              # Check current signing style
              target_name = options[:target] || parser.main_target.name
              signing_style = parser.code_sign_style(target_name)

              if signing_style == 'Automatic'
                say '⚠️  Project uses Automatic signing', :yellow
                say ''
                say 'Your project is configured for Automatic signing, which means:', :cyan
                say '  • Xcode manages profiles automatically'
                say '  • No manual profile configuration needed'
                say '  • Team ID is all you need'
                say ''
                say "Current Team ID: #{parser.team_id(target_name) || '(not set)'}", :green
                say ''
                say 'You can build with: mysigner build'
                say ''
                say '💡 To convert to Manual signing, use: mysigner signing configure --force-manual'
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
