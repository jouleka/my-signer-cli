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
        puts ""
        puts "🧙 Manual Signing Setup Wizard"
        puts "=" * 80
        puts ""
        
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
          error "No signable targets found in project"
          return
        end
        
        puts "Found #{targets.count} signable target(s):"
        targets.each do |info|
          type_label = info[:type] == :app ? '📱 App' : '🧩 Extension'
          puts "  #{type_label}: #{info[:name]}"
        end
        puts ""
        
        print "Configure all targets? (y/n): "
        confirm = STDIN.gets.strip.downcase
        
        unless confirm == 'y' || confirm == 'yes'
          puts "Cancelled"
          return
        end
        
        puts ""
        
        # Configure each target
        successful = 0
        failed = 0
        
        targets.each_with_index do |info, index|
          puts ""
          puts "=" * 80
          puts "Configuring #{index + 1}/#{targets.count}: #{info[:name]}"
          puts "=" * 80
          puts ""
          
          if configure_single_target(info[:name], skip_header: true)
            successful += 1
          else
            failed += 1
            puts ""
            print "Continue with remaining targets? (y/n): "
            continue = STDIN.gets.strip.downcase
            unless continue == 'y' || continue == 'yes'
              break
            end
          end
        end
        
        puts ""
        puts "=" * 80
        puts "✅ Completed: #{successful} successful, #{failed} failed"
        puts "=" * 80
        puts ""
        puts "Next steps:"
        puts "  1. Test build: mysigner build"
        puts "  2. Or ship to TestFlight: mysigner ship testflight"
        puts ""
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
          puts ""
          puts "=" * 80
          puts "✅ Signing configuration complete!"
          puts "=" * 80
          puts ""
          puts "Next steps:"
          puts "  1. Test build: mysigner build"
          puts "  2. Or ship to TestFlight: mysigner ship testflight"
          puts ""
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
            puts ""
            return target_name
          rescue => e
            error "Target '#{target_name}' not found: #{e.message}"
            return nil
          end
        end
        
        # No target provided, auto-detect or let user choose
        targets = @parser.app_targets
        
        if targets.empty?
          error "No app targets found in project"
          return nil
        end
        
        if targets.count == 1
          target = targets.first
          puts "📱 Target: #{target.name}"
          puts ""
          return target.name
        end
        
        # Multiple targets - let user choose
        puts "Multiple app targets found:"
        targets.each_with_index do |target, i|
          puts "  #{i + 1}. #{target.name}"
        end
        puts ""
        
        print "Select target (1-#{targets.count}): "
        choice = STDIN.gets.strip.to_i
        
        if choice < 1 || choice > targets.count
          error "Invalid selection"
          return nil
        end
        
        targets[choice - 1].name
      end

      def show_current_config(target_name)
        puts "Current Configuration:"
        puts "-" * 80
        
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
        
        puts ""
      end

      def select_team(target_name)
        puts "Step 1: Select Development Team"
        puts "-" * 80
        puts ""
        
        current_team = @parser.team_id(target_name)
        
        # Option 1: Keep current team
        if current_team && !current_team.empty?
          puts "  1. Keep current team: #{current_team}"
        end
        
        # Option 2: Fetch from API
        puts "  #{current_team ? '2' : '1'}. Fetch from My Signer API"
        
        # Option 3: Enter manually
        puts "  #{current_team ? '3' : '2'}. Enter team ID manually"
        
        puts ""
        print "Select option: "
        choice = STDIN.gets.strip.to_i
        
        case choice
        when 1
          if current_team
            puts "✓ Using current team: #{current_team}"
            puts ""
            return current_team
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
          error "Invalid selection"
          nil
        end
      end

      def fetch_team_from_api
        puts ""
        puts "Fetching team from My Signer..."
        
        begin
          response = @client.get("/api/v1/organizations/#{@organization_id}")
          team_id = response.dig(:data, 'app_store_connect_team_id') || response['app_store_connect_team_id']
          
          if team_id && !team_id.empty?
            puts "✓ Found team: #{team_id}"
            puts ""
            return team_id
          else
            error "Team ID not saved in My Signer API (database)"
            puts ""
            current_team = @parser.team_id(@current_target)
            puts "Note: Your Xcode project already has team: #{current_team}" if current_team
            puts ""
            puts "You can either:"
            puts "  1. Keep your current Xcode team (go back and select option 1)"
            puts "  2. Add it to My Signer web: https://app.mysigner.app"
            puts "     → Open your organization → App Store Connect → Edit/Add credentials → Team ID field"
            puts "  3. Enter it manually (go back and select option 3)"
            puts ""
            nil
          end
        rescue => e
          error "Failed to fetch team: #{e.message}"
          nil
        end
      end

      def enter_team_manually
        puts ""
        print "Enter Team ID (10 characters): "
        team_id = STDIN.gets.strip
        
        if team_id =~ /^[A-Z0-9]{10}$/
          puts "✓ Team ID: #{team_id}"
          puts ""
          return team_id
        else
          error "Invalid Team ID format (must be 10 alphanumeric characters)"
          nil
        end
      end

      def select_profile(target_name, team_id)
        puts "Step 2: Select Provisioning Profile"
        puts "-" * 80
        puts ""
        
        # Fetch profiles from API
        puts "Fetching provisioning profiles..."
        
        begin
          bundle_id = @parser.bundle_id(target_name)
          
          # Get profiles for this bundle ID
          response = @client.get("/api/v1/organizations/#{@organization_id}/profiles", 
                                 params: { bundle_id: bundle_id })
          
          profiles = response[:data]['profiles'] || []
          
          if profiles.empty?
            error "No provisioning profiles found for bundle ID: #{bundle_id}"
            puts ""
            puts "Create a profile at: https://developer.apple.com/account/resources/profiles/add"
            puts "Or sync from App Store Connect using My Signer web dashboard"
            puts ""
            return nil
          end
          
          # Filter profiles by type (development vs distribution)
          dev_profiles = profiles.select { |p| p['profile_type']&.include?('DEVELOPMENT') }
          dist_profiles = profiles.select do |p|
            type = p['profile_type']
            type&.include?('DISTRIBUTION') || type&.include?('APP_STORE') || type&.include?('ADHOC') || type&.include?('INHOUSE')
          end
          
          puts ""
          puts "Available Profiles:"
          puts ""
          
          all_profiles = []
          
          if dev_profiles.any?
            puts "  Development Profiles:"
            dev_profiles.each_with_index do |profile, i|
              all_profiles << profile
              status = profile['status'] == 'ACTIVE' ? '✓' : '✗'
              puts "    #{all_profiles.count}. #{status} #{profile['name']}"
              puts "       Expires: #{profile['expires_at']&.split('T')&.first || 'Unknown'}"
            end
            puts ""
          end
          
          if dist_profiles.any?
            puts "  Distribution Profiles:"
            dist_profiles.each_with_index do |profile, i|
              all_profiles << profile
              status = profile['status'] == 'ACTIVE' ? '✓' : '✗'
              puts "    #{all_profiles.count}. #{status} #{profile['name']}"
              puts "       Expires: #{profile['expires_at']&.split('T')&.first || 'Unknown'}"
            end
            puts ""
          end
          
          print "Select profile (1-#{all_profiles.count}): "
          choice = STDIN.gets.strip.to_i
          
          if choice < 1 || choice > all_profiles.count
            error "Invalid selection"
            return nil
          end
          
          selected = all_profiles[choice - 1]
          puts "✓ Selected: #{selected['name']}"
          puts ""
          
          # Download and install the profile
          download_and_install_profile(selected)
          
          selected
          
        rescue => e
          error "Failed to fetch profiles: #{e.message}"
          nil
        end
      end

      def download_and_install_profile(profile)
        puts "Downloading and installing profile..."
        
        begin
          # Download profile
          download_url = "/api/v1/organizations/#{@organization_id}/profiles/#{profile['id']}/download"
          response = @client.get(download_url)
          profile_content = response
          
          # Create profiles directory if it doesn't exist
          profiles_dir = File.expand_path("~/Library/MobileDevice/Provisioning Profiles")
          FileUtils.mkdir_p(profiles_dir) unless Dir.exist?(profiles_dir)
          
          # Generate filename (use UUID if available, otherwise sanitized name)
          uuid = profile['uuid'] || profile['id']
          filename = "#{uuid}.mobileprovision"
          output_path = File.join(profiles_dir, filename)
          
          # Write profile to file
          File.open(output_path, 'wb') do |file|
            file.write(profile_content)
          end
          
          puts "✓ Profile installed: #{output_path}"
          puts ""
          
        rescue => e
          # Non-fatal error - profile might still work if already installed
          puts "⚠️  Could not auto-install profile: #{e.message}"
          puts "   You may need to install it manually by double-clicking the .mobileprovision file"
          puts ""
        end
      end

      def apply_configuration(target_name, team_id, profile)
        puts "Step 3: Applying Configuration"
        puts "-" * 80
        puts ""
        
        puts "Setting up manual signing for target: #{target_name}"
        puts "  Team: #{team_id}"
        puts "  Profile: #{profile['name']}"
        puts ""
        
        target = @parser.project.targets.find { |t| t.name == target_name }
        
        unless target
          raise WizardError, "Target not found: #{target_name}"
        end
        
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
          if profile_type&.include?('DEVELOPMENT')
            config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
          else
            config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Distribution'
          end
        end
        
        # Save project
        @parser.project.save
        
        puts "✓ Configuration applied"
        puts ""
      end

      def validate_configuration(target_name, team_id)
        puts "Step 4: Validating Configuration"
        puts "-" * 80
        puts ""
        
        validator = Validator.new(@parser, target_name, 'Release', team_id: team_id)
        result = validator.validate
        
        if result[:valid]
          puts "✓ Configuration is valid"
          
          if result[:warnings].any?
            puts ""
            puts "Warnings:"
            result[:warnings].each do |warning|
              puts "  ⚠️  #{warning}"
            end
          end
        else
          puts "✗ Configuration has errors:"
          puts ""
          result[:errors].each do |error|
            puts "  • #{error}"
          end
          puts ""
          raise WizardError, "Configuration validation failed"
        end
        
        puts ""
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
            puts ""
            puts "⚠️  Warning: Organization / Team Mismatch", :yellow
            puts "=" * 80
            puts ""
            puts "Your Xcode project uses team:     #{project_team}"
            puts "Current My Signer org:            #{org_name} (Team: #{org_team})"
            puts ""
            puts "This means your project belongs to a different Apple Developer account"
            puts "than the organization you're currently using in My Signer."
            puts ""
            puts "What this means:"
            puts "  • Profiles/certificates fetched will be for team #{org_team}"
            puts "  • But your project needs resources for team #{project_team}"
            puts "  • This will likely cause signing errors"
            puts ""
            puts "To fix this:"
            puts "  1. Exit this wizard (Ctrl+C)"
            puts "  2. Run: mysigner switch"
            puts "  3. Select the organization that has team #{project_team}"
            puts "  4. Run this wizard again"
            puts ""
            print "Continue anyway? (y/N): "
            answer = STDIN.gets.strip.downcase
            
            unless answer == 'y' || answer == 'yes'
              puts ""
              puts "Wizard cancelled. Please switch organizations and try again."
              exit 0
            end
            puts ""
          elsif !org_team
            # Current org has no team configured
            puts ""
            puts "ℹ️  Note: Current organization has no Team ID configured", :cyan
            puts "=" * 80
            puts ""
            puts "Your Xcode project uses team:     #{project_team}"
            puts "Current My Signer org:            #{org_name} (No team configured)"
            puts ""
            puts "You can continue, but the wizard won't be able to fetch the team from My Signer."
            puts "Consider adding Team ID to this org at: https://app.mysigner.app"
            puts ""
            print "Continue? (Y/n): "
            answer = STDIN.gets.strip.downcase
            
            if answer == 'n' || answer == 'no'
              puts ""
              puts "Wizard cancelled."
              exit 0
            end
            puts ""
          end
        rescue => e
          # Ignore errors in org checking - don't block the wizard
          puts "Warning: Could not verify organization match: #{e.message}" if ENV['DEBUG']
        end
      end

      def error(message)
        puts "✗ #{message}"
      end
    end
  end
end

