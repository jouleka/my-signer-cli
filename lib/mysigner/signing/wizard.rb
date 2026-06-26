# frozen_string_literal: true

require 'faraday'
require 'json'

module Mysigner
  module Signing
    class Wizard
      class WizardError < StandardError; end

      def initialize(parser, client, organization_id, options = {})
        @parser = parser
        @client = client
        @organization_id = organization_id
        @options = options
      end

      # Run the interactive wizard
      def run!
        puts ''
        puts '🧙 Manual Signing Setup Wizard'
        puts '=' * 80
        puts ''

        # Check if we're configuring all targets
        if @options[:all_targets]
          configure_all_targets
        else
          configure_single_target(@options[:target])
        end
      end

      def configure_all_targets
        targets = @parser.signable_targets

        if targets.empty?
          error 'No signable targets found in project'
          return
        end

        puts "Found #{targets.count} signable target(s):"
        targets.each do |info|
          type_label = info[:type] == :app ? '📱 App' : '🧩 Extension'
          puts "  #{type_label}: #{info[:name]}"
        end
        puts ''

        print 'Configure all targets? (y/n): '
        confirm = get_input.downcase

        unless %w[y yes].include?(confirm)
          puts 'Cancelled'
          return
        end

        puts ''

        # Configure each target
        successful = 0
        failed = 0

        targets.each_with_index do |info, index|
          puts ''
          puts '=' * 80
          puts "Configuring #{index + 1}/#{targets.count}: #{info[:name]}"
          puts '=' * 80
          puts ''

          if configure_single_target(info[:name], skip_header: true)
            successful += 1
          else
            failed += 1
            puts ''
            print 'Continue with remaining targets? (y/n): '
            continue = get_input.downcase
            break unless %w[y yes].include?(continue)
          end
        end

        puts ''
        puts '=' * 80
        puts "✅ Completed: #{successful} successful, #{failed} failed"
        puts '=' * 80
        puts ''
        puts 'Next steps:'
        puts '  1. Test build: mysigner build'
        puts '  2. Or ship to TestFlight: mysigner ship testflight'
        puts ''
      end

      def configure_single_target(target_name = nil, skip_header: false)
        unless skip_header
          # No header needed, already printed in run!
        end

        # Step 1: Detect or validate target
        target_name = detect_target(target_name)
        return false unless target_name

        @current_target = target_name

        # Step 1.5: Check if project's team matches current org
        check_org_team_match(target_name) if @options[:check_org_match] != false

        # Step 2: Show current configuration
        show_current_config(target_name)

        # Step 3: Select team
        team_id = select_team(target_name)
        return false unless team_id

        # Step 4: Select provisioning profile
        profile = select_profile(target_name, team_id)
        return false unless profile

        # Step 5: Apply configuration
        apply_configuration(target_name, team_id, profile)

        # Step 6: Validate
        validate_configuration(target_name, team_id)

        unless skip_header
          puts ''
          puts '=' * 80
          puts '✅ Signing configuration complete!'
          puts '=' * 80
          puts ''
          puts 'Next steps:'
          puts '  1. Test build: mysigner build'
          puts '  2. Or ship to TestFlight: mysigner ship testflight'
          puts ''
        end

        true
      end

      private

      def detect_target(target_name = nil)
        # If target_name provided, validate it exists
        if target_name
          begin
            @parser.find_target(target_name)
            puts "📱 Target: #{target_name}"
            puts ''
            return target_name
          rescue StandardError => e
            error "Target '#{target_name}' not found: #{e.message}"
            return nil
          end
        end

        # No target provided, auto-detect or let user choose
        targets = @parser.app_targets

        if targets.empty?
          error 'No app targets found in project'
          return nil
        end

        if targets.one?
          target = targets.first
          puts "📱 Target: #{target.name}"
          puts ''
          return target.name
        end

        # Multiple targets - let user choose
        puts 'Multiple app targets found:'
        targets.each_with_index do |target, i|
          puts "  #{i + 1}. #{target.name}"
        end
        puts ''

        print "Select target (1-#{targets.count}): "
        choice = get_input.to_i

        if choice < 1 || choice > targets.count
          error 'Invalid selection'
          return nil
        end

        targets[choice - 1].name
      end

      def show_current_config(target_name)
        puts 'Current Configuration:'
        puts '-' * 80

        bundle_id = @parser.bundle_id(target_name)
        puts "  Bundle ID: #{bundle_id || 'Not set'}"

        team_id = @parser.team_id(target_name)
        puts "  Team: #{team_id || 'Not set'}"

        sign_style = @parser.code_sign_style(target_name)
        puts "  Signing: #{sign_style || 'Not set'}"

        if @parser.signing_configured?(target_name)
          profile_name = @parser.project.targets.find { |t| t.name == target_name }
                                                &.build_configurations&.first
                                &.build_settings&.[]('PROVISIONING_PROFILE_SPECIFIER')
          puts "  Profile: #{profile_name || 'Auto'}"
        end

        puts ''
      end

      def select_team(target_name)
        puts 'Step 1: Select Development Team'
        puts '-' * 80
        puts ''

        current_team = @parser.team_id(target_name)

        # Option 1: Keep current team
        puts "  1. Keep current team: #{current_team}" if current_team && !current_team.empty?

        # Option 2: Fetch from API
        puts "  #{current_team ? '2' : '1'}. Fetch from My Signer API"

        # Option 3: Enter manually
        puts "  #{current_team ? '3' : '2'}. Enter team ID manually"

        puts ''
        print 'Select option: '
        choice = get_input.to_i

        case choice
        when 1
          if current_team
            puts "✓ Using current team: #{current_team}"
            puts ''
            current_team
          else
            # Fetch from API
            fetch_team_from_api
          end
        when 2
          if current_team
            fetch_team_from_api
          else
            enter_team_manually
          end
        when 3
          enter_team_manually
        else
          error 'Invalid selection'
          nil
        end
      end

      def fetch_team_from_api
        puts ''
        puts 'Fetching team from My Signer...'

        begin
          response = @client.get("/api/v1/organizations/#{@organization_id}")
          team_id = response.dig(:data, 'app_store_connect_team_id') || response['app_store_connect_team_id']

          if team_id && !team_id.empty?
            puts "✓ Found team: #{team_id}"
            puts ''
            team_id
          else
            error 'Team ID not saved in My Signer API (database)'
            puts ''
            current_team = @parser.team_id(@current_target)
            puts "Note: Your Xcode project already has team: #{current_team}" if current_team
            puts ''
            puts 'You can either:'
            puts '  1. Keep your current Xcode team (go back and select option 1)'
            puts '  2. Add it to My Signer web: https://mysigner.dev'
            puts '     → Open your organization → App Store Connect → Edit/Add credentials → Team ID field'
            puts '  3. Enter it manually (go back and select option 3)'
            puts ''
            nil
          end
        rescue StandardError => e
          error "Failed to fetch team: #{e.message}"
          nil
        end
      end

      def enter_team_manually
        puts ''
        print 'Enter Team ID (10 characters): '
        team_id = get_input

        if team_id =~ /^[A-Z0-9]{10}$/
          puts "✓ Team ID: #{team_id}"
          puts ''
          team_id
        else
          error 'Invalid Team ID format (must be 10 alphanumeric characters)'
          nil
        end
      end

      def select_profile(target_name, _team_id)
        puts 'Step 2: Select Provisioning Profile'
        puts '-' * 80
        puts ''

        # Fetch profiles from API
        puts 'Fetching provisioning profiles...'

        begin
          bundle_id = @parser.bundle_id(target_name)

          # Get profiles for this bundle ID
          response = @client.get("/api/v1/organizations/#{@organization_id}/profiles",
                                 params: { bundle_id: bundle_id })

          profiles = response[:data]['profiles'] || []

          if profiles.empty?
            puts "No provisioning profiles found for bundle ID: #{bundle_id}"
            puts ''
            puts 'Options:'
            puts '  1. Auto-create App Store profile (recommended)'
            puts '  2. Auto-create Development profile'
            puts '  3. Create manually and sync'
            puts '  4. Skip'
            puts ''

            print 'Select option (1-4): '
            choice = get_input
            puts ''

            case choice
            when '1'
              profile = auto_create_profile(bundle_id, :appstore)
              return profile if profile

            when '2'
              profile = auto_create_profile(bundle_id, :development)
              return profile if profile

            when '3'
              puts 'Create profile at: https://developer.apple.com/account/resources/profiles/add'
              puts 'Then sync from My Signer web dashboard'
              puts ''
            when '4'
              puts 'Skipped profile selection'
            else
              error 'Invalid selection'
            end
            return nil
          end

          # Filter profiles by type (development vs distribution)
          dev_profiles = profiles.select { |p| p['profile_type']&.include?('DEVELOPMENT') }
          dist_profiles = profiles.select do |p|
            type = p['profile_type']
            type&.include?('DISTRIBUTION') || type&.include?('APP_STORE') || type&.include?('ADHOC') || type&.include?('INHOUSE')
          end

          puts ''
          puts 'Available Profiles:'
          puts ''

          all_profiles = []

          if dev_profiles.any?
            puts '  Development Profiles:'
            dev_profiles.each_with_index do |profile, _i|
              all_profiles << profile
              status = profile['status'] == 'ACTIVE' ? '✓' : '✗'
              puts "    #{all_profiles.count}. #{status} #{profile['name']}"
              puts "       Expires: #{profile['expires_at']&.split('T')&.first || 'Unknown'}"
            end
            puts ''
          end

          if dist_profiles.any?
            puts '  Distribution Profiles:'
            dist_profiles.each_with_index do |profile, _i|
              all_profiles << profile
              status = profile['status'] == 'ACTIVE' ? '✓' : '✗'
              puts "    #{all_profiles.count}. #{status} #{profile['name']}"
              puts "       Expires: #{profile['expires_at']&.split('T')&.first || 'Unknown'}"
            end
            puts ''
          end

          print "Select profile (1-#{all_profiles.count}): "
          choice = get_input.to_i

          if choice < 1 || choice > all_profiles.count
            error 'Invalid selection'
            return nil
          end

          selected = all_profiles[choice - 1]
          puts "✓ Selected: #{selected['name']}"
          puts ''

          # Download and install the profile
          download_and_install_profile(selected)

          selected
        rescue StandardError => e
          error "Failed to fetch profiles: #{e.message}"
          nil
        end
      end

      def download_and_install_profile(profile)
        puts 'Downloading and installing profile...'

        begin
          # Download profile using direct Faraday connection for binary data
          # (the client's get method uses JSON middleware which corrupts binary data)
          download_url = "/api/v1/organizations/#{@organization_id}/profiles/#{profile['id']}/download"

          # Never attach the API token to a non-https (non-loopback) endpoint.
          Mysigner::Client.assert_secure_api_url!(@client.api_url)
          conn = Faraday.new(url: @client.api_url) do |f|
            f.request :authorization, 'Bearer', @client.api_token
            f.adapter Faraday.default_adapter
          end

          response = conn.get(download_url) do |req|
            req.options.timeout = 30
            req.options.open_timeout = 10
          end

          unless response.success?
            raise "Download failed with status #{response.status}" unless response.headers['content-type']&.include?('json')

            begin
              error_data = JSON.parse(response.body)
              raise "Download failed: #{error_data['message'] || error_data['error']}"
            rescue JSON::ParserError
              raise "Download failed with status #{response.status}"
            end

          end

          profile_content = response.body

          # Create profiles directory if it doesn't exist
          profiles_dir = File.expand_path('~/Library/MobileDevice/Provisioning Profiles')
          FileUtils.mkdir_p(profiles_dir)

          # Generate filename (use UUID if available, otherwise sanitized name)
          uuid = profile['uuid'] || profile['id']
          filename = "#{uuid}.mobileprovision"
          output_path = File.join(profiles_dir, filename)

          # Write binary profile to file
          File.binwrite(output_path, profile_content)

          puts "✓ Profile installed: #{output_path}"
          puts ''
        rescue StandardError => e
          # Non-fatal error - profile might still work if already installed
          puts "⚠️  Could not auto-install profile: #{e.message}"
          puts '   You may need to install it manually by double-clicking the .mobileprovision file'
          puts ''
        end
      end

      def apply_configuration(target_name, team_id, profile)
        puts 'Step 3: Applying Configuration'
        puts '-' * 80
        puts ''

        puts "Setting up manual signing for target: #{target_name}"
        puts "  Team: #{team_id}"
        puts "  Profile: #{profile['name']}"
        puts ''

        target = @parser.project.targets.find { |t| t.name == target_name }

        raise WizardError, "Target not found: #{target_name}" unless target

        # Update build configurations
        target.build_configurations.each do |config|
          puts "  Configuring #{config.name}..."

          # Set manual signing
          config.build_settings['CODE_SIGN_STYLE'] = 'Manual'

          # Set team
          config.build_settings['DEVELOPMENT_TEAM'] = team_id

          # Set provisioning profile
          config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = profile['name']

          # Set code sign identity
          profile_type = profile['profile_type']
          config.build_settings['CODE_SIGN_IDENTITY'] = if profile_type&.include?('DEVELOPMENT')
                                                          'Apple Development'
                                                        else
                                                          'Apple Distribution'
                                                        end
        end

        # Save project
        @parser.project.save

        puts '✓ Configuration applied'
        puts ''
      end

      def validate_configuration(target_name, team_id)
        puts 'Step 4: Validating Configuration'
        puts '-' * 80
        puts ''

        validator = Validator.new(@parser, target_name, 'Release', team_id: team_id)
        result = validator.validate

        if result[:valid]
          puts '✓ Configuration is valid'

          if result[:warnings].any?
            puts ''
            puts 'Warnings:'
            result[:warnings].each do |warning|
              puts "  ⚠️  #{warning}"
            end
          end
        else
          puts '✗ Configuration has errors:'
          puts ''
          result[:errors].each do |error|
            puts "  • #{error}"
          end
          puts ''
          raise WizardError, 'Configuration validation failed'
        end

        puts ''
      end

      def check_org_team_match(target_name)
        project_team = @parser.team_id(target_name)
        return unless project_team # No team set in project yet

        begin
          # Fetch current org's team
          response = @client.get("/api/v1/organizations/#{@organization_id}")
          org_name = response.dig(:data, 'name') || response['name']
          org_team = response.dig(:data, 'app_store_connect_team_id') || response['app_store_connect_team_id']

          if org_team && org_team != project_team
            puts ''
            puts '⚠️  Warning: Organization / Team Mismatch', :yellow
            puts '=' * 80
            puts ''
            puts "Your Xcode project uses team:     #{project_team}"
            puts "Current My Signer org:            #{org_name} (Team: #{org_team})"
            puts ''
            puts 'This means your project belongs to a different Apple Developer account'
            puts "than the organization you're currently using in My Signer."
            puts ''
            puts 'What this means:'
            puts "  • Profiles/certificates fetched will be for team #{org_team}"
            puts "  • But your project needs resources for team #{project_team}"
            puts '  • This will likely cause signing errors'
            puts ''
            puts 'To fix this:'
            puts '  1. Exit this wizard (Ctrl+C)'
            puts '  2. Run: mysigner switch'
            puts "  3. Select the organization that has team #{project_team}"
            puts '  4. Run this wizard again'
            puts ''
            print 'Continue anyway? (y/N): '
            answer = get_input.downcase

            unless %w[y yes].include?(answer)
              puts ''
              puts 'Wizard cancelled. Please switch organizations and try again.'
              exit 0
            end
            puts ''
          elsif !org_team
            # Current org has no team configured
            puts ''
            puts 'ℹ️  Note: Current organization has no Team ID configured', :cyan
            puts '=' * 80
            puts ''
            puts "Your Xcode project uses team:     #{project_team}"
            puts "Current My Signer org:            #{org_name} (No team configured)"
            puts ''
            puts "You can continue, but the wizard won't be able to fetch the team from My Signer."
            puts 'Consider adding Team ID to this org at: https://mysigner.dev'
            puts ''
            print 'Continue? (Y/n): '
            answer = get_input.downcase

            if %w[n no].include?(answer)
              puts ''
              puts 'Wizard cancelled.'
              exit 0
            end
            puts ''
          end
        rescue StandardError => e
          # Ignore errors in org checking - don't block the wizard
          puts "Warning: Could not verify organization match: #{e.message}" if ENV['DEBUG']
        end
      end

      def auto_create_profile(bundle_id, type)
        puts "Creating #{type} profile for #{bundle_id}..."
        puts ''

        profile_type = type == :appstore ? 'IOS_APP_STORE' : 'IOS_APP_DEVELOPMENT'

        begin
          # Sync first to ensure we have latest resources
          puts '  Syncing organization resources...'
          @client.post("/api/v1/organizations/#{@organization_id}/sync_app_store_connect")

          # Wait for sync
          sleep 2

          # Check sync status
          max_wait = 15
          waited = 0

          while waited < max_wait
            status_response = @client.get("/api/v1/organizations/#{@organization_id}/sync/status")
            sync_data = status_response[:data]['sync']

            break unless sync_data['running']

            sleep 1
            waited += 1
          end

          puts '  ✓ Sync complete'
          puts ''

          # Create profile
          puts "  Creating #{profile_type} profile..."
          response = @client.post(
            "/api/v1/organizations/#{@organization_id}/profiles/auto_create",
            body: {
              bundle_id: bundle_id,
              profile_type: profile_type
            }
          )

          profile = response[:data]['profile']
          puts "  ✓ Created profile: #{profile['name']}"
          puts ''

          # Download and install
          download_and_install_profile(profile)

          profile
        rescue Mysigner::ClientError => e
          error_msg = e.message

          if error_msg.include?('bundle_id_not_found')
            error "Bundle ID '#{bundle_id}' not found"
            puts ''
            puts 'Register it at: https://developer.apple.com/account/resources/identifiers/add'
            puts 'Then sync in the web dashboard'
          elsif error_msg.include?('certificates found') || error_msg.include?('no_certificates')
            cert_name = type == :appstore ? 'Apple Distribution' : 'Apple Development'

            error "No #{cert_name} certificates found"
            puts ''

            print 'Generate CSR automatically? [Y/n] '
            response = get_input.downcase

            puts ''
            if response.empty? || response == 'y' || response == 'yes'
              csr_path = generate_csr_for_wizard

              if csr_path
                puts ''
                puts "  ✓ CSR ready: #{File.basename(csr_path)}"
                puts ''
                puts '  📋 Next steps:'
                puts '    1. https://developer.apple.com/account/resources/certificates/add'
                puts "    2. Select: '#{cert_name}' (or older 'iOS' variant if available)"
                puts "    3. Upload: #{csr_path}"
                puts '    4. Download .cer → Double-click → Sync → Try again'
                puts ''
              end
            else
              puts 'Quick fix:'
              puts '  1. Open Keychain Access → Request Certificate (save CSR)'
              puts '  2. https://developer.apple.com/account/resources/certificates/add'
              puts "  3. Select '#{cert_name}' → Upload CSR → Download .cer"
              puts '  4. Double-click .cer → Sync My Signer → Try again'
              puts ''
            end
          elsif error_msg.include?('no_devices') || error_msg.include?('devices found')
            error 'No test devices registered'
            puts ''
            puts 'Quick fix:'
            puts '  • Get UDID: Connect device → Finder → Click serial number'
            puts '  • Run: mysigner device add <UDID> <NAME>'
            puts ''
          else
            error "Failed to create profile: #{error_msg}"
          end
          puts ''
          nil
        rescue StandardError => e
          error "Unexpected error: #{e.message}"
          puts ''
          nil
        end
      end

      def generate_csr_for_wizard
        require 'openssl'

        begin
          # Save to Downloads (visible in file picker)
          csr_dir = File.expand_path('~/Downloads')
          FileUtils.mkdir_p(csr_dir)

          # Generate RSA key pair
          key = OpenSSL::PKey::RSA.new(2048)

          # Create CSR
          csr = OpenSSL::X509::Request.new
          csr.version = 0
          csr.subject = OpenSSL::X509::Name.new([
                                                  ['CN', 'My Signer User'],
                                                  ['emailAddress', 'user@example.com']
                                                ])
          csr.public_key = key.public_key
          csr.sign(key, OpenSSL::Digest.new('SHA256'))

          # Generate unique filename
          timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
          csr_filename = "CertificateSigningRequest_#{timestamp}.certSigningRequest"
          key_filename = "private_key_#{timestamp}.pem"

          # Save CSR to Downloads (visible)
          csr_path = File.join(csr_dir, csr_filename)

          # Save private key to hidden location (secure)
          key_dir = File.expand_path('~/.mysigner/keys')
          FileUtils.mkdir_p(key_dir)
          key_path = File.join(key_dir, key_filename)

          # Save files
          File.write(csr_path, csr.to_pem)
          File.write(key_path, key.to_pem)
          File.chmod(0o600, key_path)

          csr_path
        rescue StandardError => e
          puts "  ✗ Failed to generate CSR: #{e.message}"
          nil
        end
      end

      # Safely get user input, returns empty string if STDIN is closed or nil
      def get_input
        input = $stdin.gets
        input ? input.strip : ''
      end

      def error(message)
        puts "✗ #{message}"
      end
    end
  end
end
