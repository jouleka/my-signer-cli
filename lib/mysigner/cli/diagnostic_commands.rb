module Mysigner
  class CLI < Thor
    module DiagnosticCommands
      def self.included(base)
        base.class_eval do
          desc "doctor", "🩺 Run health check and diagnose setup issues (run this if stuck)"
          method_option :platform, type: :string, desc: 'Check specific platform only: ios, android, or all (default)'
          def doctor
            say "🩺 My Signer Health Check", :cyan
            say "=" * 80, :cyan
            say ""
            
            issues = []
            warnings = []
            
            # Determine which platforms to check
            platform_filter = options[:platform]&.downcase
            check_ios = platform_filter.nil? || platform_filter == 'all' || platform_filter == 'ios'
            check_android = platform_filter.nil? || platform_filter == 'all' || platform_filter == 'android'

            if platform_filter && !%w[ios android all].include?(platform_filter)
              error "Invalid platform: #{platform_filter}"
              say "Valid options: ios, android, all", :yellow
              exit 1
            end

            # Check 1: Xcode (iOS only)
            if check_ios
            say "Checking Xcode...", :yellow
            if system('which xcodebuild > /dev/null 2>&1')
              xcode_version = `xcodebuild -version`.lines.first.strip rescue "Unknown"
              say "  ✓ Xcode installed: #{xcode_version}", :green
            else
              say "  ✗ Xcode not found", :red
              issues << "Xcode is not installed or not in PATH"
            end
            say ""
            
            # Check 2: Command Line Tools
            say "Checking Command Line Tools...", :yellow
            if system('xcode-select -p > /dev/null 2>&1')
              say "  ✓ Command Line Tools installed", :green
            else
              say "  ✗ Command Line Tools not found", :red
              issues << "Install with: xcode-select --install"
            end
            say ""
            
            # Check 3: xcrun altool
            say "Checking upload tools...", :yellow
            if system('xcrun --find altool > /dev/null 2>&1')
              say "  ✓ xcrun altool available", :green
            else
              say "  ⚠️  xcrun altool not found", :yellow
              warnings << "altool not available (upload may fail)"
            end
            
            # Check for iTMSTransporter
            transporter_paths = [
              '/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter',
              '/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter'
            ]
            transporter_found = transporter_paths.any? { |path| File.exist?(path) }
            
            if transporter_found
              say "  ✓ iTMSTransporter available (fallback)", :green
            else
              say "  ⚠️  iTMSTransporter not found (optional)", :yellow
            end
            say ""
            
            # Check 4: My Signer Configuration
            say "Checking My Signer configuration...", :yellow
            config = Config.new
            client = nil
            org_data = nil
            
            if config.exists?
              config.load
              say "  ✓ Logged in", :green
              
              begin
                client = Client.new(api_url: config.api_url, api_token: config.api_token)
                client.test_connection
                say "  ✓ API connection working", :green
                
                # Get organization details
                if config.current_organization_id
                  org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                  org_data = org_response[:data]
                end
              rescue Mysigner::UnauthorizedError
                say "  ✗ Token is invalid or expired", :red
                issues << "Token authentication failed - run 'mysigner onboard' to re-authenticate"
                client = nil
              rescue Mysigner::ConnectionError => e
                say "  ✗ Cannot connect to API: #{e.message}", :red
                issues << "API connection failed - check your network or API URL"
                client = nil
              rescue => e
                say "  ✗ API error: #{e.message}", :red
                issues << "API connection failed - check your configuration"
                client = nil
              end
            else
              say "  ✗ Not logged in", :red
              issues << "Run 'mysigner onboard' to authenticate"
            end
            say ""
            
            # Check 4a: Signing Identity in Keychain (CRITICAL)
            if client && org_data && org_data['app_store_connect_team_id']
              say "Checking signing identity for team...", :yellow
              team_id = org_data['app_store_connect_team_id']
              
              # Check if signing identities exist in keychain for this team
              identities = `security find-identity -v -p codesigning 2>/dev/null | grep -i "#{team_id}"`
              has_identity = $?.success? && !identities.strip.empty?
              
              if has_identity
                say "  ✓ Signing identity found for team #{team_id}", :green
              else
                say "  ✗ No signing identity for team #{team_id}", :red
                say ""
                say "  CRITICAL: You need to sign into Xcode and download certificates:", :red
                say "    1. Open Xcode → Settings → Accounts", :yellow
                say "    2. Verify you're signed in with your Apple ID", :yellow
                say "    3. Select team '#{team_id}'", :yellow
                say "    4. Click 'Download Manual Profiles' (or 'Manage Certificates')", :yellow
                say "    5. The certificate should appear in keychain", :yellow
                say ""
                issues << "No signing identity for team #{team_id} in keychain"
              end
              say ""
            end
            
            # Check 4b: App Store Connect Credentials (with auto-fix)
            if client && org_data
              say "Checking App Store Connect credentials...", :yellow
              creds_status = org_data['credentials_status'] || {}
              
              if creds_status['needs_setup'] || !org_data['app_store_connect_configured']
                say "  ✗ App Store Connect not configured", :red
                say ""
                
                if yes_with_default?("Would you like to set it up now?", :green)
                  say ""
                  # Call the setup helper (available from AuthCommands module)
                  if respond_to?(:setup_app_store_connect_credentials, true)
                    asc_configured = setup_app_store_connect_credentials(client, config, config.current_organization_id)
                  else
                    say "  ✗ Setup helper not available", :red
                    say "  Please run 'mysigner onboard' instead", :yellow
                    asc_configured = false
                  end
                  
                  if asc_configured
                    say ""
                    say "  ✓ App Store Connect configured successfully!", :green
                    say ""
                    # Refresh org data
                    org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                    org_data = org_response[:data]
                  else
                    say ""
                    issues << "App Store Connect setup incomplete - run 'mysigner onboard' to try again"
                  end
                else
                  issues << "App Store Connect not configured - run 'mysigner onboard' to set it up"
                end
              elsif !creds_status['team_id_set']
                say "  ⚠️  Team ID not set", :yellow
                warnings << "Team ID missing - may cause issues. Re-sync to extract it."
              else
                say "  ✓ App Store Connect configured", :green
                if org_data['app_store_connect_team_id']
                  say "    Team ID: #{org_data['app_store_connect_team_id']}", :cyan
                end
              end
              say ""
            end
            
            # Check 5: Xcode License Agreement
            say "Checking Xcode license...", :yellow
            begin
              license_check = `sudo -n xcodebuild -checkFirstLaunchStatus 2>&1`
              license_status = $?.success?
              
              if license_status
                say "  ✓ Xcode license accepted", :green
              else
                # Check if it's a permission issue or actual license issue
                if license_check.include?("password") || license_check.include?("sudo")
                  say "  ℹ️  Cannot check license (needs sudo)", :cyan
                else
                  say "  ⚠️  Xcode license may not be accepted", :yellow
                  say "    Run: sudo xcodebuild -license accept", :cyan
                  warnings << "Xcode license may need acceptance"
                end
              end
            rescue
              say "  ℹ️  Could not check Xcode license", :cyan
            end
            say ""
            
            # Check 6: Disk Space
            say "Checking disk space...", :yellow
            begin
              df_output = `df -h . 2>/dev/null | tail -1`.strip
              if df_output =~ /(\d+)%/
                usage = $1.to_i
                if usage > 95
                  say "  ✗ Critical: Disk space very low (#{usage}% used)", :red
                  issues << "Free up disk space before building"
                elsif usage > 90
                  say "  ⚠️  Low disk space: #{usage}% used", :yellow
                  warnings << "Low disk space may cause build failures"
                else
                  say "  ✓ Sufficient disk space: #{usage}% used", :green
                end
              else
                say "  ⚠️  Could not check disk space", :yellow
              end
            rescue
              say "  ⚠️  Could not check disk space", :yellow
            end
            say ""
            
            # Check 7: Network Connectivity
            say "Checking network connectivity...", :yellow
            begin
              require 'socket'
              Socket.tcp("apple.com", 443, connect_timeout: 5) { |sock| sock.close }
              say "  ✓ Internet connection working", :green
            rescue => e
              say "  ✗ No internet connection", :red
              issues << "Cannot reach Apple servers - check your network connection"
            end
            say ""
            
            # Check 8: Project Detection (if in a project directory)
            say "Checking current directory...", :yellow
            project_info = nil
            begin
              project_info = Build::Detector.detect
              framework = case project_info[:framework]
              when :capacitor then "Capacitor/Ionic"
              when :react_native then "React Native"
              when :flutter then "Flutter"
              else "Native iOS"
              end
              say "  ✓ Found #{framework} project: #{File.basename(project_info[:path])}", :green
            rescue
              say "  ℹ️  No project detected in current directory", :cyan
            end
            say ""
            
            # Check 9: Organization Resources Health (if logged in)
            if client && org_data && org_data['app_store_connect_configured']
              say "Checking organization resources...", :yellow
              
              stats = org_data['stats'] || {}
              
              # Check certificates
              certs_count = stats['certificates_count'] || 0
              if certs_count == 0
                say "  ⚠️  No certificates synced", :yellow
                warnings << "Run sync in web dashboard to fetch certificates from Apple"
              else
                say "  ✓ Certificates: #{certs_count}", :green
              end
              
              # Check devices
              devices_count = stats['devices_count'] || 0
              if devices_count == 0
                say "  ⚠️  No devices registered", :yellow
                warnings << "Add devices for development/adhoc builds"
              else
                say "  ✓ Devices: #{devices_count}", :green
              end
              
              # Check bundle IDs
              bundle_ids_count = stats['bundle_ids_count'] || 0
              if bundle_ids_count == 0
                say "  ⚠️  No bundle IDs synced", :yellow
                say "    This is normal for new accounts", :cyan
              else
                say "  ✓ Bundle IDs: #{bundle_ids_count}", :green
              end
              
              # Check profiles
              profiles_count = stats['profiles_count'] || 0
              invalid_profiles = stats['invalid_profiles_count'] || 0
              
              if profiles_count == 0
                say "  ⚠️  No provisioning profiles", :yellow
                warnings << "Create profiles for your projects"
              elsif invalid_profiles > 0
                say "  ✓ Profiles: #{profiles_count} (⚠️  #{invalid_profiles} invalid)", :yellow
                warnings << "#{invalid_profiles} profile(s) invalid - may need regeneration"
              else
                say "  ✓ Profiles: #{profiles_count}", :green
              end
              
              say ""
            end
            
            # Check 10: Project Signing Setup (if project detected and logged in)
            if project_info && client && org_data && org_data['app_store_connect_configured']
              say "Checking project signing setup...", :yellow
              
              begin
                parser = Build::Parser.new(project_info)
                main_target = parser.main_target
                
                if main_target
                  target_name = main_target.name
                  bundle_id = parser.bundle_id(target_name, 'Release')
                  
                  say "  Project: #{target_name}", :cyan
                  say "  Bundle ID: #{bundle_id}", :cyan
                  say ""
                  
                  # First check if bundle ID is registered
                  say "  Checking bundle ID registration...", :yellow
                  
                  bundle_ids_response = client.get(
                    "/api/v1/organizations/#{config.current_organization_id}/bundle_ids",
                    params: { q: bundle_id }
                  )
                  
                  bundle_id_exists = (bundle_ids_response[:data]['bundle_ids'] || []).any? do |bid|
                    bid['identifier'] == bundle_id
                  end
                  
                  if !bundle_id_exists
                    say "  ✗ Bundle ID '#{bundle_id}' not registered in App Store Connect", :red
                    say ""
                    
                    # Show what bundle IDs ARE registered
                    all_bundle_ids = bundle_ids_response[:data]['bundle_ids'] || []
                    if all_bundle_ids.any?
                      say "  Registered bundle IDs in your organization:", :cyan
                      all_bundle_ids.first(5).each do |bid|
                        say "    • #{bid['identifier']}", :cyan
                      end
                      if all_bundle_ids.length > 5
                        say "    ... and #{all_bundle_ids.length - 5} more", :cyan
                      end
                      say ""
                    end
                    
                    say "  Options:", :yellow
                    say "    A. Register '#{bundle_id}' in App Store Connect:", :yellow
                    say "       1. Go to: https://developer.apple.com/account/resources/identifiers/add", :cyan
                    say "       2. Select 'App IDs'", :cyan
                    say "       3. Register: #{bundle_id}", :cyan
                    say "       4. Sync in web dashboard", :cyan
                    say "       5. Run 'mysigner doctor' again", :cyan
                    say ""
                    say "    B. Or change your Xcode project to use an existing bundle ID", :yellow
                    say ""
                    issues << "Bundle ID #{bundle_id} not registered in App Store Connect"
                  else
                    say "  ✓ Bundle ID registered", :green
                    
                    # Check if profiles exist for this bundle ID
                    say "  Checking provisioning profiles...", :yellow
                    
                    profiles_response = client.get(
                      "/api/v1/organizations/#{config.current_organization_id}/profiles",
                      params: { bundle_id: bundle_id }
                    )
                    
                    profiles = profiles_response[:data]['profiles'] || []
                    
                    # Check for App Store profile
                    appstore_profiles = profiles.select { |p| p['profile_type'] == 'IOS_APP_STORE' && p['state'] == 'ACTIVE' }
                    
                    if appstore_profiles.empty?
                      say "  ✗ No App Store provisioning profile for #{bundle_id}", :red
                      say ""
                      
                      if yes_with_default?("Create App Store profile automatically?", :green)
                        say ""
                        auto_create_profile(client, config, bundle_id, 'appstore')
                      else
                        issues << "Missing App Store profile for #{bundle_id} - run 'mysigner signing configure'"
                      end
                    else
                      say "  ✓ App Store provisioning profile exists", :green
                      
                      # Check if expired
                      expired = appstore_profiles.select do |p|
                        expires_at = Time.parse(p['expires_at']) rescue nil
                        expires_at && expires_at < Time.now
                      end
                      
                      if expired.any?
                        say "  ⚠️  #{expired.length} profile(s) expired", :yellow
                        warnings << "Some profiles are expired - sync to refresh"
                      end
                    end
                    
                    # Check for development profile (helpful for testing)
                    dev_profiles = profiles.select { |p| p['profile_type'] == 'IOS_APP_DEVELOPMENT' && p['state'] == 'ACTIVE' }
                    
                    if dev_profiles.empty?
                      say "  ⚠️  No Development profile (optional but recommended)", :yellow
                      say ""
                      say "  📱 Development profiles let you:", :cyan
                      say "    • Test your app on physical devices (iPhone/iPad)", :cyan
                      say "    • Debug before uploading to TestFlight", :cyan
                      say "    • Share with your team for testing", :cyan
                      say ""
                      
                      if yes_with_default?("Create Development profile for local testing?", :yellow)
                        say ""
                        auto_create_profile(client, config, bundle_id, 'development')
                      else
                        warnings << "No development profile - you won't be able to test on devices"
                      end
                    else
                      say "  ✓ Development profile exists", :green
                    end
                  end
                end
              rescue => e
                say "  ⚠️  Could not check project signing: #{e.message}", :yellow
                warnings << "Project signing check failed"
              end
              say ""
            elsif project_info && (!client || !org_data)
              say "⚠️  Project detected but cannot check signing (not logged in)", :yellow
              say ""
            end
            end # end of check_ios block

            # ==================== ANDROID CHECKS ====================
            if check_android
            say "Checking Android development environment...", :yellow
            android_available = false

            # Check 11: Java/JDK
            if system('which java > /dev/null 2>&1')
              java_version = `java -version 2>&1`.lines.first.strip rescue "Unknown"
              say "  ✓ Java installed: #{java_version}", :green
              android_available = true
              
              # Check JAVA_HOME validity
              java_home = ENV['JAVA_HOME']
              if java_home && !java_home.empty?
                if Dir.exist?(java_home)
                  say "  ✓ JAVA_HOME: #{java_home}", :green
                else
                  say "  ✗ JAVA_HOME invalid: #{java_home}", :red
                  
                  # Try to auto-detect correct JAVA_HOME
                  detected_java_home = detect_java_home
                  if detected_java_home
                    say "  💡 Detected valid Java at: #{detected_java_home}", :yellow
                    say ""
                    if yes_with_default?("  Would you like to fix JAVA_HOME in your shell config?", :green)
                      fix_java_home(detected_java_home)
                    else
                      say "  To fix manually, add to ~/.zshrc:", :yellow
                      say "    export JAVA_HOME=#{detected_java_home}", :cyan
                      issues << "JAVA_HOME points to non-existent directory"
                    end
                  else
                    issues << "JAVA_HOME points to non-existent directory and no Java found"
                  end
                end
              else
                # JAVA_HOME not set - try to detect and suggest
                detected_java_home = detect_java_home
                if detected_java_home
                  say "  ⚠️  JAVA_HOME not set", :yellow
                  say "  💡 Detected Java at: #{detected_java_home}", :yellow
                  say ""
                  if yes_with_default?("  Would you like to set JAVA_HOME in your shell config?", :green)
                    fix_java_home(detected_java_home)
                  else
                    warnings << "JAVA_HOME not set (recommended: export JAVA_HOME=#{detected_java_home})"
                  end
                else
                  say "  ⚠️  JAVA_HOME not set", :yellow
                end
              end
            else
              say "  ℹ️  Java not found (required for Android)", :cyan
            end

            # Check 12: Android SDK
            android_home = ENV['ANDROID_HOME'] || ENV['ANDROID_SDK_ROOT']
            if android_home && Dir.exist?(android_home)
              say "  ✓ Android SDK: #{android_home}", :green
              android_available = true
            else
              say "  ℹ️  Android SDK not found (set ANDROID_HOME)", :cyan
            end

            # Check 13: Gradle
            if system('which gradle > /dev/null 2>&1') || (android_home && File.exist?("#{android_home}/../gradle"))
              gradle_version = `gradle --version 2>&1 | grep 'Gradle '`.strip rescue ""
              if gradle_version.empty?
                say "  ✓ Gradle available (version check skipped)", :green
              else
                say "  ✓ #{gradle_version}", :green
              end
            else
              say "  ℹ️  Gradle not found (will use project gradlew)", :cyan
            end
            say ""

            # Check 14: Google Play credentials (if logged in)
            if client && org_data
              say "Checking Google Play configuration...", :yellow
              
              if org_data['google_play_configured']
                say "  ✓ Google Play credentials configured", :green
              else
                say "  ℹ️  Google Play not configured", :cyan
                say "    Configure in My Signer dashboard or run 'mysigner doctor'", :cyan
              end

              # Check for keystores
              begin
                require_relative '../signing/keystore_manager'
                manager = Signing::KeystoreManager.new(client, config.current_organization_id)
                keystores = manager.list
                
                if keystores.any?
                  active = keystores.find { |k| k['active'] }
                  if active
                    say "  ✓ Active keystore: #{active['name']}", :green
                  else
                    say "  ⚠️  #{keystores.count} keystores, none active", :yellow
                    warnings << "No active keystore - activate one with: mysigner keystore activate ID"
                  end
                else
                  say "  ℹ️  No Android keystores", :cyan
                  say "    Upload with: mysigner keystore upload PATH", :cyan
                end
              rescue => e
                say "  ⚠️  Could not check keystores: #{e.message}", :yellow
              end
              say ""
            end

            # Check 15: Android Project Detection
            android_project = nil
            begin
              android_project = Build::Detector.detect_android
              framework = case android_project[:framework]
              when :capacitor then "Capacitor/Ionic"
              when :react_native then "React Native"
              when :flutter then "Flutter"
              else "Native Android"
              end
              say "Checking Android project...", :yellow
              say "  ✓ Found #{framework} Android project", :green
              
              # Parse project details
              require_relative '../build/android_parser'
              parser = Build::AndroidParser.new(android_project)
              say "  Package: #{parser.application_id}", :cyan
              say "  Version: #{parser.version_name} (#{parser.version_code})", :cyan
              say "  Gradle wrapper: #{parser.gradle_wrapper_exists? ? '✓' : '✗'}", :cyan
              say ""
            rescue Build::Detector::NoProjectError
              # Not an Android project, that's fine
            rescue => e
              say "  ⚠️  Could not analyze Android project: #{e.message}", :yellow if android_available
            end
            end # end of check_android block
            
            # Final Report
            say "=" * 80, :cyan
            say "Health Report", :bold
            say "=" * 80, :cyan
            say ""
            
            if issues.empty? && warnings.empty?
              say "🎉 All checks passed! You're good to go!", :green
              say ""
              say "Try: mysigner ship testflight", :cyan
            elsif issues.empty?
              say "⚠️  #{warnings.length} warning(s), but you're mostly good!", :yellow
              say ""
              warnings.each do |warning|
                say "  • #{warning}", :yellow
              end
            else
              say "✗ #{issues.length} issue(s) found:", :red
              say ""
              issues.each do |issue|
                say "  • #{issue}", :red
              end
              
              if warnings.any?
                say ""
                say "⚠️  #{warnings.length} warning(s):", :yellow
                warnings.each do |warning|
                  say "  • #{warning}", :yellow
                end
              end
            end
            
            say ""
          end

          no_commands do
            # Helper method for yes/no prompts with Enter defaulting to yes
            def yes_with_default?(statement, color = nil)
              response = ask("#{statement} [Y/n]", color).to_s.strip.downcase
              response.empty? || response == 'y' || response == 'yes'
            end

            # Generate a Certificate Signing Request (CSR)
            def generate_csr(email)
              require 'openssl'
              
              say "  Generating CSR...", :cyan
              
              begin
                # Save to Downloads (visible in file picker)
                csr_dir = File.expand_path("~/Downloads")
                FileUtils.mkdir_p(csr_dir)
                
                # Generate RSA key pair
                key = OpenSSL::PKey::RSA.new(2048)
                
                # Create CSR
                csr = OpenSSL::X509::Request.new
                csr.version = 0
                csr.subject = OpenSSL::X509::Name.new([
                  ['CN', email || 'My Signer User'],
                  ['emailAddress', email || 'user@example.com']
                ])
                csr.public_key = key.public_key
                csr.sign(key, OpenSSL::Digest::SHA256.new)
                
                # Generate unique filename with timestamp
                timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
                csr_filename = "CertificateSigningRequest_#{timestamp}.certSigningRequest"
                key_filename = "private_key_#{timestamp}.pem"
                
                # Save CSR to Downloads (visible)
                csr_path = File.join(csr_dir, csr_filename)
                
                # Save private key to hidden location (secure)
                key_dir = File.expand_path("~/.mysigner/keys")
                FileUtils.mkdir_p(key_dir)
                key_path = File.join(key_dir, key_filename)
                
                # Save CSR file
                File.write(csr_path, csr.to_pem)
                
                # Import private key directly to keychain (so certificate can pair)
                File.write(key_path, key.to_pem)
                
                import_result = `security import #{key_path} -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -T /usr/bin/security 2>&1`
                import_success = $?.success?
                
                if import_success
                  say "  ✓ CSR saved to Downloads", :green
                  say "  ✓ Private key imported to keychain", :green
                  # Clean up the file after importing
                  File.delete(key_path) rescue nil
                else
                  say "  ✓ CSR saved to Downloads", :green
                  say "  ✓ Private key saved to: #{key_path}", :green
                  say "  ⚠️  Import it with: security import #{key_path} -k ~/Library/Keychains/login.keychain-db", :yellow
                end
                
                csr_path
              rescue => e
                say "  ✗ Failed to generate CSR: #{e.message}", :red
                nil
              end
            end

            # Helper to auto-create a provisioning profile
            def auto_create_profile(client, config, bundle_id, profile_type)
              say "Creating #{profile_type} profile for #{bundle_id}...", :yellow
              say ""
              
              # Map friendly names to Apple's profile types
              apple_profile_type = case profile_type.to_s.downcase
                                   when 'appstore', 'store' then 'IOS_APP_STORE'
                                   when 'development', 'dev' then 'IOS_APP_DEVELOPMENT'
                                   when 'adhoc' then 'IOS_APP_ADHOC'
                                   else profile_type
                                   end
              
              begin
                # First, ensure resources are synced
                say "  Syncing organization resources...", :cyan
                client.post("/api/v1/organizations/#{config.current_organization_id}/sync_app_store_connect")
                
                # Wait a bit for sync to complete
                sleep 2
                
                # Check sync status
                max_wait = 15 # seconds
                waited = 0
                sync_complete = false
                
                while waited < max_wait
                  status_response = client.get("/api/v1/organizations/#{config.current_organization_id}/sync/status")
                  sync_data = status_response[:data]['sync']
                  
                  if !sync_data['running']
                    sync_complete = true
                    break
                  end
                  
                  sleep 1
                  waited += 1
                end
                
                if sync_complete
                  say "  ✓ Sync complete", :green
                else
                  say "  ⚠️  Sync still running, continuing anyway...", :yellow
                end
                say ""
                
                # Create profile
                say "  Creating #{apple_profile_type} profile...", :cyan
                response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/profiles/auto_create",
                  body: {
                    bundle_id: bundle_id,
                    profile_type: apple_profile_type
                  }
                )
                
                if response[:success]
                  profile = response[:data]['profile']
                  say "  ✓ Created profile: #{profile['name']}", :green
                  say "    UUID: #{profile['uuid']}", :cyan
                  say "    Expires: #{profile['expires_at']}", :cyan
                  say ""
                  
                  # Download and install the profile
                  say "  Downloading profile...", :cyan
                  download_response = client.get("/api/v1/organizations/#{config.current_organization_id}/profiles/#{profile['id']}/download")
                  
                  # Install to Xcode's provisioning profiles directory
                  profiles_dir = File.expand_path("~/Library/MobileDevice/Provisioning Profiles")
                  FileUtils.mkdir_p(profiles_dir)
                  profile_path = File.join(profiles_dir, "#{profile['uuid']}.mobileprovision")
                  File.write(profile_path, download_response)
                  
                  say "  ✓ Profile installed to Xcode", :green
                  say ""
                  true
                else
                  say "  ✗ Failed to create profile", :red
                  false
                end
              rescue Mysigner::ClientError => e
                error_msg = e.message
                
                if error_msg.include?("bundle_id_not_found")
                  say "  ✗ Bundle ID '#{bundle_id}' not found in App Store Connect", :red
                  say ""
                  say "  You need to register this bundle ID first:", :yellow
                  say "    1. Go to: https://developer.apple.com/account/resources/identifiers/list", :cyan
                  say "    2. Register bundle ID: #{bundle_id}", :cyan
                  say "    3. Run 'mysigner doctor' again", :cyan
                elsif error_msg.include?("certificates found") || error_msg.include?("no_certificates")
                  cert_type = apple_profile_type == 'IOS_APP_STORE' ? "Distribution" : "Development"
                  cert_name = apple_profile_type == 'IOS_APP_STORE' ? "Apple Distribution" : "Apple Development"
                  
                  say "  ✗ No #{cert_type} certificates found", :red
                  say ""
                  
                  # Offer to generate CSR automatically
                  if yes_with_default?("Generate CSR and get step-by-step guide?", :green)
                    say ""
                    csr_path = generate_csr(config.user_email)
                    
                    if csr_path
                      say ""
                      say "  ✓ CSR ready: #{File.basename(csr_path)}", :green
                      say ""
                      say "  📋 Next steps:", :cyan
                      say "    1. Go to: https://developer.apple.com/account/resources/certificates/add", :green
                      say "    2. Select: '#{cert_name}'", :green
                      say "    3. Upload CSR: #{csr_path}", :green
                      say "    4. Download .cer file and double-click to install", :green
                      say "    5. Sync in My Signer → Run 'mysigner doctor' again", :green
                      say ""
                    end
                  else
                    say ""
                    say "  📋 Quick guide:", :cyan
                    say "    1. Open Keychain Access → Request Certificate (save as CSR)", :green
                    say "    2. https://developer.apple.com/account/resources/certificates/add", :green
                    say "    3. Select '#{cert_name}' → Upload CSR → Download .cer", :green
                    say "    4. Double-click .cer to install → Sync My Signer", :green
                    say ""
                  end
                elsif error_msg.include?("no_devices") || error_msg.include?("devices found")
                  say "  ✗ No test devices (needed for dev profiles)", :red
                  say ""
                  say "  📋 Quick fix:", :cyan
                  say "    • Get UDID: Connect device → Finder → Click serial number", :green
                  say "    • Run: mysigner device add <UDID> <NAME>", :green
                  say "    • Or add in: #{client.api_url}/organizations/#{config.current_organization_id}", :green
                  say ""
                else
                  say "  ✗ Failed: #{error_msg}", :red
                end
                say ""
                false
              rescue => e
                say "  ✗ Unexpected error: #{e.message}", :red
                say ""
                false
              end
            end
          end

          desc "sync [PLATFORM]", "🔄 Sync data from App Store Connect or Google Play"
          long_desc <<~DESC
            Sync your organization's data from app stores.

            PLATFORMS (optional):
              ios      : Sync from App Store Connect (default)
              android  : Sync from Google Play
              all      : Sync from both platforms

            Without a platform argument, syncs iOS (App Store Connect) data.

            EXAMPLES:
              mysigner sync              # Sync iOS data
              mysigner sync ios          # Sync iOS data
              mysigner sync android      # Sync Android data
              mysigner sync all          # Sync both platforms
          DESC
          option :force, type: :boolean, aliases: '-f', desc: 'Force sync even if recently synced'
          def sync(platform = 'ios')
            config = load_config
            client = create_client(config)

            platform = platform.to_s.downcase

            case platform
            when 'ios', 'apple', 'appstore'
              sync_ios(client, config)
            when 'android', 'google', 'googleplay', 'play'
              sync_android(client, config)
            when 'all', 'both'
              sync_ios(client, config)
              say ""
              sync_android(client, config)
            else
              error "Unknown platform: #{platform}"
              say "Valid platforms: ios, android, all", :yellow
              exit 1
            end
          end

          no_commands do
            def sync_ios(client, config)
              say "🔄 Syncing data from App Store Connect...", :cyan
              say ""

              begin
                response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/sync",
                  body: { force: options[:force] }
                )

                if response[:success]
                  data = response[:data]
                  say "✓ iOS sync completed!", :green
                  say ""
                  
                  if data['synced_at']
                    say "Last synced: #{data['synced_at']}", :cyan
                  end
                  
                  if data['summary']
                    say ""
                    say "📊 Summary:", :cyan
                    summary = data['summary']
                    say "  • Apps: #{summary['apps']}" if summary['apps']
                    say "  • Builds: #{summary['builds']}" if summary['builds']
                    say "  • Certificates: #{summary['certificates']}" if summary['certificates']
                    say "  • Devices: #{summary['devices']}" if summary['devices']
                    say "  • Profiles: #{summary['profiles']}" if summary['profiles']
                  end
                else
                  say "✗ iOS sync failed: #{response[:error]}", :red
                end
              rescue => e
                say "✗ iOS sync failed: #{e.message}", :red
              end
            end

            def sync_android(client, config)
              say "🔄 Syncing data from Google Play...", :cyan
              say ""

              begin
                response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/sync_google_play",
                  body: { force: options[:force] }
                )

                if response[:success]
                  say "✓ Android sync started!", :green
                  say ""
                  say "Sync runs in the background. Check status with:", :cyan
                  say "  mysigner android-apps", :green
                  say ""
                  
                  # Optionally wait and show status
                  say "💡 Google Play sync may take a few minutes.", :yellow
                  say "   Unlike iOS, Google Play doesn't auto-discover apps.", :yellow
                  say "   If no apps appear, add them in the web dashboard first.", :yellow
                else
                  say "✗ Android sync failed: #{response[:error] || 'Unknown error'}", :red
                end
              rescue Mysigner::ClientError => e
                if e.message.include?("No active Google Play credential")
                  say "✗ Google Play not configured", :red
                  say ""
                  say "Set up credentials first:", :yellow
                  say "  Configure Google Play in My Signer dashboard", :green
                else
                  say "✗ Android sync failed: #{e.message}", :red
                end
              rescue => e
                say "✗ Android sync failed: #{e.message}", :red
              end
            end

            # Detect valid JAVA_HOME using macOS java_home utility or common paths
            def detect_java_home(version: nil)
              # Try macOS java_home utility first (most reliable)
              if system('which /usr/libexec/java_home > /dev/null 2>&1')
                cmd = '/usr/libexec/java_home'
                cmd += " -v #{version}" if version
                java_home = `#{cmd} 2>/dev/null`.strip
                return java_home if !java_home.empty? && Dir.exist?(java_home)
              end

              # Try common Homebrew paths (Apple Silicon)
              homebrew_paths = %w[
                /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
                /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
                /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
              ]
              homebrew_paths.each do |path|
                return path if Dir.exist?(path)
              end

              # Try common Homebrew paths (Intel)
              intel_paths = %w[
                /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
                /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
                /usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home
              ]
              intel_paths.each do |path|
                return path if Dir.exist?(path)
              end

              # Try system Java
              system_paths = Dir.glob('/Library/Java/JavaVirtualMachines/*/Contents/Home')
              return system_paths.first if system_paths.any?

              nil
            end

            # Fix JAVA_HOME in shell config
            def fix_java_home(java_home)
              shell_config = File.expand_path('~/.zshrc')
              
              # Use ~/.bash_profile if zsh config doesn't exist
              unless File.exist?(shell_config)
                shell_config = File.expand_path('~/.bash_profile')
              end

              # Read existing content
              content = File.exist?(shell_config) ? File.read(shell_config) : ""

              # Check if JAVA_HOME is already set
              if content.include?('export JAVA_HOME=')
                # Replace existing JAVA_HOME line
                new_content = content.gsub(/^export JAVA_HOME=.*$/, "export JAVA_HOME=\"#{java_home}\"")
                File.write(shell_config, new_content)
                say "  ✓ Updated JAVA_HOME in #{shell_config}", :green
              else
                # Append JAVA_HOME
                File.open(shell_config, 'a') do |f|
                  f.puts ""
                  f.puts "# Added by mysigner doctor"
                  f.puts "export JAVA_HOME=\"#{java_home}\""
                end
                say "  ✓ Added JAVA_HOME to #{shell_config}", :green
              end

              say ""
              say "  To apply now, run:", :yellow
              say "    source #{shell_config}", :cyan
              say ""
              say "  Or restart your terminal.", :yellow
            end
          end
        end
      end
    end
  end
end
