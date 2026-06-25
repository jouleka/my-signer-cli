# frozen_string_literal: true

require 'json'
require 'yaml'
require 'time'
require_relative '../upload/play_store_uploader'
require_relative '../upload/app_store_automation'
require_relative '../upload/app_store_submission'
require_relative '../upload/asc_rest_uploader'

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

            iOS TARGETS (requires macOS + Xcode)
              testflight : Beta testing via TestFlight
              appstore   : Submit for public App Store release

            ANDROID TARGETS (works on macOS, Linux, and Windows)
              internal   : Fastest — up to 100 testers you list. NOT public.
              alpha      : Closed testing — an invite-only tester group.
              beta       : Open testing — anyone with your opt-in link.
              production : PUBLIC — goes LIVE to everyone on the Google Play Store.

            An AAB (Android App Bundle, .aab) is what Google Play requires — the
            CLI builds and signs it for you (you don't upload an APK).

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

            LOCAL-ONLY (no My Signer account — use your OWN credentials)
              Run `mysigner --local-only onboard` once for a guided setup, or pass:
                iOS:     --asc-key-path (the AuthKey_XXXX.p8 from
                         appstoreconnect.apple.com/access/api), --asc-key-id (the
                         XXXX in that filename), --asc-issuer-id (the UUID on that page)
                Android: --keystore-path / --keystore-password / --key-alias and
                         --play-credentials (a Google Play service-account .json)

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
          method_option :release_notes, type: :string, desc: 'Release notes for Play Store (Android) / App Store (iOS whatsNew)'
          method_option :metadata_file, type: :string, desc: 'Path to metadata JSON file (iOS App Store submissions)'
          method_option :version, type: :string, desc: 'Set version name for Android (e.g., 1.2.0)'
          method_option :release_type, type: :string, enum: %w[AFTER_APPROVAL MANUAL SCHEDULED],
                                       desc: 'Release type for App Store: AFTER_APPROVAL, MANUAL, or SCHEDULED'
          method_option :scheduled_date, type: :string, banner: 'ISO8601',
                                         desc: 'Scheduled release date (ISO 8601, e.g., 2026-02-01T10:00:00Z)'
          method_option :auto_submit, type: :boolean,
                                      desc: 'Submit for App Store review after upload. Defaults to dashboard CLI Defaults, else true for ship appstore. Use --no-auto-submit to skip.'
          # mysigner-22 Phase 5 — local-only credential auto-discovery
          # overrides. These layer on top of env vars / Keychain / disk scan;
          # see Mysigner::CredentialResolver. They are no-ops in vault mode.
          method_option :asc_key_path, type: :string, banner: 'PATH',
                                       desc: 'Path to your App Store Connect .p8 key (local-only mode)'
          method_option :asc_key_id, type: :string, banner: 'KEY_ID',
                                     desc: 'App Store Connect Key ID (local-only mode)'
          method_option :asc_issuer_id, type: :string, banner: 'UUID',
                                        desc: 'App Store Connect Issuer ID (local-only mode)'
          method_option :play_credentials, type: :string, banner: 'PATH',
                                           desc: 'Path to Google Play service-account JSON (local-only mode)'
          # mysigner-22 Phase 7 — Android keystore overrides for --local-only.
          # In vault mode these are ignored; the cascade only fires when
          # local_only? is true.
          method_option :keystore_path, type: :string, banner: 'PATH',
                                        desc: 'Path to Android signing keystore .jks/.keystore (local-only mode)'
          method_option :keystore_password, type: :string, banner: 'PWD',
                                            desc: 'Android keystore password (local-only mode)'
          method_option :key_alias, type: :string, banner: 'ALIAS',
                                    desc: 'Android key alias inside the keystore (local-only mode)'
          method_option :key_password, type: :string, banner: 'PWD',
                                       desc: 'Android key password (defaults to keystore password) (local-only mode)'
          # mysigner-22 — explicit Apple-side app id override for local-only
          # mode. When the bundleId lookup against Apple's /v1/apps returns
          # zero or multiple matches, the user can short-circuit it by passing
          # the exact appstoreconnect app id from the URL of their app page
          # (e.g. https://appstoreconnect.apple.com/apps/<APPLE_APP_ID>/...).
          method_option :apple_id, type: :string, banner: 'APPLE_APP_ID',
                                   desc: 'App Store Connect app id (overrides bundleId lookup in --local-only mode)'
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

            # iOS flow continues below — requires macOS + Xcode.
            require_macos!("ship #{target}")

            is_appstore = (target == 'appstore')

            # mysigner-42 — when the user opts into local-only for `ship`
            # (testflight/appstore), surface the banner once so they know their
            # .p8 won't traverse the MySigner server. The uploader itself
            # enforces the contract below.
            emit_local_only_banner if local_only?

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
                # mysigner-22 — local-only mode cannot read team-id from the
                # MySigner org record (no client). Surface a useful hint
                # instead of letting xcodebuild fail later with a generic
                # signing error.
                if local_only?
                  say '⚠️  No team set in project and --local-only mode (cannot fetch from MySigner).', :yellow
                  say '   Pass --team <TEAM_ID> or set DEVELOPMENT_TEAM in your Xcode project.', :yellow
                else
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
              end
              say ''

              # Pre-build validation
              say '🔍 Validating signing setup...', :cyan
              validator = Signing::Validator.new(parser, target_name, options[:configuration],
                                                 team_id: team_id_to_use, local_only: local_only?)
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

              # STEP 2.5: Get current latest build (BEFORE upload) - App Store only.
              # mysigner-22 — in local-only mode every probe here was a
              # MySigner-server call. We skip the whole block: Apple itself is
              # the source of truth for whether the upload succeeded
              # (AscRestUploader polls /v1/buildUploads directly), so the
              # "did a new build appear server-side" comparison is moot.
              latest_build_before_upload = nil
              if is_appstore && !local_only?
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

              # ASC REST Build Upload API. No .p8 ever leaves the server in
              # vault mode; local-only mode delegates to altool via the
              # uploader itself.
              require_relative '../upload/asc_rest_uploader'

              # In local-only mode, pre-resolve ASC creds via the cascade
              # (flag → env → keychain → ~/.appstoreconnect → prompt) BEFORE
              # the app-id lookup, because the lookup itself needs a JWT.
              # The uploader will mint the JWT from these; no LocalCredentials
              # round-trip happens inside it. In vault mode this is nil and
              # the uploader takes the server-mediated path unchanged.
              asc_creds_for_uploader = (resolve_local_asc_creds_or_exit if local_only?)

              # Resolve apple_app_id.
              # - vault mode: MySigner /apple_apps lookup (may have been
              #   pre-fetched in the appstore sync block above).
              # - local-only: explicit --apple-id wins; otherwise hit Apple's
              #   /v1/apps?filter[bundleId]= directly.
              apple_app_id =
                if local_only?
                  resolve_apple_app_id_local!(
                    bundle_id: bundle_id,
                    apple_id_override: options[:apple_id],
                    asc_creds: asc_creds_for_uploader
                  )
                else
                  if !defined?(app) || app.nil?
                    app_response = client.get("/api/v1/organizations/#{config.current_organization_id}/apple_apps",
                                              params: { bundle_id: bundle_id })
                    app = Array(app_response.dig(:data, 'data', 'apps')).first
                  end

                  unless app && app['id']
                    say "✗ App not found in MySigner for bundle_id: #{bundle_id}", :red
                    say 'Run: mysigner sync ios', :yellow
                    exit 1
                  end

                  app['id']
                end

              # Read version info from the built IPA
              ipa_info = Upload::Uploader.extract_ipa_info(ipa_path)
              cf_version = ipa_info[:cf_bundle_version] || '1'
              cf_short   = ipa_info[:cf_bundle_short_version_string] || '1.0'

              say "📤 Uploading via App Store Connect REST API (version #{cf_short} build #{cf_version})...", :cyan

              rest = Mysigner::Upload::AscRestUploader.new(
                client: client,
                organization_id: local_only? ? nil : config.current_organization_id,
                ipa_path: ipa_path,
                apple_app_id: apple_app_id,
                cf_bundle_version: cf_version,
                cf_bundle_short_version_string: cf_short,
                platform: 'IOS',
                local_only: local_only?,
                asc_creds: asc_creds_for_uploader
              )

              result = rest.call
              case result[:final_state]
              when 'COMPLETE'
                say '✓ Upload complete — Apple accepted the build', :green
              when 'FAILED', 'INVALIDATED'
                say "✗ Apple rejected the upload: #{result[:final_state]}", :red
                exit 1
              when 'TIMEOUT'
                say '⚠ Apple is still processing — check App Store Connect.', :yellow
              end

              timings[:upload] = Time.now - upload_start

              # STEP 4: Submit for App Store Review (appstore only).
              # mysigner-22 follow-up — local-only now drives the same
              # 4-step Apple REST submission flow the vault path drives via
              # MySigner, using the JWT minted from the user's local .p8.
              # Gated by --auto-submit (default true, --no-auto-submit opts
              # out) so users who want "upload only, finish in dashboard"
              # still have that path.
              if is_appstore && local_only?
                auto_submit_default = true
                auto_submit = options.key?(:auto_submit) ? options[:auto_submit] : auto_submit_default

                say ''
                say '=' * 80, :cyan
                if auto_submit
                  say '[4/4] Submit for App Store Review (--local-only)', :cyan
                  say '=' * 80, :cyan
                  say ''
                  submit_appstore_local!(
                    asc_creds: asc_creds_for_uploader,
                    apple_app_id: apple_app_id,
                    cf_bundle_version: cf_version,
                    cf_bundle_short_version_string: cf_short
                  )
                else
                  say '[4/4] Submit for App Store Review (skipped: --no-auto-submit)', :cyan
                  say '=' * 80, :cyan
                  say ''
                  say '⚠️  Auto-submit disabled. The build is uploaded; finish the submission at:', :yellow
                  say '     https://appstoreconnect.apple.com/apps', :cyan
                  say ''
                end
              end

              if is_appstore && !local_only?
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
                    no_submit: false,
                    # ship appstore defaults to submitting for review, but
                    # dashboard `cli_defaults.auto_submit = false` now wins
                    # (the old hard-override that clobbered it was removed).
                    default_submit: true
                  }
                )

                # Submit the new build (use its specific build number)
                # Build metadata overrides from CLI options — start from any
                # --metadata-file + --release-notes, then layer in ship-specific
                # release_type/scheduled_date. auto_submit is NOT forced here;
                # precedence is: --auto-submit flag > cli_defaults > command default.
                ship_overrides, override_sources = build_metadata_overrides(options)
                ship_override_keys = []

                if options.key?(:auto_submit)
                  ship_overrides['auto_submit'] = options[:auto_submit]
                  ship_override_keys << 'auto_submit'
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

                override_sources << { type: :inline, keys: ship_override_keys }

                submission = Upload::AppStoreSubmission.new(
                  client,
                  config.current_organization_id,
                  {
                    bundle_id: bundle_id,
                    build_number: new_build['build_number'] # Use the specific build we found
                  },
                  metadata_overrides: ship_overrides,
                  override_sources: override_sources
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
            rescue Mysigner::Upload::AscRestUploader::BuildVersionConflictError => e
              say ''
              say "✗ #{e.message}", :red
              say ''
              exit 1
            rescue Mysigner::Upload::AscRestUploader::MissingLocalCredentialsError => e
              # mysigner-42 — local-only requested but no credentials stored.
              # Fail loud with a non-stack-trace message; the message already
              # tells the user where to store the credentials.
              say ''
              say "✗ #{e.message}", :red
              say ''
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
            # mysigner-22 — local-only equivalent of the MySigner `/apple_apps`
            # lookup. Calls Apple's /v1/apps?filter[bundleId]= directly with
            # the resolved ASC JWT and returns the matched `id` (string).
            # Honors --apple-id as an unconditional override (skip the lookup
            # entirely). Exits 1 with a clear pointer to --apple-id on zero or
            # multiple matches so the user has a one-knob fix.
            def resolve_apple_app_id_local!(bundle_id:, apple_id_override:, asc_creds:)
              return apple_id_override.to_s if apple_id_override && !apple_id_override.empty?

              require 'mysigner/auth/asc_jwt_minter'
              require 'faraday'
              require 'json'
              require 'uri'

              jwt = Mysigner::Auth::AscJwtMinter.new(
                key_id: asc_creds.key_id,
                issuer_id: asc_creds.issuer_id,
                p8_pem: asc_creds.p8_pem
              ).mint

              conn = Faraday.new(url: 'https://api.appstoreconnect.apple.com') do |f|
                f.adapter Faraday.default_adapter
              end
              resp = conn.get('/v1/apps') do |req|
                req.params['filter[bundleId]'] = bundle_id
                req.headers['Authorization'] = "Bearer #{jwt}"
              end

              unless resp.status.between?(200, 299)
                say "✗ Apple /v1/apps lookup failed for bundle_id #{bundle_id}: #{resp.status}", :red
                say "   #{resp.body}", :yellow if resp.body && !resp.body.empty?
                say '   Override with: mysigner ship appstore --local-only --apple-id <APPLE_APP_ID>', :yellow
                exit 1
              end

              data = Array(JSON.parse(resp.body)['data'])
              case data.length
              when 0
                say "✗ No App Store Connect app found for bundle_id: #{bundle_id}", :red
                say "   Make sure the app exists in App Store Connect under this team's account,", :yellow
                say '   or override with: --apple-id <APPLE_APP_ID>', :yellow
                exit 1
              when 1
                data.first['id'].to_s
              else
                ids = data.map { |a| a['id'] }.join(', ')
                say "✗ Apple returned multiple apps for bundle_id #{bundle_id} (ids: #{ids}).", :red
                say '   Pick one and re-run with: --apple-id <APPLE_APP_ID>', :yellow
                exit 1
              end
            end

            # mysigner-22 follow-up — local-only submit-for-review.
            # Mints a fresh JWT from the same local .p8 the uploader used,
            # then drives Apple's REST submission flow via AscSubmitter.
            # Translates each typed error into a one-line actionable message;
            # exits 1 on failure so the caller's success-path doesn't run.
            def submit_appstore_local!(asc_creds:, apple_app_id:, cf_bundle_version:,
                                       cf_bundle_short_version_string:)
              require 'mysigner/auth/asc_jwt_minter'
              require_relative '../upload/asc_submitter'

              say '⏳ Waiting for Apple to finish processing the build...', :yellow

              jwt = Mysigner::Auth::AscJwtMinter.new(
                key_id: asc_creds.key_id,
                issuer_id: asc_creds.issuer_id,
                p8_pem: asc_creds.p8_pem
              ).mint

              submission_id = Mysigner::Upload::AscSubmitter.new(
                jwt: jwt,
                apple_app_id: apple_app_id,
                cf_bundle_version: cf_bundle_version,
                cf_bundle_short_version_string: cf_bundle_short_version_string
              ).submit!

              say "✓ Submission created (id: #{submission_id})", :green
              say '   Monitor review status at: https://appstoreconnect.apple.com/apps', :cyan
              say ''
            rescue Mysigner::Upload::AscSubmitter::BuildProcessingTimeoutError => e
              say ''
              say "✗ #{e.message}", :red
              say ''
              say '   Tip: this is not a CLI bug — Apple is still processing your build.', :yellow
              say '   Re-run `mysigner ship appstore --local-only` once it shows', :yellow
              say '   "Ready to Submit" in App Store Connect, or finish manually:', :yellow
              say '     https://appstoreconnect.apple.com/apps', :cyan
              say ''
              exit 1
            rescue Mysigner::Upload::AscSubmitter::VersionAlreadyReleasedError => e
              say ''
              say "✗ #{e.message}", :red
              say ''
              exit 1
            rescue Mysigner::Upload::AscSubmitter::VersionInFlightError => e
              # Apple has a version for this MARKETING_VERSION that's in an
              # in-flight state (in review, rejected, etc). The error message
              # names the state and the next user action verbatim.
              say ''
              say "✗ #{e.message}", :red
              say ''
              say '   Monitor or act in App Store Connect:', :yellow
              say '     https://appstoreconnect.apple.com/apps', :cyan
              say ''
              exit 1
            rescue Mysigner::Upload::AscSubmitter::SubmissionRejectedError => e
              # Surface Apple's verbatim error body — usually missing metadata
              # (description, what's new, screenshots). We don't pretend to
              # auto-populate metadata; the user owns it in App Store Connect.
              say ''
              say "✗ Apple rejected the submission: #{e.message}", :red
              say ''
              say '   Missing required metadata is the most common cause.', :yellow
              say '   Finish the listing at: https://appstoreconnect.apple.com/apps', :cyan
              say ''
              exit 1
            rescue Mysigner::Upload::AscSubmitter::AppleApiError => e
              say ''
              say "✗ App Store Connect API error: #{e.message}", :red
              say ''
              exit 1
            end

            # Ship Android to Google Play
            def ship_android(track)
              # mysigner-43 — when the user opts into local-only for `ship
              # android`, surface the banner once so they know their SA-JSON
              # won't traverse the MySigner server. The uploader itself
              # enforces the contract below.
              emit_local_only_banner if local_only?

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

                # Check highest version code from API and auto-increment if needed.
                # mysigner-22 follow-up — local-only mode now also runs the
                # pre-check via Google Play directly (no MySigner round-trip):
                # mint an OAuth2 token from local SA-JSON, list bundles on the
                # app, take max(versionCode). Unlike vault mode we DO NOT
                # auto-bump the AAB — that's the user's project state. We just
                # warn so they can bump versionCode in their Gradle file and
                # re-run rather than burn 3 minutes on a doomed upload.
                #
                # Best-effort: if the mint fails (network, mock, expired key)
                # we skip the pre-check rather than fail the ship. Google will
                # still reject at upload time with a clear message.
                highest_version_code =
                  if local_only?
                    fetch_local_only_highest_version_code(package_name: package_name)
                  else
                    fetch_android_highest_version_code(client, config, package_name)
                  end
                version_code = local_version_code
                version_code_override = nil

                if local_only? && highest_version_code && local_version_code <= highest_version_code
                  # Local-only: warn-only. Bumping the AAB's versionCode
                  # would silently mutate the user's project state, which
                  # the brief is explicit we should not do.
                  say ''
                  say "[mysigner] Your project's versionCode (#{local_version_code}) is ≤ Google Play's latest (#{highest_version_code}).", :red
                  say "Google will reject this upload. Bump versionCode to #{highest_version_code + 1} or higher in", :red
                  say 'android/app/build.gradle and re-run.', :red
                  say ''
                  exit 1
                elsif highest_version_code && local_version_code <= highest_version_code
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

                # mysigner-22 Phase 7 — local-only mode resolves the keystore
                # via the credential cascade (flag → env → keychain → project
                # sniff → prompt). The MySigner server is never contacted for
                # the .jks blob, passwords, or alias. In vault mode the old
                # KeystoreManager path runs unchanged.
                active_keystore = nil
                keystore_path = nil
                keystore_password = nil
                key_password = nil
                key_alias = nil

                if local_only?
                  say '🔐 Resolving Android keystore locally (--local-only)...', :yellow
                  android_creds = resolve_local_android_keystore_or_exit
                  keystore_path = android_creds.keystore_path
                  keystore_password = android_creds.keystore_password
                  key_password = android_creds.key_password || keystore_password
                  key_alias = android_creds.key_alias
                  # Hold the tmpfile (if any) on a local so GC can't unlink
                  # the materialized .jks mid-build. The local goes out of
                  # scope when ship_android returns, which is fine — the
                  # build/upload have both consumed the file by then.
                  _keystore_tmpfile_hold = android_creds.tmpfile
                  say "✓ Keystore ready at: #{keystore_path} (source: #{android_creds.source})", :green
                  say ''
                else
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

                  active_keystore = keystore_manager.active_keystore(android_app_id: app_id)
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
                  keystore_path = keystore_info[:path]
                  say "✓ Keystore ready at: #{keystore_path}", :green
                  say ''

                  # mysigner-49: passwords are never returned inline on the
                  # active_keystore (list) payload. Fetch them through the
                  # dedicated, audit-logged /secrets endpoint instead. ENV
                  # vars remain a manual override for power users.
                  secrets = keystore_manager.fetch_secrets(active_keystore['id'])
                  keystore_password = secrets['keystore_password'] || ENV.fetch('MYSIGNER_KEYSTORE_PASSWORD', nil)
                  key_password = secrets['key_password'] || ENV['MYSIGNER_KEY_PASSWORD'] || keystore_password
                  key_alias = secrets['key_alias'] || active_keystore['key_alias']

                  unless keystore_password
                    say '⚠️  Keystore password not found in My Signer', :yellow
                    say '    Upload your keystore with password: mysigner keystore upload FILE', :yellow
                    keystore_password = ask('Keystore password:', echo: false)
                    say ''
                    key_password ||= keystore_password
                  end
                end

                # Build AAB
                require_relative '../build/android_executor'
                executor = Build::AndroidExecutor.new(project_info, parser)

                aab_path = executor.build_aab!(
                  variant: 'release',
                  keystore_path: keystore_path,
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

                # Phase 0: mint short-lived OAuth2 access token server-side.
                # Service-account JSON never leaves the server.
                #
                # mysigner-43: in local-only mode the token is minted *inside*
                # PlayStoreUploader from Keychain-backed SA-JSON. Skip the
                # server round-trip entirely.
                access_token = nil
                if local_only?
                  say '🔐 Local-only mode — will mint Google Play access token locally.', :yellow
                else
                  say '🔐 Requesting Google Play access token...', :yellow

                  begin
                    token_response = client.post(
                      "/api/v1/organizations/#{config.current_organization_id}/credentials/google_play/access_token"
                    )
                    access_token = token_response[:data]['access_token']
                  rescue Mysigner::NotFoundError, Mysigner::ValidationError
                    say ''
                    say '✗ Google Play credentials not configured', :red
                    say ''
                    say 'Quick fix:', :cyan
                    say '  Configure Google Play credentials in My Signer dashboard', :green
                    say ''
                    exit 1
                  end

                  if access_token.nil? || access_token.to_s.empty?
                    say '✗ Error: Failed to mint Google Play access token', :red
                    exit 1
                  end

                  say '✓ Access token minted (valid ~1 hour)', :green
                end
                say ''

                # Phase 0: fetch Android CLI Defaults from the dashboard
                # (android_apps.cli_defaults JSONB). Fields here act as base
                # values; explicit CLI flags below layer on top.
                # mysigner-22 Phase 7 — local-only mode bypasses dashboard
                # defaults; the user supplies everything via flags or accepts
                # the built-in defaults below.
                android_defaults =
                  if local_only?
                    warn '[mysigner] local-only: skipping fetch_android_release_defaults (server-only feature; using CLI flags + defaults)'
                    nil
                  else
                    fetch_android_release_defaults(client, config, package_name)
                  end
                if android_defaults
                  say "✓ Loaded CLI Defaults for #{package_name}", :green
                  say ''
                end

                # Upload to Google Play with bare bearer token
                require_relative '../upload/play_store_uploader'

                # Merge release notes: flag > defaults.release_notes (Hash)
                release_notes = nil
                if options[:release_notes]
                  release_notes = { 'en-US' => options[:release_notes] }
                elsif android_defaults && android_defaults['release_notes'].is_a?(Hash) && android_defaults['release_notes'].any?
                  release_notes = android_defaults['release_notes']
                end

                # Effective track: positional arg wins; defaults only kick in
                # if the user left it implicit (which `ship android` currently
                # doesn't allow — track is required — but kept here for
                # symmetry with submit_android and future-proofing).
                effective_track = (track && !track.empty? ? track : nil) || android_defaults&.dig('default_track') || 'internal'

                status = android_defaults&.dig('default_status')
                user_fraction = android_defaults&.dig('default_user_fraction')
                in_app_update_priority = android_defaults&.dig('default_in_app_update_priority')
                release_name = android_defaults&.dig('release_name')
                country_targeting = android_defaults&.dig('country_targeting')
                changes_not_sent_for_review = android_defaults&.key?('changes_not_sent_for_review') ? android_defaults['changes_not_sent_for_review'] : nil
                country_targeting = country_targeting.transform_keys(&:to_sym) if country_targeting.is_a?(Hash)

                # mysigner-22 Phase 5 — pre-resolve Play creds via the
                # cascade (flag → env → keychain → project-sniff → prompt).
                # In vault mode this is nil and the existing access_token
                # round-trip is unchanged.
                play_creds_for_uploader = (resolve_local_play_creds_or_exit if local_only?)

                uploader = Upload::PlayStoreUploader.new(
                  aab_path: aab_path,
                  access_token: access_token,
                  package_name: package_name,
                  local_only: local_only?,
                  play_creds: play_creds_for_uploader
                )

                uploader.upload!(
                  track: effective_track,
                  release_notes: release_notes,
                  user_fraction: user_fraction,
                  status: status,
                  in_app_update_priority: in_app_update_priority,
                  release_name: release_name,
                  country_targeting: country_targeting,
                  changes_not_sent_for_review: changes_not_sent_for_review
                )

                timings[:upload] = Time.now - upload_start
                timings[:total] = Time.now - overall_start

                # Link keystore to app in MySigner (so dashboard shows it).
                # mysigner-22 Phase 7 — local-only mode never has an
                # active_keystore record (the .jks came from the user's
                # machine, not MySigner), so the link step is unconditionally
                # skipped here. Surface it so users know the dashboard won't
                # auto-update.
                if local_only?
                  warn '[mysigner] local-only: skipping android_keystores/:id/link_to_app (server-only feature)'
                elsif active_keystore && active_keystore['id']
                  begin
                    client.post(
                      "/api/v1/organizations/#{config.current_organization_id}/android_keystores/#{active_keystore['id']}/link_to_app",
                      body: { package_name: package_name }
                    )
                  rescue StandardError => e
                    # Non-fatal, continue
                  end
                end

                # Save build record to MySigner (for version tracking).
                # mysigner-22 Phase 7 — local-only mode has no MySigner
                # record to update; skip and warn.
                if local_only?
                  warn '[mysigner] local-only: skipping save_android_build_record (server-only feature)'
                else
                  save_android_build_record(client, config, package_name, version_code, version_name)
                end

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
              rescue Upload::PlayStoreUploader::MissingLocalCredentialsError => e
                # mysigner-43 — local-only requested but no credentials stored.
                # Fail loud with a non-stack-trace message; the message already
                # tells the user where to store the credentials.
                say ''
                say "✗ #{e.message}", :red
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

                # Save build record even on partial failure (AAB is on Play Store).
                # mysigner-22 Phase 7 — skip the server write in local-only mode.
                if e.version_code && !local_only?
                  save_android_build_record(client, config, package_name, e.version_code, version_name)
                  say "📝 Build v#{e.version_code} recorded (prevents version conflicts on retry)", :yellow
                  say ''
                elsif e.version_code && local_only?
                  warn '[mysigner] local-only: skipping save_android_build_record on partial-upload retry path'
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

            # Fetch Android CLI Defaults (android_apps.cli_defaults) for the
            # package_name. Returns nil if none configured or request fails —
            # ship proceeds with CLI-flag-only values in that case.
            def fetch_android_release_defaults(client, config, package_name)
              response = client.get(
                "/api/v1/organizations/#{config.current_organization_id}/android_releases",
                params: { package_name: package_name }
              )
              data = response[:data] if response[:success]
              return nil unless data.is_a?(Hash)

              releases = data['android_releases']
              return nil unless releases.is_a?(Array) && releases.any?

              releases.first
            rescue Mysigner::NotFoundError
              nil
            rescue StandardError => e
              # Non-fatal: log and proceed without defaults.
              puts "⚠️  Could not fetch Android CLI Defaults: #{e.message}" if ENV['MYSIGNER_VERBOSE'] == '1'
              nil
            end

            # mysigner-22 follow-up — local-only equivalent of
            # fetch_android_highest_version_code. Resolves Play creds via the
            # cascade, mints an OAuth2 token, and asks Google Play directly.
            # Best-effort: any failure (mint error, network, list error)
            # returns nil so the ship proceeds — Google will still reject at
            # upload time with a clear message, but a transient pre-check
            # failure shouldn't block the user.
            def fetch_local_only_highest_version_code(package_name:)
              require 'mysigner/auth/google_oauth_minter'

              play_creds = resolve_local_play_creds_or_exit
              token = Mysigner::Auth::GoogleOauthMinter.new(play_creds.sa_json)
                                                       .mint(scope: Upload::PlayStoreUploader::SCOPE)
              Upload::PlayStoreUploader.fetch_highest_version_code(
                package_name: package_name,
                access_token: token
              )
            rescue StandardError => e
              warn "[mysigner] local-only: skipping versionCode pre-check (#{e.class}: #{e.message})"
              nil
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

                # Phase 0: mint short-lived access token server-side; JSON stays on server
                say '🔐 Requesting Google Play access token...', :yellow

                begin
                  token_response = client.post(
                    "/api/v1/organizations/#{config.current_organization_id}/credentials/google_play/access_token"
                  )
                  access_token = token_response[:data]['access_token']
                rescue Mysigner::NotFoundError, Mysigner::ValidationError
                  say ''
                  say '✗ Google Play credentials not configured', :red
                  say ''
                  say 'Configure Google Play credentials in My Signer dashboard', :cyan
                  exit 1
                end

                if access_token.nil? || access_token.to_s.empty?
                  say '✗ Error: Failed to mint Google Play access token', :red
                  exit 1
                end

                say '✓ Access token minted', :green
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

                # Use the Google API directly with the bare bearer token for track assignment
                require 'google/apis/androidpublisher_v3'

                service = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
                service.authorization = access_token

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
            require_macos!('build')
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

              # Validate bundle ID format if overridden (skip empty to let executor handle)
              if options[:bundle_id] && !options[:bundle_id].empty?
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
              validator = Signing::Validator.new(parser, target_name, options[:configuration],
                                                 team_id: team_id_to_use, local_only: local_only?)
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
            require_macos!('export')
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
            require_macos!('upload testflight')
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

              # ASC REST Build Upload API.
              require_relative '../upload/asc_rest_uploader'

              ipa_info = Upload::Uploader.extract_ipa_info(ipa_path)
              bundle_id = ipa_info[:bundle_id]
              cf_version = ipa_info[:cf_bundle_version] || '1'
              cf_short   = ipa_info[:cf_bundle_short_version_string] || '1.0'

              if bundle_id.nil? || bundle_id.empty?
                say '✗ Could not extract bundle identifier from IPA.', :red
                say '  Ensure the file is a valid iOS .ipa with a Payload/*.app/Info.plist.', :yellow
                exit 1
              end

              app_response = client.get("/api/v1/organizations/#{config.current_organization_id}/apple_apps",
                                        params: { bundle_id: bundle_id })
              app = Array(app_response.dig(:data, 'data', 'apps')).first

              unless app && app['id']
                say "✗ App with bundle ID '#{bundle_id}' not found in MySigner.", :red
                say '  Run: mysigner sync ios', :yellow
                exit 1
              end

              say "📤 Uploading #{File.basename(ipa_path)} via App Store Connect REST API (version #{cf_short} build #{cf_version})...", :cyan

              rest = Mysigner::Upload::AscRestUploader.new(
                client: client,
                organization_id: config.current_organization_id,
                ipa_path: ipa_path,
                apple_app_id: app['id'],
                cf_bundle_version: cf_version,
                cf_bundle_short_version_string: cf_short,
                platform: 'IOS'
              )

              result = rest.call
              case result[:final_state]
              when 'COMPLETE'
                say '✓ Upload complete — Apple accepted the build', :green
              when 'FAILED', 'INVALIDATED'
                say "✗ Apple rejected the upload: #{result[:final_state]}", :red
                exit 1
              when 'TIMEOUT'
                say '⚠ Apple is still processing — check App Store Connect.', :yellow
              end

              say '🎉 Upload complete!', :green
              say ''
              say 'Next steps:', :cyan
              say '  • Open App Store Connect to see your build'
              say '  • Wait for processing (5-15 minutes)'
              say '  • Distribute to TestFlight testers'
              say ''
            rescue Mysigner::Upload::AscRestUploader::BuildVersionConflictError => e
              say ''
              say "✗ #{e.message}", :red
              say ''
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
          method_option :auto_submit, type: :boolean,
                                      desc: 'Submit for review. Defaults to dashboard CLI Defaults, else true. Use --no-auto-submit to skip.'
          def submit(track = nil)
            exit_unless_local_supported!('submit')

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
                  no_submit: false,
                  # `mysigner submit` without --auto-submit/--no-auto-submit
                  # defaults to submitting; cli_defaults.auto_submit=false can
                  # still suppress it.
                  default_submit: true
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

              # `mysigner submit` defaults to submitting (see AppStoreAutomation
              # opts[:default_submit]=true above) but no longer hard-clobbers
              # the user's dashboard `cli_defaults.auto_submit = false`.
              # Precedence: --auto-submit flag > cli_defaults > command default.
              metadata_overrides = {}
              override_keys = []

              if options.key?(:auto_submit)
                metadata_overrides['auto_submit'] = options[:auto_submit]
                override_keys << 'auto_submit'
              end

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
