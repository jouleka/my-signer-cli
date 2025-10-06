module Mysigner
  class CLI < Thor
    module BuildCommands
      def self.included(base)
        base.class_eval do
          desc "ship testflight", "Build, export, and upload to TestFlight (one command!)"
          method_option :configuration, aliases: '-c', default: 'Release', desc: 'Build configuration'
          method_option :scheme, aliases: '-s', desc: 'Scheme to build (auto-detect if not specified)'
          method_option :wait, type: :boolean, default: false, desc: 'Wait for processing to complete'
          def ship(target)
            unless target == 'testflight'
              error "Only 'testflight' target is supported currently"
              exit 1
            end

            config = load_config
            client = create_client(config)
            
            overall_start = Time.now
            timings = {}
            archive_path = nil
            ipa_path = nil
            project_name = nil
            bundle_id = nil

            say "🚀 My Signer - Ship to TestFlight", :cyan
            say "=" * 80, :cyan
            say ""
            say "This will:", :bold
            say "  1️⃣  Detect and build your project"
            say "  2️⃣  Export IPA for App Store"
            say "  3️⃣  Upload to TestFlight"
            say ""
            say "⏱️  Estimated time: 3-7 minutes", :yellow
            say ""

            begin
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
              bundle_id = parser.bundle_id(target_name, options[:configuration])
              
              say "🎯 Target: #{target_name}", :cyan
              say "📦 Bundle ID: #{bundle_id}", :cyan
              say "⏱️  Estimated: 2-5 minutes", :yellow
              say ""
              
              executor = Build::Executor.new(project_info, parser)
              archive_path = executor.build!(
                target_name, 
                options[:configuration], 
                scheme: options[:scheme],
                signing_style: parser.code_sign_style(target_name, options[:configuration])
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
              say "[3/3] Uploading to TestFlight", :cyan
              say "=" * 80, :cyan
              say ""
              say "⏱️  Estimated: 1-3 minutes", :yellow
              say ""
              
              upload_start = Time.now

              # Fetch App Store Connect credentials
              say "🔐 Fetching App Store Connect credentials...", :yellow
              
              org_response = client.get("/api/v1/organizations/#{config.organization_id}")
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
              timings[:total] = Time.now - overall_start

              # SUCCESS SUMMARY!
              say ""
              say "=" * 80, :green
              say "🎉 SUCCESS! Your app is on TestFlight!", :green
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
              say "  3. Add testers and distribute via TestFlight"
              say ""

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

          desc "build", "Build iOS archive from current project"
          method_option :configuration, aliases: '-c', default: 'Release', desc: 'Build configuration (Debug, Release, etc.)'
          method_option :target, aliases: '-t', desc: 'Target to build (auto-detect if not specified)'
          method_option :scheme, aliases: '-s', desc: 'Scheme to build (defaults to target name)'
          method_option :type, default: 'appstore', desc: 'Build type: development, adhoc, appstore, enterprise'
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
              target_name = options[:target] || parser.main_target.name
              
              say "🎯 Target: #{target_name}", :cyan
              
              bundle_id = parser.bundle_id(target_name, options[:configuration])
              say "📦 Bundle ID: #{bundle_id}", :cyan
              say "⚙️  Configuration: #{options[:configuration]}", :cyan
              
              # Check signing style
              sign_style = parser.code_sign_style(target_name, options[:configuration])
              say "🔐 Signing: #{sign_style || 'Not Set'}", :cyan
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
                  
                  configurator = Build::Configurator.new(parser, client, config.organization_id)
                  build_type = options[:type].to_sym
                  
                  profile = configurator.configure!(target_name, options[:configuration], build_type: build_type)
                  
                  say "✓ Configured with profile: #{profile['name']}", :green
                  say ""
                end
              else
                # No signing style set, default to configuring manual signing
                say "🔐 Configuring manual signing via My Signer API...", :cyan
                
                configurator = Build::Configurator.new(parser, client, config.organization_id)
                build_type = options[:type].to_sym
                
                profile = configurator.configure!(target_name, options[:configuration], build_type: build_type)
                
                say "✓ Configured with profile: #{profile['name']}", :green
                say ""
              end

              # Build
              executor = Build::Executor.new(project_info, parser)
              archive_path = executor.build!(
                target_name, 
                options[:configuration], 
                scheme: options[:scheme],
                signing_style: sign_style
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
                org_response = client.get("/api/v1/organizations/#{config.organization_id}")
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
        end
      end
    end
  end
end
