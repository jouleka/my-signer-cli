# frozen_string_literal: true

module Mysigner
  class CLI < Thor
    module ResourceCommands
      def self.included(base)
        base.class_eval do
          desc 'devices', 'List registered test devices (UDIDs)'
          method_option :platform, type: :string, aliases: '-p', desc: 'Filter by platform (IOS, MAC_OS, TV_OS)'
          method_option :status, type: :string, aliases: '-s', desc: 'Filter by status (ENABLED, DISABLED)'
          method_option :search, type: :string, aliases: '-q', desc: 'Search by name or UDID'
          method_option :page, type: :numeric, default: 1, desc: 'Page number'
          method_option :per_page, type: :numeric, default: 50, desc: 'Devices per page'
          def devices
            config = load_config
            client = create_client(config)

            say '📱 Devices', :cyan
            say ''

            # Build query params
            params = {
              page: options[:page],
              per_page: options[:per_page]
            }
            params[:platform] = options[:platform].upcase if options[:platform]
            params[:status] = options[:status].upcase if options[:status]
            params[:q] = options[:search] if options[:search]

            begin
              response = client.get("/api/v1/organizations/#{config.current_organization_id}/devices", params: params)
              devices = response[:data]['devices']
              pagination = response[:data]['pagination']

              if devices.empty?
                say 'No devices found', :yellow
                say ''
                say "Tip: Register a device with 'mysigner device add NAME UDID'", :yellow
                return
              end

              # Display devices
              devices.each do |device|
                status_icon = device['status'] == 'ENABLED' ? '✓' : '✗'
                status_color = device['status'] == 'ENABLED' ? :green : :red

                say "  #{status_icon} #{device['name']} (ID: #{device['id']})", status_color
                say "    UDID: #{device['udid']}"
                say "    Platform: #{device['platform']} | Class: #{device['device_class']}"
                say "    Status: #{device['status']}"
                say ''
              end

              # Show pagination
              if pagination
                say "Page #{pagination['page']} of #{pagination['total_pages']} (#{pagination['total']} total)", :yellow

                say "Run with --page #{pagination['page'] + 1} to see more", :yellow if pagination['page'] < pagination['total_pages']
              end
            rescue Mysigner::ClientError => e
              error "Failed to fetch devices: #{e.message}"
              exit 1
            end
          end

          desc 'device SUBCOMMAND', 'Manage test devices (detect, add, update)'
          long_desc <<~DESC
            Register and manage test devices for development builds.

            WHY REGISTER DEVICES?

            To install development/adhoc builds on physical devices, you must register
            their UDIDs (Unique Device Identifiers) with Apple and include them in your
            provisioning profiles.

            SUBCOMMANDS:

              mysigner device detect
              Auto-detect connected iOS devices and show their UDIDs
            #{'  '}
              mysigner device add NAME UDID [--platform IOS]
              Register a new device for testing
            #{'  '}
              mysigner device update ID NEW_NAME
              Rename an existing device

            HOW TO GET A DEVICE UDID:

            Method 1 - Auto-detect (Recommended):
              mysigner device detect
            #{'  '}
              This will find all connected iOS devices and let you register them
              interactively. No need to open any other apps.

            Method 2 - Via Finder:
              1. Connect your iPhone/iPad to your Mac
              2. Open Finder and select your device in the sidebar
              3. Click on the device info to reveal UDID
              4. Right-click → Copy UDID

            EXAMPLES:

              # Register your iPhone
              mysigner device add "My iPhone 15" 00008030-001A1B2C3D4E567F
            #{'  '}
              # Register an iPad
              mysigner device add "Test iPad" da83bb40dba39e35d258988d856508798db7afba
            #{'  '}
              # Register a Mac for Mac Catalyst apps
              mysigner device add "MacBook Pro" ABC123... --platform MAC_OS
            #{'  '}
              # Rename a device (use ID from 'mysigner devices' list)
              mysigner device update 42 "John's iPhone"

            NOTES:

            • UDIDs are 40 hex characters (0-9, a-f) or 25 characters for newer devices
            • You can register up to 100 devices per year per account
            • After registering, regenerate your provisioning profiles to include the device
            • Run 'mysigner devices' to see all registered devices
          DESC
          method_option :platform, type: :string, default: 'IOS', aliases: '-p', desc: 'Platform (IOS, MAC_OS, TV_OS)'
          def device(action, *args)
            config = load_config
            client = create_client(config)

            case action
            when 'detect'
              detect_connected_devices(config, client)
            when 'add'
              if args.length < 2
                error 'Usage: mysigner device add NAME UDID [--platform IOS]'
                say ''
                say 'Example: mysigner device add "My iPhone" 00008030-001A1B2C3D4E567F', :yellow
                say ''
                say "💡 Don't know your UDID? Run:", :cyan
                say '   mysigner device detect', :cyan
                say ''
                say '   This will auto-detect connected devices and let you register them.', :cyan
                exit 1
              end

              name = args[0]
              udid = args[1]
              platform = options[:platform].upcase

              # Client-side UDID sanity check — catches obvious typos and
              # copy-paste errors before they hit Apple's API (which, for IOS
              # at least, has historically accepted synthetic/all-zeros UDIDs
              # in sandbox environments). Skipped for non-IOS platforms.
              if (platform == 'IOS') && !valid_ios_udid?(udid)
                error "Invalid iOS UDID: #{udid}"
                say ''
                say 'iOS UDIDs must:', :yellow
                say '  • Be either 25 chars (older devices) or 40 hex chars (newer)', :cyan
                say '  • Be hexadecimal (0-9, A-F)', :cyan
                say '  • Not be trivially synthetic (e.g. all zeros, single repeated char)', :cyan
                say ''
                say '💡 Get a real UDID:', :cyan
                say '   mysigner device detect', :yellow
                exit 1
              end

              say '📱 Registering device...', :cyan
              say ''

              begin
                response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/devices",
                  body: {
                    name: name,
                    udid: udid,
                    platform: platform
                  }
                )

                device = response[:data]['device']
                say '✓ Device registered successfully!', :green
                say ''
                say 'Details:', :bold
                say "  Name:     #{device['name']}"
                say "  UDID:     #{device['udid']}"
                say "  Platform: #{device['platform']}"
                say "  Status:   #{device['status']}"
              rescue Mysigner::ValidationError => e
                error 'Validation failed:'
                if e.details
                  e.details.each do |field, errors|
                    say "  #{field}: #{errors.join(', ')}", :red
                  end
                else
                  say "  #{e.message}", :red
                end
                say "  Suggestion: #{e.suggestion}", :yellow if e.suggestion
                exit 1
              rescue Mysigner::ClientError => e
                if e.message.include?('already exists')
                  error 'Device with this UDID already exists'
                else
                  error "Failed to register device: #{e.message}"
                end
                exit 1
              end
            when 'update'
              if args.length < 2
                error 'Usage: mysigner device update ID NEW_NAME'
                say ''
                say "Example: mysigner device update 42 \"John's iPhone\"", :yellow
                say ''
                say '💡 To get device IDs:', :cyan
                say "   Run 'mysigner devices' to see all devices with their IDs", :cyan
                exit 1
              end

              device_id = args[0]
              new_name = args[1]

              say '📱 Updating device...', :cyan
              say ''

              begin
                # Get device details first
                response = client.get("/api/v1/organizations/#{config.current_organization_id}/devices/#{device_id}")
                device = response[:data]

                say "Current name: #{device['name']}", :yellow
                say "New name:     #{new_name}", :green
                say ''

                # Update device
                response = client.patch(
                  "/api/v1/organizations/#{config.current_organization_id}/devices/#{device_id}",
                  body: { name: new_name }
                )

                updated_device = response[:data]['device']
                say '✓ Device updated successfully!', :green
                say ''
                say 'Details:', :bold
                say "  Name:     #{updated_device['name']}"
                say "  UDID:     #{updated_device['udid']}"
                say "  Platform: #{updated_device['platform']}"
              rescue Mysigner::NotFoundError
                error "Device not found with ID: #{device_id}"
                exit 1
              rescue Mysigner::ClientError => e
                error "Failed to update device: #{e.message}"
                exit 1
              end
            when 'help'
              invoke :help, ['device']
            else
              error "Unknown action: #{action}"
              say 'Available actions: detect, add, update, help', :yellow
              exit 1
            end
          end

          private

          def detect_connected_devices(config, client)
            say '🔍 Detecting connected iOS devices...', :cyan
            say ''

            devices = []

            # Try system_profiler first (built-in macOS)
            if system('which system_profiler > /dev/null 2>&1')
              output = `system_profiler SPUSBDataType 2>/dev/null`

              # Parse iOS devices from system_profiler output
              current_device = nil
              output.each_line do |line|
                if line =~ /^\s{4}(\S.+):$/
                  # New top-level USB device
                  current_device = { name: ::Regexp.last_match(1).strip }
                elsif current_device
                  if line =~ /Serial Number:\s*([A-Fa-f0-9-]+)/
                    serial = ::Regexp.last_match(1).gsub('-', '')
                    # iOS device serials are typically 24-40 hex chars
                    current_device[:udid] = serial if serial.length.between?(24, 40)
                  elsif line =~ /Product ID:\s*(0x12[aA][0-9a-fA-F])/
                    # Apple mobile device product IDs start with 0x12a
                    current_device[:is_ios] = true
                  end
                end

                if current_device && current_device[:udid] && current_device[:is_ios]
                  devices << current_device
                  current_device = nil
                end
              end
            end

            # Also try idevice_id if available (more reliable)
            if system('which idevice_id > /dev/null 2>&1')
              output = `idevice_id -l 2>/dev/null`.strip
              output.each_line do |line|
                udid = line.strip
                next if udid.empty?

                # Get device name if ideviceinfo is available
                name = 'iOS Device'
                if system('which ideviceinfo > /dev/null 2>&1')
                  device_name = `ideviceinfo -u #{udid} -k DeviceName 2>/dev/null`.strip
                  name = device_name unless device_name.empty?
                end

                # Avoid duplicates
                devices << { name: name, udid: udid } unless devices.any? { |d| d[:udid] == udid }
              end
            end

            # Also try xcrun xctrace (Xcode command line tools)
            if devices.empty? && system('which xcrun > /dev/null 2>&1')
              # xctrace output can contain non-ASCII bytes (emoji in device
              # names, accented characters). Force UTF-8 + scrub invalid
              # sequences so `.strip` / `.each_line` don't raise
              # Encoding::CompatibilityError under the default US-ASCII locale.
              output = `xcrun xctrace list devices 2>/dev/null`.force_encoding('UTF-8').scrub
              in_devices_section = false

              output.each_line do |line|
                line = line.strip

                # Track sections
                if line == '== Devices =='
                  in_devices_section = true
                  next
                elsif line == '== Simulators =='
                  in_devices_section = false
                  next
                end

                next unless in_devices_section
                next if line.empty?

                # Format: "Name (Version) (UDID)" - iOS devices have UDIDs starting with 0000
                # Skip Macs which have UUID format
                next unless line =~ /^(.+?)\s+\([^)]+\)\s+\((0000[A-Fa-f0-9-]+)\)\s*$/

                name = ::Regexp.last_match(1).strip
                udid = ::Regexp.last_match(2).gsub('-', '')
                devices << { name: name, udid: udid }
              end
            end

            if devices.empty?
              say 'No iOS devices detected.', :yellow
              say ''
              say 'Make sure:', :cyan
              say '  1. Your device is connected via USB', :cyan
              say '  2. The device is unlocked', :cyan
              say "  3. You've trusted this computer on the device", :cyan
              say ''
              say '💡 For better detection, install libimobiledevice:', :yellow
              say '   brew install libimobiledevice', :yellow
              return
            end

            say "Found #{devices.length} device(s):", :green
            say ''

            devices.each_with_index do |device, idx|
              say "  #{idx + 1}. #{device[:name]}", :green
              say "     UDID: #{device[:udid]}", :white
              say ''
            end

            # Check if running interactively
            return unless $stdin.tty?

            # Ask if user wants to register
            say "Would you like to register a device? (Enter number, or 'n' to skip)", :cyan
            choice = ask('>')&.strip || ''

            return if choice.downcase == 'n' || choice.empty?

            idx = choice.to_i - 1
            if idx >= 0 && idx < devices.length
              device = devices[idx]

              say ''
              say "Enter a name for this device (or press Enter to use '#{device[:name]}'):", :cyan
              custom_name = ask('>')&.strip || ''
              name = custom_name.empty? ? device[:name] : custom_name

              say ''
              say "📱 Registering '#{name}'...", :cyan

              begin
                response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/devices",
                  body: {
                    name: name,
                    udid: device[:udid],
                    platform: 'IOS'
                  }
                )

                registered = response[:data]['device']
                say ''
                say '✓ Device registered successfully!', :green
                say "  Name:     #{registered['name']}"
                say "  UDID:     #{registered['udid']}"
                say "  Platform: #{registered['platform']}"
              rescue Mysigner::ClientError => e
                if e.message.include?('already exists')
                  say ''
                  say 'ℹ️  Device already registered', :yellow
                else
                  error "Failed to register: #{e.message}"
                end
              end
            else
              say 'Invalid selection', :red
            end
          end

          public

          desc 'profiles', 'List provisioning profiles (advanced - only needed for manual signing)'
          long_desc <<~DESC
            List all provisioning profiles in your organization.

            WHEN DO YOU NEED THIS?

            For Automatic Signing (Most Users):
              ❌ You DON'T need this - Xcode handles everything

            For Manual Signing (Advanced):
              ✅ View available profiles
              ✅ Check expiration dates
              ✅ Get profile IDs for download/delete

            EXAMPLES:

              # List all profiles
              mysigner profiles
            #{'  '}
              # Filter by type
              mysigner profiles --type APP_STORE
              mysigner profiles --type DEVELOPMENT
            #{'  '}
              # Filter by status
              mysigner profiles --status EXPIRED
            #{'  '}
              # Search by name
              mysigner profiles --search "MyApp"

            NOTE: Most users can skip this and just run 'mysigner build'
          DESC
          method_option :type, type: :string, aliases: '-t',
                               desc: 'Filter by type (DEVELOPMENT, AD_HOC, APP_STORE, ENTERPRISE)'
          method_option :status, type: :string, aliases: '-s', desc: 'Filter by status (ACTIVE, EXPIRED, INVALID)'
          method_option :search, type: :string, aliases: '-q', desc: 'Search by name or identifier'
          method_option :page, type: :numeric, default: 1, desc: 'Page number'
          method_option :per_page, type: :numeric, default: 50, desc: 'Profiles per page'
          def profiles
            config = load_config
            client = create_client(config)

            say '📄 Provisioning Profiles', :cyan
            say ''

            # Build query params
            params = {
              page: options[:page],
              per_page: options[:per_page]
            }
            params[:type] = options[:type].upcase if options[:type]
            params[:state] = options[:status].upcase if options[:status]
            params[:q] = options[:search] if options[:search]

            begin
              response = client.get("/api/v1/organizations/#{config.current_organization_id}/profiles", params: params)
              profiles = response[:data]['profiles']
              pagination = response[:data]['pagination']

              if profiles.empty?
                say 'No profiles found', :yellow
                say ''
                say 'Tip: Profiles are created automatically when you request code signing', :yellow
                return
              end

              # Display profiles
              profiles.each do |profile|
                status_icon = profile['state'] == 'ACTIVE' ? '✓' : '✗'
                status_color = profile['state'] == 'ACTIVE' ? :green : :red

                say "  #{status_icon} #{profile['name']}", status_color
                say "    ID: #{profile['id']} | Type: #{profile['profile_type'] || 'N/A'}"
                say "    Bundle ID: #{profile['bundle_id_identifier'] || 'N/A'}"
                say "    Status: #{profile['state'] || 'UNKNOWN'}"

                if profile['expires_at']
                  expires = Time.parse(profile['expires_at']).strftime('%Y-%m-%d')
                  say "    Expires: #{expires}"
                end

                say ''
              end

              # Show pagination
              if pagination
                say "Page #{pagination['page']} of #{pagination['total_pages']} (#{pagination['total']} total)", :yellow

                say "Run with --page #{pagination['page'] + 1} to see more", :yellow if pagination['page'] < pagination['total_pages']
              end
            rescue Mysigner::ClientError => e
              error "Failed to fetch profiles: #{e.message}"
              exit 1
            end
          end

          desc 'profile SUBCOMMAND', 'Download or delete profiles (advanced - only needed for manual signing)'
          long_desc <<~DESC
            Manage provisioning profiles for code signing.

            WHAT ARE PROVISIONING PROFILES?

            Provisioning profiles are required for signing iOS apps. They link:
            - Your signing certificate
            - Your App ID (bundle ID)
            - Authorized devices (for development/ad-hoc)

            WHEN DO YOU NEED THIS?

            For Automatic Signing (Most Users):
              ❌ You DON'T need these commands
              ✅ Xcode handles profiles automatically
              ✅ Just run: mysigner build

            For Manual Signing (Advanced):
              ✅ Download profiles from My Signer
              ✅ Install them to ~/Library/MobileDevice/Provisioning Profiles/
              ✅ Delete old/expired profiles

            SUBCOMMANDS:

              mysigner profile download ID [--output path]
              Download a provisioning profile
            #{'  '}
              mysigner profile delete ID
              Delete a provisioning profile

            HOW TO USE:

            1. List available profiles:
               mysigner profiles

            2. Download a profile:
               mysigner profile download 1

            3. Install it (double-click or manual):
               open Profile_Name.mobileprovision
               # Or: cp *.mobileprovision ~/Library/MobileDevice/Provisioning\\ Profiles/

            EXAMPLES:

              # Download profile ID 1
              mysigner profile download 1
            #{'  '}
              # Download to specific location
              mysigner profile download 1 --output ~/Desktop/MyProfile.mobileprovision
            #{'  '}
              # Delete expired profile
              mysigner profile delete 5
            #{'  '}
              # List all profiles
              mysigner profiles
            #{'  '}
              # Filter by type
              mysigner profiles --type APP_STORE

            NOTES:

            • Most users with Automatic signing don't need this
            • Manual signing wizard tries to auto-install profiles
            • Profiles expire after 1 year and must be regenerated
            • Development profiles: For testing on devices
            • App Store profiles: For production releases
          DESC
          method_option :output, type: :string, aliases: '-o', desc: 'Output file path (default: profile name)'
          def profile(action, *args)
            config = load_config
            client = create_client(config)

            case action
            when 'download'
              if args.empty?
                error 'Usage: mysigner profile download ID [--output path.mobileprovision]'
                say ''
                say 'Example: mysigner profile download 1', :yellow
                say ''
                say '💡 To get profile IDs:', :cyan
                say "   Run 'mysigner profiles' to see all profiles with their IDs", :cyan
                say ''
                say "Note: Most users with Automatic signing don't need this", :yellow
                say "Run 'mysigner help profile' for more info", :cyan
                exit 1
              end

              profile_id = args[0]

              say '📄 Downloading profile...', :cyan
              say ''

              begin
                # Get profile details first
                response = client.get("/api/v1/organizations/#{config.current_organization_id}/profiles/#{profile_id}")
                profile = response[:data]

                # Determine output path. Default to ~/Downloads/ (created if
                # missing) instead of the current working directory — users
                # were ending up with .mobileprovision files sprinkled inside
                # whatever project they ran the command from.
                output_path = if options[:output]
                                options[:output]
                              else
                                name = profile['name'] || "profile_#{profile['id']}"
                                filename = name.gsub(/[^0-9A-Za-z.-]/, '_')
                                downloads_dir = File.expand_path('~/Downloads')
                                FileUtils.mkdir_p(downloads_dir)
                                File.join(downloads_dir, "#{filename}.mobileprovision")
                              end

                # Download the profile content using the client's connection with auth
                download_url = "/api/v1/organizations/#{config.current_organization_id}/profiles/#{profile_id}/download"

                say 'Fetching profile content...', :yellow

                # Use Faraday directly with proper auth for binary download
                conn = Faraday.new(url: config.api_url) do |f|
                  f.request :authorization, 'Bearer', config.api_token
                  f.headers['X-User-Email'] = config.user_email if config.user_email
                  f.adapter Faraday.default_adapter
                end

                response = conn.get(download_url) do |req|
                  req.options.timeout = 30 # 30 second timeout
                  req.options.open_timeout = 10 # 10 second connection timeout
                end

                unless response.success?
                  # Check if it's a JSON error response
                  if response.headers['content-type']&.include?('json')
                    begin
                      error_data = JSON.parse(response.body)
                      error "Download failed: #{error_data['message'] || error_data['error']}"
                    rescue StandardError
                      error "Download failed with status #{response.status}"
                    end
                  else
                    error "Download failed with status #{response.status}"
                  end
                  exit 1
                end

                # Write binary content directly to file
                File.binwrite(output_path, response.body)

                say '✓ Profile downloaded successfully!', :green
                say ''
                say 'Details:', :bold
                say "  Name:      #{profile['name']}"
                say "  Type:      #{profile['profile_type'] || 'N/A'}"
                say "  Bundle ID: #{profile['bundle_id_identifier'] || 'N/A'}"
                say "  Status:    #{profile['state'] || 'UNKNOWN'}"
                say "  File:      #{output_path}"
                say ''
                say "File size: #{response.body.bytesize} bytes", :yellow
              rescue Mysigner::NotFoundError
                error "Profile not found with ID: #{profile_id}"
                say ''
                say '💡 Profile Not Found: How to fix', :cyan
                say ''
                say '   → List available profiles: mysigner profiles', :yellow
                say '   → Sync from Apple: mysigner sync ios', :yellow
                say '   → Check ID is correct (IDs are numeric)', :yellow
                say ''
                exit 1
              rescue Mysigner::ClientError => e
                error "Failed to download profile: #{e.message}"
                say ''
                say '💡 Download Failed: Try these steps', :cyan
                say ''
                say '   → Check your network connection', :yellow
                say '   → Verify API token is valid: mysigner status', :yellow
                say '   → Re-authenticate if needed: mysigner login', :yellow
                say ''
                exit 1
              rescue StandardError => e
                error "Failed to save file: #{e.message}"
                say ''
                say '💡 File Save Failed: Check these', :cyan
                say ''
                say '   → Verify you have write permissions to the directory', :yellow
                say '   → Check disk space is available', :yellow
                say '   → Try specifying a different output path with --output', :yellow
                say ''
                exit 1
              end
            when 'delete'
              if args.empty?
                error 'Usage: mysigner profile delete ID'
                say ''
                say 'Example: mysigner profile delete 5', :yellow
                say ''
                say '💡 To get profile IDs:', :cyan
                say "   Run 'mysigner profiles' to see all profiles with their IDs", :cyan
                exit 1
              end

              profile_id = args[0]

              say '📄 Deleting profile...', :cyan
              say ''

              begin
                # Get profile details first
                response = client.get("/api/v1/organizations/#{config.current_organization_id}/profiles/#{profile_id}")
                profile = response[:data]

                # Confirm deletion
                say 'You are about to delete:', :yellow
                say "  Name: #{profile['name']}"
                say "  Type: #{profile['profile_type']}"
                say "  Bundle ID: #{profile['bundle_id_identifier'] || 'N/A'}"
                say ''

                if yes?('Are you sure you want to delete this profile? (y/n)')
                  client.delete("/api/v1/organizations/#{config.current_organization_id}/profiles/#{profile_id}")
                  say ''
                  say '✓ Profile deleted successfully!', :green
                else
                  say 'Deletion cancelled', :yellow
                end
              rescue Mysigner::NotFoundError
                error "Profile not found with ID: #{profile_id}"
                exit 1
              rescue Mysigner::ClientError => e
                error "Failed to delete profile: #{e.message}"
                exit 1
              end
            when 'help'
              invoke :help, ['profile']
            else
              error "Unknown action: #{action}"
              say 'Available actions: download, delete, help', :yellow
              exit 1
            end
          end

          desc 'certificates', 'List signing certificates from App Store Connect'
          method_option :type, type: :string, aliases: '-p', desc: 'Filter by type (DEVELOPMENT, DISTRIBUTION)'
          method_option :status, type: :string, aliases: '-s', desc: 'Filter by status (ACTIVE, EXPIRED, REVOKED)'
          method_option :search, type: :string, aliases: '-q', desc: 'Search by name'
          method_option :page, type: :numeric, default: 1, desc: 'Page number'
          method_option :per_page, type: :numeric, default: 50, desc: 'Certificates per page'
          def certificates
            config = load_config
            client = create_client(config)

            say '🔐 Signing Certificates', :cyan
            say ''

            # Build query params
            params = {
              page: options[:page],
              per_page: options[:per_page]
            }
            params[:certificate_type] = options[:type].upcase if options[:type]
            params[:status] = options[:status].upcase if options[:status]
            params[:q] = options[:search] if options[:search]

            begin
              response = client.get("/api/v1/organizations/#{config.current_organization_id}/certificates",
                                    params: params)
              certificates = response[:data]['certificates']
              pagination = response[:data]['pagination']

              if certificates.empty?
                say 'No certificates found', :yellow
                say ''
                say 'Tip: Certificates are synced automatically from App Store Connect', :yellow
                return
              end

              # Display certificates
              certificates.each do |cert|
                status_icon = cert['status'] == 'ACTIVE' ? '✓' : '✗'
                status_color = cert['status'] == 'ACTIVE' ? :green : :red

                say "  #{status_icon} #{cert['name']}", status_color
                say "    ID: #{cert['id']} | Type: #{cert['certificate_type'] || 'N/A'}"
                say "    Serial: #{cert['serial_number'] || 'N/A'}"
                say "    Status: #{cert['status'] || 'UNKNOWN'}"

                if cert['expires_at']
                  expires = Time.parse(cert['expires_at']).strftime('%Y-%m-%d')
                  say "    Expires: #{expires}"
                end

                say ''
              end

              # Show pagination
              if pagination
                say "Page #{pagination['page']} of #{pagination['total_pages']} (#{pagination['total']} total)", :yellow

                say "Run with --page #{pagination['page'] + 1} to see more", :yellow if pagination['page'] < pagination['total_pages']
              end
            rescue Mysigner::ClientError => e
              error "Failed to fetch certificates: #{e.message}"
              exit 1
            end
          end

          desc 'certificate ACTION', 'Check local keychain or download certificates (check, download)'
          long_desc <<~DESC
            Actions:
              check              - Check certificates installed in your Mac's Keychain (not API)
              download ID        - Download a certificate from My Signer API

            Note: 'check' scans your LOCAL Keychain, not certificates in My Signer API.
                  Use 'mysigner certificates' to see API certificates.
          DESC
          method_option :output, type: :string, aliases: '-o', desc: 'Output file path (default: certificate name)'
          def certificate(action, *args)
            config = load_config
            client = create_client(config)

            case action
            when 'check'
              require_relative '../signing/certificate_checker'

              say '🔍 Checking local certificates...', :cyan
              say ''

              checker = Signing::CertificateChecker.new

              begin
                certificates = checker.check!

                if certificates.empty?
                  say 'No code signing certificates found in local Keychain', :yellow
                  say ''
                  say '⚠️  Important:', :yellow
                  say '  This command checks certificates INSTALLED ON YOUR MAC.', :white
                  say '  Certificates in My Signer API are not automatically installed locally.', :white
                  say ''
                  say 'To install certificates:', :cyan
                  say '  1. List certificates in My Signer: mysigner certificates', :white
                  say '  2. Download one: mysigner certificate download <ID>', :white
                  say '  3. Double-click the .cer file to install in Keychain', :white
                  say ''
                  say 'Or download from Apple Developer:', :cyan
                  say '  https://developer.apple.com/account/resources/certificates/list', :white
                  return
                end

                # Group by status
                by_status = checker.by_status

                # Show valid certificates
                if by_status[:valid].any?
                  say "✓ Valid Certificates (#{by_status[:valid].count})", :green
                  say ''
                  by_status[:valid].each do |cert|
                    say "  #{cert[:name]}", :green
                    say "    Type: #{cert[:type]}"
                    say "    Team: #{cert[:team_id] || 'Unknown'}"
                    say "    Expires: #{cert[:expires_at].strftime('%Y-%m-%d')} (#{cert[:days_until_expiry]} days)",
                        :white
                    say ''
                  end
                end

                # Show expiring soon certificates
                if by_status[:expiring_soon].any?
                  say "⚠️  Expiring Soon (#{by_status[:expiring_soon].count})", :yellow
                  say ''
                  by_status[:expiring_soon].each do |cert|
                    say "  #{cert[:name]}", :yellow
                    say "    Type: #{cert[:type]}"
                    say "    Team: #{cert[:team_id] || 'Unknown'}"
                    say "    Expires: #{cert[:expires_at].strftime('%Y-%m-%d')} (#{cert[:days_until_expiry]} days)",
                        :yellow
                    say ''
                  end
                  say 'Renew these certificates soon to avoid build failures!', :yellow
                  say ''
                end

                # Show expired certificates
                if by_status[:expired].any?
                  say "✗ Expired Certificates (#{by_status[:expired].count})", :red
                  say ''
                  by_status[:expired].each do |cert|
                    say "  #{cert[:name]}", :red
                    say "    Type: #{cert[:type]}"
                    say "    Team: #{cert[:team_id] || 'Unknown'}"
                    say "    Expired: #{cert[:expires_at].strftime('%Y-%m-%d')} (#{cert[:days_until_expiry].abs} days ago)",
                        :red
                    say ''
                  end
                  say 'These certificates will cause build failures. Renew them at:', :red
                  say '  https://developer.apple.com/account/resources/certificates/list', :white
                  say ''
                end

                # Summary
                say '─' * 80, :cyan
                say "Total: #{certificates.count} certificate#{'s' unless certificates.one?} installed locally",
                    :cyan
                if checker.has_issues?
                  say 'Status: ⚠️  Action required', :yellow
                else
                  say 'Status: ✓ All certificates valid', :green
                end
                say ''
                say '💡 Tip: These are certificates INSTALLED ON YOUR MAC.', :cyan
                say '    To see all certificates in My Signer API, run: mysigner certificates', :white
              rescue Signing::CertificateChecker::CheckError => e
                error "Certificate check failed: #{e.message}"
                say ''
                say 'This usually means:', :yellow
                say '  • Keychain is locked', :white
                say '  • No certificates installed', :white
                say '  • Security command not available', :white
                exit 1
              end

            when 'download'
              if args.empty?
                error 'Usage: mysigner certificate download ID [--output path.cer]'
                exit 1
              end

              certificate_id = args[0]

              say '🔐 Downloading certificate...', :cyan
              say ''

              begin
                # Get certificate details first
                response = client.get("/api/v1/organizations/#{config.current_organization_id}/certificates/#{certificate_id}")
                certificate = response[:data]

                # Determine output path. Default to ~/Downloads/ (mirrors
                # profile download behavior) rather than the CWD to avoid
                # dropping .cer files inside the user's project tree.
                output_path = if options[:output]
                                options[:output]
                              else
                                name = certificate['name'] || "certificate_#{certificate['id']}"
                                filename = name.gsub(/[^0-9A-Za-z.-]/, '_')
                                downloads_dir = File.expand_path('~/Downloads')
                                FileUtils.mkdir_p(downloads_dir)
                                File.join(downloads_dir, "#{filename}.cer")
                              end

                # Download the certificate content (binary response)
                download_url = "/api/v1/organizations/#{config.current_organization_id}/certificates/#{certificate_id}/download"

                say 'Fetching certificate content...', :yellow

                # Use Faraday directly with proper auth for binary download
                conn = Faraday.new(url: config.api_url) do |f|
                  f.request :authorization, 'Bearer', config.api_token
                  f.headers['X-User-Email'] = config.user_email if config.user_email
                  f.adapter Faraday.default_adapter
                end

                response = conn.get(download_url) do |req|
                  req.options.timeout = 30 # 30 second timeout
                  req.options.open_timeout = 10 # 10 second connection timeout
                end

                unless response.success?
                  # Check if it's a JSON error response
                  if response.headers['content-type']&.include?('json')
                    begin
                      error_data = JSON.parse(response.body)
                      error "Download failed: #{error_data['message'] || error_data['error']}"
                    rescue StandardError
                      error "Download failed with status #{response.status}"
                    end
                  else
                    error "Download failed with status #{response.status}"
                  end
                  exit 1
                end

                # Write binary content directly to file
                File.binwrite(output_path, response.body)

                say '✓ Certificate downloaded successfully!', :green
                say ''
                say 'Details:', :bold
                say "  Name:      #{certificate['name']}"
                say "  Type:      #{certificate['certificate_type'] || 'N/A'}"
                say "  Serial:    #{certificate['serial_number'] || 'N/A'}"
                say "  Status:    #{certificate['status'] || 'UNKNOWN'}"
                say "  File:      #{output_path}"
                say ''
                say "File size: #{response.body.bytesize} bytes", :yellow
              rescue Mysigner::NotFoundError
                error "Certificate not found with ID: #{certificate_id}"
                say ''
                say '💡 Certificate Not Found: How to fix', :cyan
                say ''
                say '   → List available certificates: mysigner certificates', :yellow
                say '   → Sync from Apple: mysigner sync ios', :yellow
                say '   → Check the ID is correct (IDs are numeric)', :yellow
                say ''
                exit 1
              rescue Mysigner::ClientError => e
                error "Failed to download certificate: #{e.message}"
                say ''
                say '💡 Download Failed: Try these steps', :cyan
                say ''
                say '   → Check your network connection', :yellow
                say '   → Verify API token is valid: mysigner status', :yellow
                say '   → Re-authenticate if needed: mysigner login', :yellow
                say ''
                exit 1
              rescue StandardError => e
                error "Failed to save file: #{e.message}"
                say ''
                say '💡 File Save Failed: Check these', :cyan
                say ''
                say '   → Verify you have write permissions to the directory', :yellow
                say '   → Check disk space is available', :yellow
                say '   → Try specifying a different output path with --output', :yellow
                say ''
                exit 1
              end
            when 'help'
              invoke :help, ['certificate']
            else
              error "Unknown action: #{action}"
              say 'Available actions: check, download, help', :yellow
              exit 1
            end
          end

          # ==================== ANDROID KEYSTORES ====================

          desc 'keystore SUBCOMMAND', 'Manage Android keystores (list, upload, download, delete, activate)'
          long_desc <<~DESC
            Manage Android keystores for signing your apps.

            WHAT IS A KEYSTORE?

            A keystore (.jks or .keystore file) contains the private key used to sign
            your Android app. The same keystore must be used for all updates to your app.

            SUBCOMMANDS:

              mysigner keystore list
              List all keystores

              mysigner keystore upload PATH
              Upload a new keystore to My Signer

              mysigner keystore download ID
              Download a keystore to use locally

              mysigner keystore delete ID
              Delete a keystore from My Signer

              mysigner keystore activate ID
              Set a keystore as the active/default one

            EXAMPLES:

              # List all keystores
              mysigner keystore list

              # Upload your release keystore
              mysigner keystore upload ~/keys/release.jks

              # Download keystore ID 1
              mysigner keystore download 1

              # Make keystore ID 2 the default
              mysigner keystore activate 2

              # Delete old keystore
              mysigner keystore delete 3

            SECURITY:

              • Keystores are stored encrypted on My Signer servers
              • Downloaded keystores are stored in ~/.mysigner/keystores/
              • Never commit keystores to version control
              • Keep backup copies in a secure location
          DESC
          method_option :name, type: :string, desc: 'Name for the keystore'
          method_option :alias, type: :string, desc: 'Key alias in the keystore'
          method_option :app_id, type: :numeric, desc: 'Associate with Android app ID'
          method_option :output, type: :string, aliases: '-o', desc: 'Output path for download'
          def keystore(action, *args)
            config = load_config
            client = create_client(config)

            require_relative '../signing/keystore_manager'
            manager = Signing::KeystoreManager.new(client, config.current_organization_id)

            case action
            when 'list'
              say '🔐 Android Keystores', :cyan
              say ''

              keystores = manager.list(android_app_id: options[:app_id])

              if keystores.empty?
                say 'No keystores found', :yellow
                say ''
                say 'Upload a keystore with: mysigner keystore upload PATH', :yellow
                return
              end

              keystores.each do |ks|
                active_icon = ks['active'] ? '✓' : '○'
                active_color = ks['active'] ? :green : :white

                say "  #{active_icon} #{ks['name']} (ID: #{ks['id']})", active_color
                say "    Key Alias: #{ks['key_alias'] || 'N/A'}"
                say "    App: #{ks['package_name']}" if ks['package_name']
                say "    Active: #{ks['active'] ? 'Yes' : 'No'}"
                say ''
              end

              say "Total: #{keystores.count} keystore(s)", :yellow

            when 'upload'
              keystore_path = args[0]

              unless keystore_path
                error 'Usage: mysigner keystore upload PATH'
                say ''
                say 'Example: mysigner keystore upload ~/keys/release.jks', :yellow
                exit 1
              end

              unless File.exist?(keystore_path)
                error "File not found: #{keystore_path}"
                exit 1
              end

              say '🔐 Uploading keystore...', :cyan
              say ''

              # Phase 0: support non-TTY automation. `ask(echo: false)` raises
              # Errno::ENOTTY on piped stdin, which made `keystore upload`
              # unusable from CI. When stdin isn't a TTY, require passwords
              # to come from env vars (MYSIGNER_KEYSTORE_PASSWORD /
              # MYSIGNER_KEY_PASSWORD) so operators can script uploads
              # without also having to wrap every invocation in `expect`.
              name = options[:name] || ask("Keystore name (e.g., 'Release Key'):")
              key_alias = options[:alias] || ask('Key alias:')

              if $stdin.tty?
                password = ask('Keystore password:', echo: false)
                say ''
                key_password = ask('Key password (press Enter if same as keystore):', echo: false)
                say ''
                key_password = password if key_password.empty?
              else
                password = ENV.fetch('MYSIGNER_KEYSTORE_PASSWORD', nil)
                key_password = ENV['MYSIGNER_KEY_PASSWORD'] || password
                if password.nil? || password.empty?
                  error 'Non-interactive upload requires MYSIGNER_KEYSTORE_PASSWORD (and optionally MYSIGNER_KEY_PASSWORD) in the environment.'
                  say ''
                  say 'Example:', :cyan
                  say '  MYSIGNER_KEYSTORE_PASSWORD=... MYSIGNER_KEY_PASSWORD=... \\', :yellow
                  say '    mysigner keystore upload ./release.jks --name "Release" --alias myalias', :yellow
                  exit 1
                end
              end

              begin
                result = manager.upload(
                  name: name,
                  keystore_path: keystore_path,
                  keystore_password: password,
                  key_alias: key_alias,
                  key_password: key_password,
                  android_app_id: options[:app_id],
                  active: true
                )

                say '✓ Keystore uploaded successfully!', :green
                say ''
                say 'Details:', :bold
                say "  ID:        #{result['id']}"
                say "  Name:      #{result['name']}"
                say "  Key Alias: #{result['key_alias']}"
                say "  Active:    #{result['active']}"
                say ''
              rescue Signing::KeystoreManager::KeystoreError => e
                error "Upload failed: #{e.message}"
                say ''
                say '💡 Keystore Upload Failed: Common issues', :cyan
                say ''
                say '   → Verify the keystore file is valid (.jks or .keystore)', :yellow
                say '   → Check keystore password is correct', :yellow
                say '   → Check key alias exists in the keystore', :yellow
                say '   → Verify key password is correct', :yellow
                say ''
                say "   Test with: keytool -list -keystore #{keystore_path}", :green
                say ''
                exit 1
              rescue Mysigner::ClientError => e
                error "API error: #{e.message}"
                say ''
                say '💡 API Error: Try these steps', :cyan
                say ''
                say '   → Check your network connection', :yellow
                say '   → Verify API token is valid: mysigner status', :yellow
                say '   → Re-authenticate if needed: mysigner login', :yellow
                say ''
                exit 1
              end

            when 'download'
              keystore_id = args[0]

              unless keystore_id
                error 'Usage: mysigner keystore download ID'
                say ''
                say "Run 'mysigner keystore list' to see available IDs", :yellow
                exit 1
              end

              say '🔐 Downloading keystore...', :cyan
              say ''

              begin
                result = manager.download(keystore_id)

                # Move to custom output path if specified
                if options[:output]
                  FileUtils.mv(result[:path], options[:output])
                  result[:path] = options[:output]
                end

                say '✓ Keystore downloaded!', :green
                say ''
                say 'Details:', :bold
                say "  Name:      #{result[:name]}"
                say "  Key Alias: #{result[:key_alias]}"
                say "  Path:      #{result[:path]}"
                say ''
                say '⚠️  Keep this file secure and backed up!', :yellow
              rescue Signing::KeystoreManager::KeystoreNotFoundError => e
                error "Keystore not found: #{e.message}"
                say ''
                say '💡 Keystore Not Found: How to fix', :cyan
                say ''
                say '   → List available keystores: mysigner keystore list', :yellow
                say '   → Upload a keystore: mysigner keystore upload <path>', :yellow
                say '   → Check the ID is correct (IDs are numeric)', :yellow
                say ''
                exit 1
              rescue Signing::KeystoreManager::DownloadError => e
                error "Download failed: #{e.message}"
                say ''
                say '💡 Download Failed: Try these steps', :cyan
                say ''
                say '   → Check your network connection', :yellow
                say '   → Verify API token is valid: mysigner status', :yellow
                say '   → Re-authenticate if needed: mysigner login', :yellow
                say ''
                exit 1
              end

            when 'delete'
              keystore_id = args[0]

              unless keystore_id
                error 'Usage: mysigner keystore delete ID'
                exit 1
              end

              # Get keystore details first
              keystores = manager.list
              keystore = keystores.find { |k| k['id'].to_s == keystore_id.to_s }

              unless keystore
                error "Keystore not found with ID: #{keystore_id}"
                say ''
                say '💡 Keystore Not Found: How to fix', :cyan
                say ''
                say '   → List available keystores: mysigner keystore list', :yellow
                say '   → Upload a keystore: mysigner keystore upload <path>', :yellow
                say ''
                exit 1
              end

              say '⚠️  You are about to delete:', :yellow
              say "  Name: #{keystore['name']}"
              say "  Key Alias: #{keystore['key_alias']}"
              say ''

              if yes?('Are you sure? This cannot be undone. (y/n)')
                begin
                  manager.delete(keystore_id)
                  say ''
                  say '✓ Keystore deleted', :green
                rescue Mysigner::ClientError => e
                  error "Delete failed: #{e.message}"
                  exit 1
                end
              else
                say 'Deletion cancelled', :yellow
              end

            when 'activate'
              keystore_id = args[0]

              unless keystore_id
                error 'Usage: mysigner keystore activate ID'
                exit 1
              end

              say '🔐 Activating keystore...', :cyan

              begin
                result = manager.activate(keystore_id)
                say '✓ Keystore activated!', :green
                say ''
                say "#{result['name']} is now the default keystore", :cyan
              rescue Mysigner::NotFoundError
                error "Keystore not found with ID: #{keystore_id}"
                say ''
                say '💡 Keystore Not Found: How to fix', :cyan
                say ''
                say '   → List available keystores: mysigner keystore list', :yellow
                say '   → Upload a keystore: mysigner keystore upload <path>', :yellow
                say ''
                exit 1
              rescue Mysigner::ClientError => e
                error "Activation failed: #{e.message}"
                say ''
                say '💡 Activation Failed: Try these steps', :cyan
                say ''
                say '   → Verify keystore ID is correct: mysigner keystore list', :yellow
                say '   → Check API token is valid: mysigner status', :yellow
                say ''
                exit 1
              end

            when 'help'
              invoke :help, ['keystore']
            else
              error "Unknown action: #{action}"
              say 'Available actions: list, upload, download, delete, activate, help', :yellow
              exit 1
            end
          end

          # ==================== ANDROID APP REGISTRATION ====================

          desc 'android SUBCOMMAND', 'Android commands (init, add, build, list)'
          long_desc <<~DESC
            Register and manage Android apps with My Signer.

            SUBCOMMANDS:

              mysigner android init
              Auto-detect package name from current project and register.
              Works with native Android, React Native, Capacitor, and Expo.

              mysigner android add PACKAGE_NAME [--name NAME]
              Manually register an app by package name.

              mysigner android build
              Build an AAB file for upload to Google Play Console.
              Use this for your FIRST upload (required before mysigner ship works).

              mysigner android list
              List registered Android apps (alias for 'mysigner apps --platform android')

            FIRST-TIME SETUP:

              Google Play requires the first build to be uploaded manually.
              After that, mysigner ship works automatically.

              1. mysigner android init          # Register app
              2. mysigner android build         # Build AAB
              3. Upload AAB in Play Console     # One-time manual step
              4. mysigner ship internal --platform android  # Works from now on!

            EXAMPLES:

              # Auto-detect from project directory
              cd my-expo-app && mysigner android init

              # Build AAB for first upload
              mysigner android build

              # Manually add an app
              mysigner android add com.example.myapp --name "My App"
          DESC
          method_option :name, type: :string, desc: 'Display name for the app'
          def android(action, *args)
            config = load_config
            client = create_client(config)

            case action
            when 'init'
              android_init(config, client)
            when 'add'
              if args.empty?
                error 'Usage: mysigner android add PACKAGE_NAME [--name NAME]'
                say ''
                say 'Example: mysigner android add com.example.myapp --name "My App"', :yellow
                exit 1
              end
              android_add(config, client, args[0], options[:name])
            when 'build'
              android_build
            when 'list'
              # Delegate to apps command with android platform
              invoke :apps, [], platform: 'android'
            when 'help'
              invoke :help, ['android']
            else
              error "Unknown action: #{action}"
              say 'Available actions: init, add, build, list, help', :yellow
              exit 1
            end
          end

          private

          def android_init(config, client)
            require_relative '../build/android_parser'

            say '🔍 Detecting project...', :cyan
            say ''

            package_name = nil
            app_name = nil
            project_type = nil

            # Try native/cross-platform detection first
            begin
              project_info = Build::Detector.detect_android(Dir.pwd)
              parser = Build::AndroidParser.new(project_info)
              package_name = parser.application_id
              app_name = parser.app_name
              project_type = project_info[:framework]&.to_s&.gsub('_', ' ')&.capitalize || 'Native Android'
            rescue Build::Detector::NoProjectError
              # Try Expo fallback
              expo_config = parse_expo_config(Dir.pwd)
              if expo_config && expo_config[:package_name]
                package_name = expo_config[:package_name]
                app_name = expo_config[:name]
                project_type = 'Expo managed'
              else
                error 'No Android project or Expo config found'
                say ''
                say "For Expo managed projects, add 'android.package' to app.json:", :yellow
                say ''
                say '  {', :white
                say '    "expo": {', :white
                say '      "android": { "package": "com.yourcompany.app" }', :white
                say '    }', :white
                say '  }', :white
                say ''
                say 'Or run from a directory with an android/ folder (native/RN/Capacitor).', :yellow
                exit 1
              end
            end

            say "✓ Found: #{project_type} project", :green
            say ''
            say "📦 Package: #{package_name}", :cyan
            say "📱 Name: #{app_name || '(not set)'}", :cyan
            say ''

            # Check if app already exists
            begin
              response = client.get(
                "/api/v1/organizations/#{config.current_organization_id}/android_apps",
                params: { q: package_name }
              )
              existing_apps = response[:data]['android_apps'] || []
              existing = existing_apps.find { |a| a['package_name'] == package_name }

              if existing
                say 'ℹ️  App already registered!', :yellow
                say ''
                say 'Details:', :bold
                say "  ID:      #{existing['id']}"
                say "  Name:    #{existing['name'] || '(not set)'}"
                say "  Package: #{existing['package_name']}"
                say "  Builds:  #{existing['builds_count'] || 0}"
                say ''
                say 'Next steps:', :cyan
                if (existing['builds_count'] || 0).positive?
                  say '  • Ship to Play Store: mysigner ship internal --platform android', :white
                else
                  say '  1. Build AAB: mysigner android build', :white
                  say '  2. Upload first build manually in Play Console (one-time requirement)', :white
                  say '  3. After that: mysigner ship internal --platform android', :white
                end
                return
              end
            rescue Mysigner::ClientError => e
              # Ignore lookup errors, proceed with creation
            end

            # Register the app
            say '🔗 Registering with My Signer...', :cyan

            begin
              response = client.post(
                "/api/v1/organizations/#{config.current_organization_id}/android_apps",
                body: { android_app: {
                  package_name: package_name,
                  name: app_name
                } }
              )

              app = response[:data]['android_app'] || response[:data]
              say '✓ App registered successfully!', :green
              say ''
              say 'Details:', :bold
              say "  ID:      #{app['id']}"
              say "  Name:    #{app['name'] || '(not set)'}"
              say "  Package: #{app['package_name']}"
              say ''
              say 'Next steps:', :cyan
              say '  1. Create app in Google Play Console', :white
              say '  2. Build AAB: mysigner android build', :white
              say '  3. Upload first build manually in Play Console (one-time requirement)', :white
              say '  4. After that: mysigner ship internal --platform android', :white
            rescue Mysigner::ValidationError => e
              error 'Validation failed:'
              if e.details
                e.details.each do |field, errors|
                  say "  #{field}: #{errors.join(', ')}", :red
                end
              else
                say "  #{e.message}", :red
              end
              say "  Suggestion: #{e.suggestion}", :yellow if e.suggestion
              exit 1
            rescue Mysigner::ClientError => e
              error "Failed to register app: #{e.message}"
              exit 1
            end
          end

          def android_add(config, client, package_name, name = nil)
            say '📦 Registering Android app...', :cyan
            say ''
            say "  Package: #{package_name}", :white
            say "  Name:    #{name || '(will be synced from Play Store)'}", :white
            say ''

            begin
              response = client.post(
                "/api/v1/organizations/#{config.current_organization_id}/android_apps",
                body: { android_app: {
                  package_name: package_name,
                  name: name
                }.compact }
              )

              app = response[:data]['android_app'] || response[:data]
              say '✓ App registered successfully!', :green
              say ''
              say 'Details:', :bold
              say "  ID:      #{app['id']}"
              say "  Name:    #{app['name'] || '(not set)'}"
              say "  Package: #{app['package_name']}"
              say ''
              say 'Next steps:', :cyan
              if (app['builds_count'] || 0).positive?
                say '  • Ship to Play Store: mysigner ship internal --platform android', :white
              else
                say '  1. Create app in Google Play Console (if not done)', :white
                say '  2. Build AAB: mysigner android build', :white
                say '  3. Upload first build manually in Play Console', :white
                say '  4. Then use: mysigner ship internal --platform android', :white
              end
            rescue Mysigner::ValidationError => e
              error 'Validation failed:'
              if e.details
                e.details.each do |field, errors|
                  say "  #{field}: #{errors.join(', ')}", :red
                end
              else
                say "  #{e.message}", :red
              end
              say "  Suggestion: #{e.suggestion}", :yellow if e.suggestion
              exit 1
            rescue Mysigner::ClientError => e
              if e.message.include?('already exists') || e.message.include?('taken')
                error 'An app with this package name already exists'
                say ''
                say 'List your apps with: mysigner android list', :yellow
              else
                error "Failed to register app: #{e.message}"
              end
              exit 1
            end
          end

          def android_build
            say '🔨 Building Android App Bundle (AAB)...', :cyan
            say ''

            begin
              require_relative '../build/android_parser'
              require_relative '../signing/keystore_manager'

              project_dir = Dir.pwd
              is_expo = expo_project?(project_dir)

              # For Expo, we may need to regenerate android folder with correct versionCode
              # Get package name from app.json first if Expo
              if is_expo
                expo_config = parse_expo_config(project_dir)
                package_name = expo_config[:package_name]
                local_version_code = expo_config[:version_code] || 1
                version_name = expo_config[:version] || '1.0.0'

                # Check highest version code from API
                highest_version_code = fetch_highest_version_code(package_name)
                version_code = local_version_code
                needs_increment = highest_version_code && local_version_code <= highest_version_code

                if needs_increment
                  version_code = highest_version_code + 1

                  # Check if android folder already has the correct versionCode
                  android_dir = File.join(project_dir, 'android')
                  current_android_version = nil
                  if Dir.exist?(android_dir)
                    build_gradle = File.join(android_dir, 'app', 'build.gradle')
                    if File.exist?(build_gradle)
                      content = File.read(build_gradle)
                      current_android_version = ::Regexp.last_match(1).to_i if content =~ /versionCode\s+(\d+)/
                    end
                  end

                  say '🔧 Framework: Expo (React Native)', :white
                  say "📦 Package: #{package_name}", :white

                  if current_android_version == version_code
                    # Android folder already has correct version, no need to regenerate
                    say "🔢 Version: #{version_name} (#{version_code})", :white
                    say '   ↳ Already at correct version code', :green
                  else
                    say "🔢 Version: #{version_name} (#{local_version_code} → #{version_code})", :white
                    say "   ↳ Auto-incremented (#{highest_version_code} already on Play Store)", :yellow
                    say ''

                    # Regenerate android folder with new versionCode
                    say "🔄 Regenerating android folder with version code #{version_code}...", :yellow
                    regenerate_expo_android(project_dir, version_code)
                  end
                end
              end

              # Now detect project (android folder should exist)
              project_info = Build::Detector.detect_android(project_dir)
              framework = project_info[:framework]
              parser = Build::AndroidParser.new(project_info)

              package_name ||= parser.application_id
              version_name ||= parser.version_name
              local_version_code ||= parser.version_code.to_i
              android_dir = project_info[:android_directory] || File.join(project_info[:directory], 'android')

              # For non-Expo, check version code now
              if is_expo
                # Expo - already printed above, just show if no increment was needed
                unless needs_increment
                  say '🔧 Framework: Expo (React Native)', :white
                  say "📦 Package: #{package_name}", :white
                  say "🔢 Version: #{version_name} (#{version_code})", :white
                end
              else
                say "🔧 Framework: #{framework.to_s.gsub('_', ' ').capitalize}", :white
                say "📦 Package: #{package_name}", :white

                highest_version_code = fetch_highest_version_code(package_name)
                version_code = local_version_code

                if highest_version_code && local_version_code <= highest_version_code
                  version_code = highest_version_code + 1
                  say "🔢 Version: #{version_name} (#{local_version_code} → #{version_code})", :white
                  say "   ↳ Auto-incremented (#{highest_version_code} already on Play Store)", :yellow
                else
                  say "🔢 Version: #{version_name} (#{version_code})", :white
                end
              end
              say ''

              # Try to get keystore from MySigner
              keystore_info = fetch_keystore_for_build(package_name)
              if keystore_info
                say "🔐 Keystore: #{keystore_info[:name]}", :green
              else
                say '⚠️  No keystore configured - will use debug signing', :yellow
                say "   Run 'mysigner android init' to set up release signing", :yellow
              end
              say ''
              say '⏱️  This may take a few minutes...', :yellow
              say ''

              # Build based on framework (pass version_code override if incremented)
              # For Expo, we already regenerated with correct version, so no override needed
              version_code_override = nil
              unless is_expo
                version_code_override = version_code == local_version_code ? nil : version_code
              end

              aab_path = case framework
                         when :flutter
                           build_flutter_aab(project_dir, keystore_info, version_code_override)
                         when :maui, :xamarin, :xamarin_forms
                           build_dotnet_aab(project_dir, project_info[:csproj_path], framework, keystore_info,
                                            version_code_override)
                         when :react_native, :capacitor, :native
                           build_gradle_aab(android_dir, framework, keystore_info, version_code_override)
                         else
                           build_gradle_aab(android_dir, framework, keystore_info, version_code_override)
                         end

              unless aab_path && File.exist?(aab_path)
                error 'AAB file not found after build'
                say 'Check build output for errors.', :yellow
                exit 1
              end

              say ''
              say '=' * 80, :green
              say '✓ Build complete!', :green
              say '=' * 80, :green
              say ''
              say "📦 AAB: #{aab_path}", :cyan
              say "📊 Size: #{format_bytes(File.size(aab_path))}", :cyan
              say ''
              say 'Next step:', :bold
              say '  Upload this AAB to Google Play Console → Internal testing → Create release', :white
              say ''
              say 'After uploading, you can use:', :cyan
              say '  mysigner ship internal --platform android', :green
              say ''

              # Open the folder containing the AAB
              aab_dir = File.dirname(aab_path)
              say '📂 Opening folder...', :yellow
              case RUBY_PLATFORM
              when /darwin/
                system('open', aab_dir)
              when /linux/
                system('xdg-open', aab_dir)
              when /mingw|mswin/
                system('explorer', aab_dir.gsub('/', '\\'))
              end
            rescue Build::Detector::NoProjectError => e
              error e.message
              say ''
              say 'Run this command from an Android project directory.', :yellow
              exit 1
            rescue StandardError => e
              error "Build failed: #{e.message}"
              exit 1
            end
          end

          def build_flutter_aab(project_dir, keystore_info = nil, version_code_override = nil)
            # Check for flutter
            unless system('which flutter > /dev/null 2>&1')
              error 'Flutter not found in PATH'
              say 'Install Flutter: https://flutter.dev/docs/get-started/install', :yellow
              exit 1
            end

            # Phase 0: do NOT write plaintext key.properties into the user's
            # project tree. Use a two-step build so we can inject signing via
            # a Gradle init script on the Gradle step only. Env vars are set
            # on the child process; passwords never appear in argv or on disk.
            require_relative '../signing/gradle_signing_injector'

            injector = nil
            env = {}
            init_path = nil

            if keystore_info
              injector = Mysigner::Signing::GradleSigningInjector.new
              init_path = injector.write_init_script!
              env = keystore_info[:signing_env_vars] || injector.env_vars(
                keystore_path: keystore_info[:path],
                store_password: keystore_info[:password],
                key_password: keystore_info[:key_password],
                key_alias: keystore_info[:key_alias]
              )
            end

            begin
              Dir.chdir(project_dir) do
                if keystore_info
                  # Step 1: Flutter prepares the Gradle project (no signing needed).
                  prepare_args = ['flutter', 'build', 'appbundle', '--release', '--config-only']
                  prepare_args += ['--build-number', version_code_override.to_s] if version_code_override
                  unless system(env, *prepare_args)
                    error 'Flutter prebuild (--config-only) failed'
                    exit 1
                  end

                  # Step 2: invoke Gradle directly so we can pass --init-script.
                  Dir.chdir(File.join(project_dir, 'android')) do
                    gradle_args = ['./gradlew', 'bundleRelease', '--warning-mode=all', '--init-script', init_path]
                    gradle_args << "-PversionCode=#{version_code_override}" if version_code_override
                    unless system(env, *gradle_args)
                      error 'Gradle bundleRelease failed'
                      exit 1
                    end
                  end
                else
                  # No keystore: plain Flutter build (debug signing).
                  args = ['flutter', 'build', 'appbundle', '--release']
                  args += ['--build-number', version_code_override.to_s] if version_code_override
                  unless system(*args)
                    error 'Flutter build failed'
                    exit 1
                  end
                end
              end
            ensure
              injector&.cleanup!
            end

            # Flutter outputs to build/app/outputs/bundle/release/
            aab_path = File.join(project_dir, 'build/app/outputs/bundle/release/app-release.aab')
            unless File.exist?(aab_path)
              alt_paths = Dir.glob(File.join(project_dir, 'build/app/outputs/bundle/*/*.aab'))
              aab_path = alt_paths.first if alt_paths.any?
            end
            aab_path
          end

          def expo_project?(directory)
            # Check for Expo markers
            (File.exist?(File.join(directory, 'app.json')) || File.exist?(File.join(directory, 'app.config.js'))) &&
              File.exist?(File.join(directory, 'package.json')) &&
              File.read(File.join(directory, 'package.json')).include?('expo')
          end

          def regenerate_expo_android(project_dir, new_version_code)
            app_json_path = File.join(project_dir, 'app.json')
            android_dir = File.join(project_dir, 'android')
            local_props_path = File.join(android_dir, 'local.properties')

            # Preserve local.properties if it exists
            local_props_content = File.read(local_props_path) if File.exist?(local_props_path)

            # Read original app.json
            original_content = File.read(app_json_path)
            config = JSON.parse(original_content)

            # Set the new versionCode
            config['expo'] ||= {}
            config['expo']['android'] ||= {}
            config['expo']['android']['versionCode'] = new_version_code

            # Write modified app.json
            File.write(app_json_path, JSON.pretty_generate(config))

            begin
              # Delete existing android folder

              FileUtils.rm_rf(android_dir)

              # Run expo prebuild
              Dir.chdir(project_dir) do
                success = system('npx', 'expo', 'prebuild', '--platform', 'android', '--clean')
                raise 'expo prebuild failed' unless success
              end

              # Restore local.properties if we had one, or create default
              if local_props_content
                File.write(local_props_path, local_props_content)
              else
                # Try to detect Android SDK and create local.properties
                sdk_path = ENV['ANDROID_HOME'] || ENV['ANDROID_SDK_ROOT'] ||
                           File.expand_path('~/Library/Android/sdk')
                File.write(local_props_path, "sdk.dir=#{sdk_path}\n") if Dir.exist?(sdk_path)
              end
            ensure
              # Restore original app.json
              File.write(app_json_path, original_content)
            end
          end

          def fetch_highest_version_code(package_name)
            config = Mysigner::Config.new
            return nil unless config.exists?

            config.load
            return nil unless config.api_token && config.organization_id

            client = Mysigner::Client.new(api_url: config.api_url, api_token: config.api_token,
                                          user_email: config.user_email)

            # Find app by package name
            response = client.get("/api/v1/organizations/#{config.organization_id}/android_apps")
            apps = response[:data]['android_apps'] || []
            app = apps.find { |a| a['package_name'] == package_name }

            return app['highest_version_code'].to_i if app && app['highest_version_code']

            nil
          rescue StandardError
            # Silently fail - we'll use local version
            nil
          end

          def fetch_keystore_for_build(package_name)
            config = Mysigner::Config.new
            return nil unless config.exists?

            config.load
            return nil unless config.api_token && config.current_organization_id

            client = Mysigner::Client.new(api_url: config.api_url, api_token: config.api_token,
                                          user_email: config.user_email)
            keystore_manager = Signing::KeystoreManager.new(client, config.current_organization_id)

            # Find app by package name to get its keystore
            response = client.get("/api/v1/organizations/#{config.current_organization_id}/android_apps")
            apps = response[:data]['android_apps'] || []
            app = apps.find { |a| a['package_name'] == package_name }

            keystore = nil
            keystore = keystore_manager.active_keystore(android_app_id: app['id']) if app
            keystore ||= keystore_manager.active_keystore
            return nil unless keystore

            # Phase 0: fetch passwords via narrow audit-logged /secrets endpoint
            # instead of the deprecated ?include_secrets=true param on the list.
            secrets = keystore_manager.fetch_secrets(keystore['id'])
            downloaded = keystore_manager.get_or_download(keystore['id'])
            password = secrets['keystore_password']
            key_password = secrets['key_password'] || password
            key_alias = secrets['key_alias'] || keystore['key_alias']
            {
              path: downloaded[:path],
              name: keystore['name'],
              password: password,
              key_alias: key_alias,
              key_password: key_password,
              id: keystore['id'],
              # Ready-to-spawn env vars consumed by GradleSigningInjector in
              # build_gradle_aab / build_flutter_aab / Build::AndroidExecutor.
              signing_env_vars: {
                'MYSIGNER_STORE_FILE' => downloaded[:path],
                'MYSIGNER_STORE_PASSWORD' => password,
                'MYSIGNER_KEY_PASSWORD' => key_password,
                'MYSIGNER_KEY_ALIAS' => key_alias
              }
            }
          rescue StandardError
            # Silently fail - we'll use debug signing
            nil
          end

          def build_dotnet_aab(project_dir, _csproj_path, framework, keystore_info = nil, version_code_override = nil)
            # Check for dotnet
            unless system('which dotnet > /dev/null 2>&1')
              error '.NET SDK not found in PATH'
              say 'Install .NET: https://dotnet.microsoft.com/download', :yellow
              exit 1
            end

            require 'tmpdir'
            pw_tmpdir = nil
            store_pw_path = nil
            key_pw_path = nil

            Dir.chdir(project_dir) do
              base_args = []

              # Phase 0: For AAB output, MSBuild only supports `file:<path>`
              # for AndroidSigning*Pass (env: is explicitly unsupported for AAB).
              # Write passwords to 0600 tempfiles whose *paths* go into argv
              # instead of the passwords themselves.
              if keystore_info
                pw_tmpdir = Dir.mktmpdir('mysigner-maui-pw-')
                store_pw_path = File.join(pw_tmpdir, 'store_pw.txt')
                File.write(store_pw_path, keystore_info[:password].to_s)
                File.chmod(0o600, store_pw_path)

                # Reuse the same file if store/key passwords match (common)
                if keystore_info[:key_password] == keystore_info[:password]
                  key_pw_path = store_pw_path
                else
                  key_pw_path = File.join(pw_tmpdir, 'key_pw.txt')
                  File.write(key_pw_path, keystore_info[:key_password].to_s)
                  File.chmod(0o600, key_pw_path)
                end

                base_args += [
                  '-p:AndroidKeyStore=true',
                  "-p:AndroidSigningKeyStore=#{keystore_info[:path]}",
                  "-p:AndroidSigningKeyAlias=#{keystore_info[:key_alias]}",
                  "-p:AndroidSigningKeyPass=file:#{key_pw_path}",
                  "-p:AndroidSigningStorePass=file:#{store_pw_path}"
                ]
              end

              # Add version code override
              base_args << "-p:ApplicationVersion=#{version_code_override}" if version_code_override

              begin
                # MAUI uses dotnet publish with Android target
                success = if framework == :maui
                            system(
                              'dotnet', 'publish',
                              '-f', 'net8.0-android',
                              '-c', 'Release',
                              '-p:AndroidPackageFormat=aab',
                              *base_args
                            )
                          else
                            # Xamarin uses msbuild
                            system(
                              'dotnet', 'build',
                              '-c', 'Release',
                              '-p:AndroidPackageFormat=aab',
                              *base_args
                            )
                          end

                unless success
                  error '.NET build failed'
                  exit 1
                end
              ensure
                # Clean up password files. On Windows NTFS the child may still
                # hold the file open; fall back to at_exit deferred delete.
                [store_pw_path, key_pw_path].compact.uniq.each do |p|
                  File.delete(p) if File.exist?(p)
                rescue Errno::EACCES
                  at_exit do
                    File.delete(p)
                  rescue StandardError
                    nil
                  end
                rescue StandardError
                  # Best effort
                end
                FileUtils.rm_rf(pw_tmpdir) if pw_tmpdir && Dir.exist?(pw_tmpdir)
              end
            end

            # Find the AAB - MAUI outputs to bin/Release/net8.0-android/publish/
            aab_paths = Dir.glob(File.join(project_dir, '**/*.aab'))
            aab_paths.reject! { |p| p.include?('/obj/') } # Exclude obj folder
            aab_paths.max_by { |f| File.mtime(f) } # Return most recent
          end

          def build_gradle_aab(android_dir, framework, keystore_info = nil, version_code_override = nil)
            # Check for gradlew
            gradlew_path = File.join(android_dir, 'gradlew')
            unless File.exist?(gradlew_path)
              error "Gradle wrapper not found at #{gradlew_path}"
              case framework
              when :react_native
                say "Run 'npx expo prebuild' or ensure android/ folder is set up.", :yellow
              when :capacitor
                say "Run 'npx cap sync android' first.", :yellow
              else
                say 'Ensure the android/ folder has gradlew.', :yellow
              end
              exit 1
            end

            # Phase 0: inject signing via Gradle init-script + env vars so
            # passwords never appear in `ps aux` (ORG_GRADLE_PROJECT_<name>
            # was the old workaround but doesn't support dotted names).
            require_relative '../signing/gradle_signing_injector'

            gradle_args = ['./gradlew', 'bundleRelease', '--warning-mode=all']
            gradle_args << "-PversionCode=#{version_code_override}" if version_code_override

            injector = nil
            env = {}
            if keystore_info
              injector = Mysigner::Signing::GradleSigningInjector.new
              init_path = injector.write_init_script!
              env = keystore_info[:signing_env_vars] || injector.env_vars(
                keystore_path: keystore_info[:path],
                store_password: keystore_info[:password],
                key_password: keystore_info[:key_password],
                key_alias: keystore_info[:key_alias]
              )
              gradle_args.insert(1, '--init-script', init_path)
            end

            begin
              Dir.chdir(android_dir) do
                success = system(env, *gradle_args)
                unless success
                  error 'Gradle build failed'
                  exit 1
                end
              end
            ensure
              injector&.cleanup!
            end

            # Find the AAB
            aab_path = File.join(android_dir, 'app/build/outputs/bundle/release/app-release.aab')
            unless File.exist?(aab_path)
              # Try alternate paths
              alt_paths = Dir.glob(File.join(android_dir, 'app/build/outputs/bundle/*/*.aab'))
              aab_path = alt_paths.first if alt_paths.any?
            end
            aab_path
          end

          def parse_expo_config(directory)
            # Try app.json first
            app_json_path = File.join(directory, 'app.json')
            if File.exist?(app_json_path)
              begin
                config = JSON.parse(File.read(app_json_path))
                expo = config['expo'] || config
                return {
                  package_name: expo.dig('android', 'package'),
                  bundle_id: expo.dig('ios', 'bundleIdentifier'),
                  name: expo['name'],
                  version: expo['version'],
                  version_code: expo.dig('android', 'versionCode')
                }
              rescue JSON::ParserError
                # Invalid JSON, ignore
              end
            end

            # Try app.config.js (basic extraction)
            app_config_path = File.join(directory, 'app.config.js')
            if File.exist?(app_config_path)
              content = File.read(app_config_path)
              # Basic regex extraction for package name
              if content =~ /android\s*:\s*\{[^}]*package\s*:\s*["']([^"']+)["']/m
                package_name = ::Regexp.last_match(1)
                name = nil
                name = ::Regexp.last_match(1) if content =~ /name\s*:\s*["']([^"']+)["']/
                return {
                  package_name: package_name,
                  bundle_id: nil,
                  name: name
                }
              end
            end

            nil
          end

          public

          # ==================== BUNDLE IDS ====================

          desc 'bundleid SUBCOMMAND', 'Register and manage iOS Bundle IDs'
          long_desc <<~DESC
            Register and manage iOS Bundle IDs in App Store Connect.

            WHAT ARE BUNDLE IDs?

            Bundle IDs are unique identifiers for your iOS apps (e.g., com.company.app).
            Every iOS app and app extension needs its own Bundle ID registered in
            App Store Connect before you can sign and distribute it.

            SUBCOMMANDS:

              mysigner bundleid register IDENTIFIER [NAME]
                Register a new Bundle ID in App Store Connect.
                The NAME is optional - defaults to the last part of the identifier.

              mysigner bundleid list
                List all registered Bundle IDs in your organization.

            EXAMPLES:

              # Register main app bundle ID
              mysigner bundleid register com.company.myapp

              # Register with a custom name
              mysigner bundleid register com.company.myapp "My App"

              # Register a widget extension bundle ID
              mysigner bundleid register com.company.myapp.widget "My App Widget"

              # List all bundle IDs
              mysigner bundleid list

            NOTES:

              • Bundle IDs must be unique across all of App Store Connect
              • Use reverse domain notation (e.g., com.company.app)
              • Extensions should use parent app's bundle ID as prefix (e.g., com.company.app.widget)
              • After registering, run 'mysigner sync ios' to update local cache
          DESC
          def bundleid(action, *args)
            config = load_config
            client = create_client(config)

            case action
            when 'register'
              if args.empty? || args[0].nil? || args[0].to_s.empty?
                error 'Usage: mysigner bundleid register IDENTIFIER [NAME]'
                say ''
                say 'Example: mysigner bundleid register com.company.myapp', :yellow
                say 'Example: mysigner bundleid register com.company.myapp.widget "My Widget"', :yellow
                exit 1
                return
              end

              identifier = args[0]

              # Validate bundle ID format BEFORE dereferencing (guards against
              # `.split` on a degenerate identifier like "123.com.app").
              unless identifier =~ /^[a-zA-Z][a-zA-Z0-9.-]*\.[a-zA-Z][a-zA-Z0-9.-]*$/
                error "Invalid Bundle ID format: #{identifier}"
                say ''
                say 'Bundle IDs must:', :yellow
                say '  • Start with a letter', :cyan
                say '  • Use reverse domain notation (e.g., com.company.app)', :cyan
                say '  • Contain only letters, numbers, hyphens, and periods', :cyan
                exit 1
                return
              end

              # Default name is the last component of the identifier
              name = args[1] || identifier.split('.').last.capitalize

              say '🔗 Registering Bundle ID...', :cyan
              say ''
              say "  Identifier: #{identifier}", :white
              say "  Name: #{name}", :white
              say ''

              begin
                response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/bundle_ids",
                  body: {
                    identifier: identifier,
                    name: name,
                    platform: 'IOS'
                  }
                )

                bundle_id_data = response[:data]['bundle_id'] || response[:data]
                say '✓ Bundle ID registered successfully!', :green
                say ''
                say 'Details:', :bold
                say "  Identifier: #{bundle_id_data['identifier'] || identifier}"
                say "  Name: #{bundle_id_data['name'] || name}"
                say ''
                say 'Next steps:', :cyan
                say '  1. Sync to update local cache: mysigner sync ios', :white
                say '  2. Create a provisioning profile: mysigner doctor (will auto-create)', :white
                say '  3. Or run: mysigner signing configure', :white
              rescue Mysigner::ValidationError => e
                error 'Validation failed:'
                if e.details
                  e.details.each do |field, errors|
                    say "  #{field}: #{errors.join(', ')}", :red
                  end
                else
                  say "  #{e.message}", :red
                end
                say "  Suggestion: #{e.suggestion}", :yellow if e.suggestion
                exit 1
              rescue Mysigner::ClientError => e
                if e.message.include?('already exists') || e.message.include?('ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE')
                  say "ℹ️  Bundle ID already registered: #{identifier}", :yellow
                  say ''
                  say 'This Bundle ID already exists in App Store Connect.', :white
                  say "Run 'mysigner sync ios' to update your local cache.", :cyan
                else
                  error "Failed to register Bundle ID: #{e.message}"
                  say ''
                  say 'Common issues:', :yellow
                  say '  • Bundle ID already exists (check App Store Connect)', :cyan
                  say '  • Invalid format (must be like com.company.app)', :cyan
                  say '  • API credentials may not have permission', :cyan
                end
                exit 1
              end

            when 'list'
              say '📦 Registered Bundle IDs', :cyan
              say ''

              begin
                response = client.get(
                  "/api/v1/organizations/#{config.current_organization_id}/bundle_ids"
                )
                bundle_ids = response[:data]['bundle_ids'] || response[:data] || []

                if bundle_ids.empty?
                  say '  No Bundle IDs found', :yellow
                  say ''
                  say '  Register one with: mysigner bundleid register com.company.app', :cyan
                else
                  bundle_ids.each do |bid|
                    identifier = bid['identifier'] || bid['bundle_id']
                    name = bid['name'] || 'N/A'
                    say "  • #{name}", :green
                    say "    Identifier: #{identifier}"
                    say ''
                  end
                end
              rescue Mysigner::ClientError => e
                error "Failed to list Bundle IDs: #{e.message}"
                exit 1
              end

            when 'delete'
              if args.empty? || args[0].nil? || args[0].to_s.empty?
                error 'Usage: mysigner bundleid delete IDENTIFIER'
                say ''
                say 'Example: mysigner bundleid delete com.company.myapp', :yellow
                exit 1
                return
              end

              identifier = args[0]

              say '🗑  Removing Bundle ID...', :cyan
              say "  Identifier: #{identifier}", :white
              say ''

              begin
                # Resolve the identifier → numeric id (the backend DELETE is keyed on id).
                list_response = client.get(
                  "/api/v1/organizations/#{config.current_organization_id}/bundle_ids"
                )
                bundle_ids = list_response[:data]['bundle_ids'] || list_response[:data] || []
                bid = bundle_ids.find { |b| (b['identifier'] || b['bundle_id']) == identifier }

                if bid.nil?
                  error "Bundle ID not found: #{identifier}"
                  say ''
                  say '  → List existing: mysigner bundleid list', :yellow
                  exit 1
                  return
                end

                client.delete(
                  "/api/v1/organizations/#{config.current_organization_id}/bundle_ids/#{bid['id']}"
                )

                say '✓ Bundle ID deleted from App Store Connect and local cache', :green
                say ''
                say 'Run `mysigner sync ios` to refresh your local cache if needed.', :cyan
              rescue Mysigner::ValidationError => e
                # Backend maps 409 Conflict → ValidationError. Apple refused
                # because of dependent resources (apps/profiles/capabilities).
                error e.message
                say ''
                say '💡 To delete this Bundle ID:', :cyan
                say '   1. Remove any provisioning profiles that use it', :yellow
                say '   2. Remove any apps tied to it in App Store Connect', :yellow
                say '   3. Disable capabilities attached to it', :yellow
                say '   4. Re-run `mysigner bundleid delete`', :yellow
                exit 1
              rescue Mysigner::ClientError => e
                error "Failed to delete Bundle ID: #{e.message}"
                exit 1
              end

            else
              error "Unknown action: #{action}"
              say ''
              say 'Available actions:', :yellow
              say '  mysigner bundleid register IDENTIFIER [NAME]', :cyan
              say '  mysigner bundleid list', :cyan
              say '  mysigner bundleid delete IDENTIFIER', :cyan
              exit 1
            end
          end

          # ==================== APPS (iOS + Android) ====================

          desc 'apps', 'List apps from App Store Connect and/or Google Play'
          long_desc <<~DESC
            List apps synced from app stores.

            PLATFORMS:
              --platform ios       List iOS apps only
              --platform android   List Android apps only
              (default)            List apps from both platforms

            EXAMPLES:
              mysigner apps                      # List all apps
              mysigner apps --platform ios       # iOS apps only
              mysigner apps --platform android   # Android apps only
              mysigner apps -q "myapp"           # Search by name
          DESC
          method_option :platform, type: :string, desc: 'Filter by platform: ios, android'
          method_option :search, type: :string, aliases: '-q', desc: 'Search by name or identifier'
          method_option :page, type: :numeric, default: 1, desc: 'Page number'
          method_option :per_page, type: :numeric, default: 50, desc: 'Apps per page'
          def apps
            config = load_config
            client = create_client(config)

            platform = options[:platform]&.downcase
            show_ios = platform.nil? || platform == 'ios'
            show_android = platform.nil? || platform == 'android'

            params = {
              page: options[:page],
              per_page: options[:per_page]
            }
            params[:q] = options[:search] if options[:search]

            # iOS Apps
            if show_ios
              say '📱 iOS Apps', :cyan
              say ''

              begin
                response = client.get(
                  "/api/v1/organizations/#{config.current_organization_id}/apple_apps",
                  params: params
                )
                ios_apps = response[:data]['data']&.fetch('apps', nil) || []

                if ios_apps.empty?
                  say '  No iOS apps found', :yellow
                  say ''
                  say "  Why don't my iOS apps appear?", :cyan
                  say '  ─────────────────────────────', :cyan
                  say ''
                  say '  Common reasons:', :yellow
                  say '    • No apps registered in App Store Connect yet'
                  say '    • Team ID not set on your credential'
                  say '    • Bundle IDs exist but apps not created in App Store Connect'
                  say ''
                  say '  How to register an iOS app:', :cyan
                  say ''
                  say '    1. Register a Bundle ID'
                  say '       https://developer.apple.com/account/resources/identifiers/list'
                  say "       Click '+' → App IDs → Enter your Bundle ID (e.g., com.company.appname)"
                  say ''
                  say '    2. Create the app in App Store Connect'
                  say '       https://appstoreconnect.apple.com/apps'
                  say "       My Apps → '+' → New App → Select your Bundle ID"
                  say ''
                  say '    3. Sync your organization'
                  say '       Run: ', :white
                  say 'mysigner sync ios', :green
                  say ''
                  say '  💡 Team ID tip:', :yellow
                  say "     Apple's API doesn't expose Team ID. Set it manually in the web dashboard."
                  say '     Find yours at: https://developer.apple.com/account/#!/membership/'
                  say ''
                else
                  ios_apps.each do |app|
                    say "  • #{app['name'] || app['bundle_id']}", :green
                    say "    Bundle ID: #{app['bundle_id']}"
                    say ''
                  end
                end
              rescue Mysigner::ClientError => e
                say "  Could not fetch iOS apps: #{e.message}", :yellow
              end
              say ''
            end

            # Android Apps
            return unless show_android

            say '🤖 Android Apps', :cyan
            say ''

            begin
              response = client.get(
                "/api/v1/organizations/#{config.current_organization_id}/android_apps",
                params: params
              )
              android_apps = response[:data]['android_apps'] || []

              if android_apps.empty?
                say '  No Android apps found', :yellow
                say '  Sync with: mysigner sync android', :yellow
              else
                android_apps.each do |app|
                  say "  • #{app['name'] || app['package_name']}", :green
                  say "    Package: #{app['package_name']}"
                  say ''
                end
              end
            rescue Mysigner::ClientError => e
              say "  Could not fetch Android apps: #{e.message}", :yellow
            end
          end

          # ==================== MERCHANT IDS (Apple Pay) ====================

          desc 'merchant-ids', 'List Apple Pay Merchant IDs'
          method_option :search, type: :string, aliases: '-q', desc: 'Search by identifier or name'
          method_option :page, type: :numeric, default: 1, desc: 'Page number'
          method_option :per_page, type: :numeric, default: 50, desc: 'Items per page'
          def merchant_ids
            config = load_config
            client = create_client(config)

            say '💳 Merchant IDs', :cyan
            say ''

            params = {
              page: options[:page],
              per_page: options[:per_page]
            }
            params[:q] = options[:search] if options[:search]

            begin
              response = client.get(
                "/api/v1/organizations/#{config.current_organization_id}/merchant_ids",
                params: params
              )
              merchant_ids = response[:data]['merchant_ids'] || []
              pagination = response[:data]['pagination']

              if merchant_ids.empty?
                say '  No Merchant IDs found', :yellow
                say ''
                say '  Create one with: mysigner merchant-id create IDENTIFIER', :cyan
              else
                merchant_ids.each do |m|
                  say "  • #{m['identifier']}", :green
                  say "    Name: #{m['name']}" if m['name'] && m['name'] != m['identifier']
                  say "    Team: #{m['team_id']}" if m['team_id']
                  say ''
                end

                if pagination
                  say "Page #{pagination['page']} of #{pagination['total_pages']} (#{pagination['total']} total)",
                      :yellow
                end
              end
            rescue Mysigner::ClientError => e
              error "Failed to fetch Merchant IDs: #{e.message}"
              exit 1
            end
          end

          desc 'merchant-id SUBCOMMAND', 'Manage Apple Pay Merchant IDs'
          long_desc <<~DESC
            Create and delete Apple Pay Merchant IDs.

            SUBCOMMANDS:

              mysigner merchant-id create IDENTIFIER [--name NAME]
              Create a new Merchant ID in App Store Connect

              mysigner merchant-id delete IDENTIFIER
              Delete a Merchant ID from App Store Connect

            EXAMPLES:

              mysigner merchant-id create merchant.com.company.app
              mysigner merchant-id create merchant.com.company.app --name "My Payment"
              mysigner merchant-id delete merchant.com.company.app
          DESC
          method_option :name, type: :string, aliases: '-n', desc: 'Friendly name for the Merchant ID'
          def merchant_id(action, identifier = nil)
            config = load_config
            client = create_client(config)

            case action
            when 'create'
              if identifier.nil? || identifier.to_s.empty?
                error 'Usage: mysigner merchant-id create IDENTIFIER [--name NAME]'
                say ''
                say 'Example: mysigner merchant-id create merchant.com.company.app', :yellow
                exit 1
                return
              end

              unless identifier.start_with?('merchant.')
                error "Merchant ID must start with 'merchant.'"
                say ''
                say 'Example: merchant.com.company.app', :cyan
                exit 1
                return
              end

              say '💳 Creating Merchant ID...', :cyan
              say ''

              begin
                response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/merchant_ids",
                  body: {
                    identifier: identifier,
                    name: options[:name] || identifier
                  }
                )

                m = response[:data]['merchant_id'] || response[:data]
                say '✓ Merchant ID created successfully!', :green
                say ''
                say "  Identifier: #{m['identifier'] || identifier}", :white
                say "  Name: #{m['name']}", :white if m['name']
              rescue Mysigner::ClientError => e
                if e.message.include?('already exists')
                  say "ℹ️  Merchant ID already exists: #{identifier}", :yellow
                else
                  error "Failed to create Merchant ID: #{e.message}"
                end
                exit 1
              end

            when 'delete'
              if identifier.nil? || identifier.to_s.empty?
                error 'Usage: mysigner merchant-id delete IDENTIFIER'
                exit 1
                return
              end

              say '💳 Deleting Merchant ID...', :cyan
              say ''

              begin
                # First find the merchant ID by identifier
                response = client.get(
                  "/api/v1/organizations/#{config.current_organization_id}/merchant_ids",
                  params: { q: identifier }
                )
                merchant_ids = response[:data]['merchant_ids'] || []
                m = merchant_ids.find { |x| x['identifier'] == identifier }

                if m.nil?
                  error "Merchant ID not found: #{identifier}"
                  exit 1
                  return
                end

                client.delete(
                  "/api/v1/organizations/#{config.current_organization_id}/merchant_ids/#{m['id']}"
                )

                say "✓ Merchant ID deleted: #{identifier}", :green
              rescue Mysigner::ClientError => e
                error "Failed to delete Merchant ID: #{e.message}"
                exit 1
              end

            else
              error "Unknown action: #{action}"
              say ''
              say 'Available actions:', :yellow
              say '  mysigner merchant-id create IDENTIFIER [--name NAME]', :cyan
              say '  mysigner merchant-id delete IDENTIFIER', :cyan
              exit 1
            end
          end

          # ==================== ANDROID TRACKS ====================

          desc 'tracks PACKAGE_NAME', 'List Google Play tracks for an Android app'
          method_option :sort, type: :boolean, desc: 'Sort by track name'
          def tracks(package_name = nil)
            config = load_config
            client = create_client(config)

            if package_name.nil?
              error 'Usage: mysigner tracks PACKAGE_NAME'
              say ''
              say 'Example: mysigner tracks com.example.myapp', :yellow
              say ''
              say '💡 To see your registered Android apps:', :cyan
              say '   mysigner apps --platform android', :cyan
              exit 1
            end

            say "🎯 Google Play Tracks for #{package_name}", :cyan
            say ''

            begin
              response = client.get("/api/v1/organizations/#{config.current_organization_id}/android_apps/package/#{package_name}/tracks")
              tracks = response[:data]['tracks'] || []

              if tracks.empty?
                say 'No tracks found', :yellow
                say ''
                say 'Tracks appear after you upload your app to Google Play Console', :cyan
                say "and sync with: mysigner sync android --package #{package_name}", :cyan
                return
              end

              # Sort by track name if requested
              tracks = tracks.sort_by { |t| t['track_name'] } if options[:sort]

              tracks.each do |track|
                status_color = track['status'] == 'completed' ? :green : :yellow
                say "  📍 #{track['track_name']}", :white
                say "    Status: #{track['status'] || 'unknown'}", status_color

                # Show releases info if available
                if track['releases'].is_a?(Array) && track['releases'].any?
                  releases = track['releases']
                  latest = releases.first
                  version_codes = latest['versionCodes'] || latest['version_codes'] || []
                  say "    Version codes: #{version_codes.join(', ')}" if version_codes.any?
                  say "    Release status: #{latest['status']}" if latest['status']
                end

                if track['updated_at']
                  updated = Time.parse(track['updated_at']).strftime('%Y-%m-%d %H:%M')
                  say "    Updated: #{updated}"
                end
                say ''
              end

              say "Total: #{tracks.count} track(s)", :yellow
            rescue Mysigner::NotFoundError => e
              if e.message.include?('Android app')
                error "Android app not found: #{package_name}"
                say ''
                say '💡 App not found:', :cyan
                say '   → Check the package name is correct', :yellow
                say '   → List your apps: mysigner apps --platform android', :yellow
                say "   → Register the app: mysigner android add #{package_name}", :yellow
              else
                error "Not found: #{e.message}"
              end
              exit 1
            rescue Mysigner::ClientError => e
              error "Failed to fetch tracks: #{e.message}"
              exit 1
            end
          end

          desc 'track PACKAGE_NAME TRACK_NAME', 'Show details for a specific Google Play track'
          def track(package_name = nil, track_name = nil)
            config = load_config
            client = create_client(config)

            if package_name.nil? || track_name.nil?
              error 'Usage: mysigner track PACKAGE_NAME TRACK_NAME'
              say ''
              say 'Example: mysigner track com.example.myapp production', :yellow
              say '         mysigner track com.example.myapp beta', :yellow
              say ''
              say 'Common track names: production, beta, alpha, internal', :cyan
              say ''
              say '💡 To see available tracks:', :cyan
              say '   mysigner tracks com.example.myapp', :cyan
              exit 1
            end

            say "🎯 Track: #{track_name}", :cyan
            say "   Package: #{package_name}", :white
            say ''

            begin
              response = client.get("/api/v1/organizations/#{config.current_organization_id}/android_apps/package/#{package_name}/tracks/#{track_name}")
              track = response[:data]

              say 'Details:', :bold
              say "  Track Name: #{track['track_name']}"
              say "  Status: #{track['status'] || 'unknown'}"

              if track['updated_at']
                updated = Time.parse(track['updated_at']).strftime('%Y-%m-%d %H:%M')
                say "  Last Updated: #{updated}"
              end

              # Show releases info
              say ''
              if track['releases'].is_a?(Array) && track['releases'].any?
                say 'Releases:', :bold
                track['releases'].each_with_index do |release, idx|
                  say "  Release #{idx + 1}:", :white
                  say "    Status: #{release['status']}" if release['status']

                  version_codes = release['versionCodes'] || release['version_codes'] || []
                  say "    Version Codes: #{version_codes.join(', ')}" if version_codes.any?

                  say "    Name: #{release['name']}" if release['name']

                  if release['releaseNotes'] || release['release_notes']
                    notes = release['releaseNotes'] || release['release_notes']
                    if notes.is_a?(Array) && notes.any?
                      say '    Release Notes:'
                      notes.each do |note|
                        lang = note['language'] || 'en-US'
                        text = note['text'] || ''
                        say "      [#{lang}] #{text.slice(0, 80)}#{'...' if text.length > 80}"
                      end
                    end
                  end

                  if release['userFraction'] || release['user_fraction']
                    fraction = release['userFraction'] || release['user_fraction']
                    say "    Rollout: #{(fraction * 100).round(1)}%"
                  end
                end
              else
                say 'No releases found in this track', :yellow
              end
            rescue Mysigner::NotFoundError => e
              if e.message.include?('Android app')
                error "Android app not found: #{package_name}"
                say ''
                say '💡 App not found:', :cyan
                say '   → Check the package name is correct', :yellow
                say '   → List your apps: mysigner apps --platform android', :yellow
              elsif e.message.include?('Track')
                error "Track not found: #{track_name}"
                say ''
                say '💡 Track not found:', :cyan
                say '   → Check the track name is correct', :yellow
                say "   → List available tracks: mysigner tracks #{package_name}", :yellow
                say '   → Common tracks: production, beta, alpha, internal', :yellow
              else
                error "Not found: #{e.message}"
              end
              exit 1
            rescue Mysigner::ClientError => e
              error "Failed to fetch track: #{e.message}"
              exit 1
            end
          end

          # ==================== APP GROUPS ====================

          desc 'app-groups', 'List App Groups'
          method_option :search, type: :string, aliases: '-q', desc: 'Search by identifier or name'
          method_option :page, type: :numeric, default: 1, desc: 'Page number'
          method_option :per_page, type: :numeric, default: 50, desc: 'Items per page'
          def app_groups
            config = load_config
            client = create_client(config)

            say '📦 App Groups', :cyan
            say ''

            params = {
              page: options[:page],
              per_page: options[:per_page]
            }
            params[:q] = options[:search] if options[:search]

            begin
              response = client.get(
                "/api/v1/organizations/#{config.current_organization_id}/app_groups",
                params: params
              )
              app_groups = response[:data]['app_groups'] || []
              pagination = response[:data]['pagination']

              if app_groups.empty?
                say '  No App Groups found', :yellow
                say ''
                say '  Register one with: mysigner app-group register IDENTIFIER', :cyan
                say ''
                say '  Note: App Groups must first be created in Apple Developer Portal', :yellow
              else
                app_groups.each do |g|
                  say "  • #{g['identifier']}", :green
                  say "    Name: #{g['name']}" if g['name'] && g['name'] != g['identifier']
                  say "    Team: #{g['team_id']}" if g['team_id']
                  say ''
                end

                if pagination
                  say "Page #{pagination['page']} of #{pagination['total_pages']} (#{pagination['total']} total)",
                      :yellow
                end
              end
            rescue Mysigner::ClientError => e
              error "Failed to fetch App Groups: #{e.message}"
              exit 1
            end
          end

          desc 'app-group SUBCOMMAND', 'Manage App Groups'
          long_desc <<~DESC
            Register and delete App Groups.

            IMPORTANT: Apple does NOT provide a public API to create App Groups.
            You must first create them in the Apple Developer Portal, then register
            them here to track and associate with Bundle IDs.

            SUBCOMMANDS:

              mysigner app-group register IDENTIFIER [--name NAME]
              Register an existing App Group from Apple Developer Portal

              mysigner app-group delete IDENTIFIER
              Remove an App Group from My Signer (does not delete from Apple)

            EXAMPLES:

              mysigner app-group register group.com.company.shared
              mysigner app-group register group.com.company.shared --name "Shared Data"
              mysigner app-group delete group.com.company.shared
          DESC
          method_option :name, type: :string, aliases: '-n', desc: 'Friendly name for the App Group'
          def app_group(action, identifier = nil)
            config = load_config
            client = create_client(config)

            case action
            when 'register'
              if identifier.nil? || identifier.to_s.empty?
                error 'Usage: mysigner app-group register IDENTIFIER [--name NAME]'
                say ''
                say 'Example: mysigner app-group register group.com.company.shared', :yellow
                say ''
                say 'Note: Create the App Group in Apple Developer Portal first!', :cyan
                exit 1
                return
              end

              unless identifier.start_with?('group.')
                error "App Group identifier must start with 'group.'"
                say ''
                say 'Example: group.com.company.shared', :cyan
                exit 1
                return
              end

              say '📦 Registering App Group...', :cyan
              say ''

              begin
                response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/app_groups",
                  body: {
                    identifier: identifier,
                    name: options[:name] || identifier
                  }
                )

                g = response[:data]['app_group'] || response[:data]
                say '✓ App Group registered!', :green
                say ''
                say "  Identifier: #{g['identifier'] || identifier}", :white
                say "  Name: #{g['name']}", :white if g['name']
                say ''
                say '  Remember: This only registers the App Group in My Signer.', :yellow
                say '  Make sure it exists in Apple Developer Portal.', :yellow
              rescue Mysigner::ClientError => e
                if e.message.include?('already exists')
                  say "ℹ️  App Group already registered: #{identifier}", :yellow
                else
                  error "Failed to register App Group: #{e.message}"
                end
                exit 1
              end

            when 'delete'
              if identifier.nil? || identifier.to_s.empty?
                error 'Usage: mysigner app-group delete IDENTIFIER'
                exit 1
                return
              end

              say '📦 Removing App Group...', :cyan
              say ''

              begin
                # First find the app group by identifier
                response = client.get(
                  "/api/v1/organizations/#{config.current_organization_id}/app_groups",
                  params: { q: identifier }
                )
                app_groups = response[:data]['app_groups'] || []
                g = app_groups.find { |x| x['identifier'] == identifier }

                if g.nil?
                  error "App Group not found: #{identifier}"
                  exit 1
                  return
                end

                client.delete(
                  "/api/v1/organizations/#{config.current_organization_id}/app_groups/#{g['id']}"
                )

                say "✓ App Group removed from My Signer: #{identifier}", :green
                say ''
                say '  Note: The App Group still exists in Apple Developer Portal.', :yellow
                say '  Delete it manually if needed.', :yellow
              rescue Mysigner::ClientError => e
                error "Failed to remove App Group: #{e.message}"
                exit 1
              end

            else
              error "Unknown action: #{action}"
              say ''
              say 'Available actions:', :yellow
              say '  mysigner app-group register IDENTIFIER [--name NAME]', :cyan
              say '  mysigner app-group delete IDENTIFIER', :cyan
              exit 1
            end
          end

          # ==================== GOOGLE PLAY CREDENTIALS ====================

          desc 'gp-credential SUBCOMMAND', 'Manage Google Play credentials (list, delete, activate, test)'
          long_desc <<~DESC
            Manage Google Play API credentials for Android app distribution.

            SUBCOMMANDS:

              mysigner gp-credential list
              List all Google Play credentials

              mysigner gp-credential delete ID
              Delete a credential

              mysigner gp-credential activate ID
              Set a credential as the active one

              mysigner gp-credential test ID
              Test connection to Google Play API

            EXAMPLES:

              # List all credentials
              mysigner gp-credential list

              # Activate credential ID 2
              mysigner gp-credential activate 2

              # Test if credential can connect to Google Play
              mysigner gp-credential test 1

              # Delete old credential
              mysigner gp-credential delete 3
          DESC
          def gp_credential(action, *args)
            config = load_config
            client = create_client(config)

            case action
            when 'list'
              say '🔑 Google Play Credentials', :cyan
              say ''

              begin
                response = client.get("/api/v1/organizations/#{config.current_organization_id}/google_play_credentials")
                credentials = response[:data]['google_play_credentials'] || []

                if credentials.empty?
                  say 'No Google Play credentials found', :yellow
                  say ''
                  say 'Set up credentials with: mysigner onboard', :yellow
                  return
                end

                credentials.each do |cred|
                  active_icon = cred['active'] ? '✓' : '○'
                  active_color = cred['active'] ? :green : :white

                  say "  #{active_icon} #{cred['name']} (ID: #{cred['id']})", active_color
                  say "    Developer Account: #{cred['developer_account_id'] || 'N/A'}"
                  say "    Active: #{cred['active'] ? 'Yes' : 'No'}"
                  if cred['last_synced_at']
                    synced = Time.parse(cred['last_synced_at']).strftime('%Y-%m-%d %H:%M')
                    say "    Last Synced: #{synced}"
                  end
                  if cred['last_sync_status']
                    sync_color = cred['last_sync_status'] == 'success' ? :green : :red
                    say "    Sync Status: #{cred['last_sync_status']}", sync_color
                  end
                  say ''
                end

                say "Total: #{credentials.count} credential(s)", :yellow
              rescue Mysigner::ClientError => e
                error "Failed to fetch credentials: #{e.message}"
                exit 1
              end

            when 'delete'
              credential_id = args[0]

              unless credential_id
                error 'Usage: mysigner gp-credential delete ID'
                say ''
                say "Run 'mysigner gp-credential list' to see available IDs", :yellow
                exit 1
              end

              say "⚠️  You are about to delete Google Play credential ID: #{credential_id}", :yellow
              say ''

              if yes?('Are you sure? This cannot be undone. (y/n)')
                begin
                  client.delete("/api/v1/organizations/#{config.current_organization_id}/google_play_credentials/#{credential_id}")
                  say ''
                  say '✓ Google Play credential deleted', :green
                rescue Mysigner::NotFoundError
                  error "Credential not found with ID: #{credential_id}"
                  say ''
                  say "Run 'mysigner gp-credential list' to see available IDs", :yellow
                  exit 1
                rescue Mysigner::ClientError => e
                  error "Delete failed: #{e.message}"
                  exit 1
                end
              else
                say 'Deletion cancelled', :yellow
              end

            when 'activate'
              credential_id = args[0]

              unless credential_id
                error 'Usage: mysigner gp-credential activate ID'
                say ''
                say "Run 'mysigner gp-credential list' to see available IDs", :yellow
                exit 1
              end

              say '🔑 Activating credential...', :cyan

              begin
                response = client.post("/api/v1/organizations/#{config.current_organization_id}/google_play_credentials/#{credential_id}/activate")
                credential = response[:data]['google_play_credential'] || response[:data]
                say '✓ Credential activated!', :green
                say ''
                say "#{credential['name']} is now the active Google Play credential", :cyan
              rescue Mysigner::NotFoundError
                error "Credential not found with ID: #{credential_id}"
                say ''
                say "Run 'mysigner gp-credential list' to see available IDs", :yellow
                exit 1
              rescue Mysigner::ClientError => e
                error "Activation failed: #{e.message}"
                exit 1
              end

            when 'test'
              credential_id = args[0]

              unless credential_id
                error 'Usage: mysigner gp-credential test ID'
                say ''
                say "Run 'mysigner gp-credential list' to see available IDs", :yellow
                exit 1
              end

              say '🔑 Testing credential connection...', :cyan
              say ''

              begin
                response = client.post("/api/v1/organizations/#{config.current_organization_id}/google_play_credentials/#{credential_id}/test")
                result = response[:data]

                if result['success']
                  say '✓ Connection successful!', :green
                  say ''
                  say '  Google Play API is reachable with this credential', :cyan
                else
                  say '✗ Connection failed', :red
                  say ''
                  say "  Error: #{result['error']}", :red if result['error']
                  say ''
                  say '💡 Check that:', :cyan
                  say '   → The service account JSON key is valid', :yellow
                  say '   → The service account has Google Play Console access', :yellow
                  say '   → API access is enabled in Google Play Console', :yellow
                  exit 1
                end
              rescue Mysigner::NotFoundError
                error "Credential not found with ID: #{credential_id}"
                say ''
                say "Run 'mysigner gp-credential list' to see available IDs", :yellow
                exit 1
              rescue Mysigner::ClientError => e
                error "Test failed: #{e.message}"
                exit 1
              end

            when 'help'
              invoke :help, ['gp-credential']
            else
              error "Unknown action: #{action}"
              say 'Available actions: list, delete, activate, test, help', :yellow
              exit 1
            end
          end

          # ==================== APP STORE RELEASES ====================

          desc 'release SUBCOMMAND', 'Manage App Store release configurations (list, show, create, update)'
          long_desc <<~DESC
            Manage App Store release configurations for iOS app distribution.

            Release configurations control how your app is submitted and released on the
            App Store, including auto-submit, phased release, and release notes.

            SUBCOMMANDS:

              mysigner release list [--bundle-id BUNDLE_ID]
              List all release configurations

              mysigner release show ID
              Show details for a release configuration

              mysigner release create --bundle-id-id ID [OPTIONS]
              Create a new release configuration

              mysigner release update ID [OPTIONS]
              Update an existing release configuration

            OPTIONS FOR CREATE/UPDATE:

              --bundle-id-id ID          Bundle ID record ID (required for create)
              --whats-new TEXT           Release notes / What's New text
              --support-url URL          Support URL
              --marketing-url URL        Marketing URL
              --privacy-url URL          Privacy policy URL
              --auto-submit              Auto-submit for review after upload
              --phased-release           Enable phased release (7-day rollout)
              --release-type TYPE        Release type: manual, after_approval, scheduled
              --scheduled-date DATE      Scheduled release date (ISO 8601)

            EXAMPLES:

              # List all release configs
              mysigner release list

              # List releases for a specific bundle ID
              mysigner release list --bundle-id com.example.app

              # Show details
              mysigner release show 1

              # Create a release config
              mysigner release create --bundle-id-id 42 --auto-submit --phased-release

              # Update release notes
              mysigner release update 1 --whats-new "Bug fixes and improvements"

              # Set up scheduled release
              mysigner release update 1 --release-type scheduled --scheduled-date 2025-03-01T10:00:00Z
          DESC
          method_option :bundle_id, type: :string, aliases: '-b', desc: 'Filter by bundle identifier'
          method_option :bundle_id_id, type: :numeric, desc: 'Bundle ID record ID (for create)'
          method_option :whats_new, type: :string, desc: "What's New text"
          method_option :support_url, type: :string, desc: 'Support URL'
          method_option :marketing_url, type: :string, desc: 'Marketing URL'
          method_option :privacy_url, type: :string, desc: 'Privacy policy URL'
          method_option :auto_submit, type: :boolean, desc: 'Auto-submit for review'
          method_option :phased_release, type: :boolean, desc: 'Enable phased release'
          method_option :release_type, type: :string, desc: 'Release type: manual, after_approval, scheduled'
          method_option :scheduled_date, type: :string, desc: 'Scheduled release date (ISO 8601)'
          def release(action, *args)
            config = load_config
            client = create_client(config)

            case action
            when 'list'
              say '🚀 App Store Releases', :cyan
              say ''

              params = {}
              params[:bundle_id] = options[:bundle_id] if options[:bundle_id]

              begin
                response = client.get(
                  "/api/v1/organizations/#{config.current_organization_id}/app_store_releases",
                  params: params
                )
                releases = response[:data]['app_store_releases'] || []

                if releases.empty?
                  say 'No release configurations found', :yellow
                  say ''
                  say 'Create one with: mysigner release create --bundle-id-id ID', :yellow
                  return
                end

                releases.each do |rel|
                  say "  • #{rel['app_name'] || rel['bundle_identifier']} (ID: #{rel['id']})", :green
                  say "    Bundle ID: #{rel['bundle_identifier']}" if rel['bundle_identifier']
                  say "    Release Type: #{rel['release_type'] || 'N/A'}"
                  say "    Auto Submit: #{rel['auto_submit'] ? 'Yes' : 'No'}"
                  say "    Phased Release: #{rel['phased_release'] ? 'Yes' : 'No'}"
                  say "    Version: #{rel['version_string']}" if rel['version_string']
                  say ''
                end

                say "Total: #{releases.count} release(s)", :yellow
              rescue Mysigner::ClientError => e
                error "Failed to fetch releases: #{e.message}"
                exit 1
              end

            when 'show'
              release_id = args[0]

              unless release_id
                error 'Usage: mysigner release show ID'
                say ''
                say "Run 'mysigner release list' to see available IDs", :yellow
                exit 1
              end

              begin
                response = client.get("/api/v1/organizations/#{config.current_organization_id}/app_store_releases/#{release_id}")
                rel = response[:data]['app_store_release'] || response[:data]

                say "🚀 Release Configuration (ID: #{rel['id']})", :cyan
                say ''
                say 'Details:', :bold
                say "  App Name:        #{rel['app_name'] || 'N/A'}"
                say "  Bundle ID:       #{rel['bundle_identifier'] || 'N/A'}"
                say "  Version:         #{rel['version_string'] || 'N/A'}"
                say "  Release Type:    #{rel['release_type'] || 'N/A'}"
                say "  Auto Submit:     #{rel['auto_submit'] ? 'Yes' : 'No'}"
                say "  Phased Release:  #{rel['phased_release'] ? 'Yes' : 'No'}"
                say ''
                if rel['whats_new'] && !rel['whats_new'].empty?
                  say "What's New:", :bold
                  say "  #{rel['whats_new']}"
                  say ''
                end
                say 'URLs:', :bold
                say "  Support:    #{rel['support_url'] || 'N/A'}"
                say "  Marketing:  #{rel['marketing_url'] || 'N/A'}"
                say "  Privacy:    #{rel['privacy_url'] || 'N/A'}"
                if rel['scheduled_date']
                  say ''
                  say "Scheduled Date: #{rel['scheduled_date']}"
                end
              rescue Mysigner::NotFoundError
                error "Release not found with ID: #{release_id}"
                say ''
                say "Run 'mysigner release list' to see available IDs", :yellow
                exit 1
              rescue Mysigner::ClientError => e
                error "Failed to fetch release: #{e.message}"
                exit 1
              end

            when 'create'
              say '🚀 Creating release configuration...', :cyan
              say ''

              body = {}
              body[:bundle_id_id] = options[:bundle_id_id] if options[:bundle_id_id]
              body[:whats_new] = options[:whats_new] if options[:whats_new]
              body[:support_url] = options[:support_url] if options[:support_url]
              body[:marketing_url] = options[:marketing_url] if options[:marketing_url]
              body[:privacy_url] = options[:privacy_url] if options[:privacy_url]
              body[:auto_submit] = options[:auto_submit] unless options[:auto_submit].nil?
              body[:phased_release] = options[:phased_release] unless options[:phased_release].nil?
              body[:release_type] = options[:release_type] if options[:release_type]
              body[:scheduled_date] = options[:scheduled_date] if options[:scheduled_date]

              begin
                response = client.post(
                  "/api/v1/organizations/#{config.current_organization_id}/app_store_releases",
                  body: body
                )
                rel = response[:data]['app_store_release'] || response[:data]

                say '✓ Release configuration created!', :green
                say ''
                say 'Details:', :bold
                say "  ID:             #{rel['id']}"
                say "  Bundle ID:      #{rel['bundle_identifier'] || 'N/A'}"
                say "  Release Type:   #{rel['release_type'] || 'N/A'}"
                say "  Auto Submit:    #{rel['auto_submit'] ? 'Yes' : 'No'}"
                say "  Phased Release: #{rel['phased_release'] ? 'Yes' : 'No'}"
              rescue Mysigner::ValidationError => e
                if e.message.include?('already exists') || (e.error_code && e.error_code.to_s == '409')
                  error 'Release configuration already exists for this bundle ID'
                  say ''
                  say "💡 Use 'mysigner release update ID' to modify it", :cyan
                  say "   Run 'mysigner release list' to find the ID", :yellow
                else
                  error "Validation failed: #{e.message}"
                  e.details&.each do |field, errors|
                    errors_text = errors.is_a?(Array) ? errors.join(', ') : errors.to_s
                    say "  #{field}: #{errors_text}", :red
                  end
                end
                exit 1
              rescue Mysigner::ClientError => e
                if e.message.include?('409') || e.message.include?('already exists')
                  error 'Release configuration already exists for this bundle ID'
                  say ''
                  say "💡 Use 'mysigner release update ID' to modify it", :cyan
                  say "   Run 'mysigner release list' to find the ID", :yellow
                else
                  error "Failed to create release: #{e.message}"
                end
                exit 1
              end

            when 'update'
              release_id = args[0]

              unless release_id
                error 'Usage: mysigner release update ID [OPTIONS]'
                say ''
                say "Run 'mysigner release list' to see available IDs", :yellow
                exit 1
              end

              body = {}
              body[:whats_new] = options[:whats_new] if options[:whats_new]
              body[:support_url] = options[:support_url] if options[:support_url]
              body[:marketing_url] = options[:marketing_url] if options[:marketing_url]
              body[:privacy_url] = options[:privacy_url] if options[:privacy_url]
              body[:auto_submit] = options[:auto_submit] unless options[:auto_submit].nil?
              body[:phased_release] = options[:phased_release] unless options[:phased_release].nil?
              body[:release_type] = options[:release_type] if options[:release_type]
              body[:scheduled_date] = options[:scheduled_date] if options[:scheduled_date]

              say '🚀 Updating release configuration...', :cyan
              say ''

              begin
                response = client.patch(
                  "/api/v1/organizations/#{config.current_organization_id}/app_store_releases/#{release_id}",
                  body: body
                )
                rel = response[:data]['app_store_release'] || response[:data]

                say '✓ Release configuration updated!', :green
                say ''
                say 'Details:', :bold
                say "  ID:             #{rel['id']}"
                say "  Bundle ID:      #{rel['bundle_identifier'] || 'N/A'}"
                say "  Release Type:   #{rel['release_type'] || 'N/A'}"
                say "  Auto Submit:    #{rel['auto_submit'] ? 'Yes' : 'No'}"
                say "  Phased Release: #{rel['phased_release'] ? 'Yes' : 'No'}"
              rescue Mysigner::NotFoundError
                error "Release not found with ID: #{release_id}"
                say ''
                say "Run 'mysigner release list' to see available IDs", :yellow
                exit 1
              rescue Mysigner::ValidationError => e
                error "Validation failed: #{e.message}"
                e.details&.each do |field, errors|
                  errors_text = errors.is_a?(Array) ? errors.join(', ') : errors.to_s
                  say "  #{field}: #{errors_text}", :red
                end
                exit 1
              rescue Mysigner::ClientError => e
                error "Failed to update release: #{e.message}"
                exit 1
              end

            when 'help'
              invoke :help, ['release']
            else
              error "Unknown action: #{action}"
              say 'Available actions: list, show, create, update, help', :yellow
              exit 1
            end
          end
        end
      end
    end
  end
end
