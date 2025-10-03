require 'thor'
require 'json'
require 'time'

module Mysigner
  class CLI < Thor
    class_option :verbose, type: :boolean, aliases: '-v', desc: 'Verbose output'

    def self.exit_on_failure?
      true
    end

    desc "version", "Show version"
    def version
      puts "My Signer CLI v#{Mysigner::VERSION}"
    end

    desc "login", "Authenticate with My Signer API"
    long_desc <<~DESC
      Authenticate with My Signer API by providing your API token.
      
      You'll be prompted for:
      - API URL (default: http://localhost:3000)
      - API Token (from My Signer dashboard)
      - Organization (select from list)
      
      Your credentials will be stored securely in ~/.mysigner/config.yml
    DESC
    def login
      # Check if already logged in
      config = Config.new
      if config.exists?
        config.load
        say "⚠️  Already logged in", :yellow
        say ""
        say "Current configuration:", :yellow
        say "  Organization ID: #{config.organization_id}"
        say "  API URL: #{config.api_url}"
        say ""
        
        if yes?("Do you want to logout and login with different credentials? (y/n)")
          config.clear
          say "✓ Logged out successfully", :green
          say ""
        else
          say "Login cancelled. Use 'mysigner logout' to logout first.", :yellow
          return
        end
      end

      say "🔐 My Signer Login", :cyan
      say ""

      # Get API URL
      api_url = ask("API URL:", default: "http://localhost:3000")
      api_url = api_url.strip

      # Get API token
      api_token = ask("API Token:", echo: false)
      say "" # New line after hidden input
      api_token = api_token.strip

      if api_token.empty?
        error "API token cannot be empty"
        exit 1
      end

      # Test connection
      say "Testing connection...", :yellow
      
      begin
        client = Client.new(api_url: api_url, api_token: api_token)
        response = client.test_connection
        
        if response[:success]
          say "✓ Connection successful", :green
        else
          error "Connection failed"
          exit 1
        end
      rescue Mysigner::UnauthorizedError => e
        error "Authentication failed: Invalid API token"
        exit 1
      rescue Mysigner::ConnectionError => e
        error "Connection failed: #{e.message}"
        say "Make sure My Signer API is running at #{api_url}", :yellow
        exit 1
      rescue => e
        error "Unexpected error: #{e.message}"
        exit 1
      end

      # Fetch organizations
      say "Fetching organizations...", :yellow

      begin
        response = client.get('/api/v1/organizations')
        organizations = response[:data]['organizations']

        if organizations.empty?
          error "No organizations found. Please create one in the web dashboard first."
          exit 1
        end

        # Let user select organization
        say "\nAvailable organizations:", :cyan
        organizations.each_with_index do |org, index|
          role = org['role'] || 'member'
          say "  #{index + 1}. #{org['name']} (#{role})"
        end
        say ""

        org_index = ask("Select organization (1-#{organizations.length}):", limited_to: (1..organizations.length).map(&:to_s))
        selected_org = organizations[org_index.to_i - 1]

        # Save configuration
        config = Config.new
        config.api_url = api_url
        config.api_token = api_token
        config.organization_id = selected_org['id']
        config.save

        say ""
        say "✓ Successfully logged in!", :green
        say "Organization: #{selected_org['name']}", :green
        say "Config saved to: #{Config::CONFIG_FILE}", :green
      rescue Mysigner::ClientError => e
        error "Failed to fetch organizations: #{e.message}"
        exit 1
      end
    end

    desc "logout", "Clear stored credentials"
    def logout
      config = Config.new
      
      unless config.exists?
        say "No stored credentials found", :yellow
        return
      end

      if yes?("Are you sure you want to logout? (y/n)")
        config.clear
        say "✓ Successfully logged out", :green
        say "Config file removed: #{Config::CONFIG_FILE}", :green
      else
        say "Logout cancelled", :yellow
      end
    end

    desc "status", "Show connection status and configuration"
    def status
      config = Config.new

      unless config.exists?
        error "Not logged in. Run 'mysigner login' first."
        exit 1
      end

      config.load

      say "📊 My Signer Status", :cyan
      say ""
      say "Configuration:", :bold
      say "  API URL:         #{config.api_url}"
      say "  API Token:       #{config.display[:api_token]}"
      say "  Organization ID: #{config.organization_id || '(not set)'}"
      say ""

      # Test connection
      say "Connection:", :bold
      
      begin
        client = Client.new(api_url: config.api_url, api_token: config.api_token)
        response = client.test_connection
        
        say "  Status: ✓ Connected", :green
        
        # Get organization details if org_id is set
        if config.organization_id
          org_response = client.get("/api/v1/organizations/#{config.organization_id}")
          org = org_response[:data]
          
          say ""
          say "Organization:", :bold
          say "  Name:    #{org['name']}"
          say "  Role:    #{org['role'] || 'member'}"
          say "  Members: #{org['member_count'] || 0}"
        end
      rescue Mysigner::UnauthorizedError
        say "  Status: ✗ Unauthorized (invalid token)", :red
        exit 1
      rescue Mysigner::ConnectionError => e
        say "  Status: ✗ Connection failed", :red
        say "  Error: #{e.message}", :red
        exit 1
      rescue => e
        say "  Status: ✗ Error", :red
        say "  Error: #{e.message}", :red
        exit 1
      end
    end

    desc "orgs", "List accessible organizations"
    def orgs
      config = load_config
      client = create_client(config)

      say "📋 Organizations", :cyan
      say ""

      begin
        response = client.get('/api/v1/organizations')
        organizations = response[:data]['organizations']

        if organizations.empty?
          say "No organizations found", :yellow
          return
        end

        organizations.each do |org|
          current = org['id'] == config.organization_id ? " (current)" : ""
          role = org['role'] || 'member'
          say "  • #{org['name']}#{current}", :green
          say "    ID: #{org['id']} | Role: #{role} | Members: #{org['member_count'] || 0}"
          say ""
        end

        say "Total: #{organizations.length} organization(s)"
        say ""
        say "Tip: Use 'mysigner switch' to change organizations", :yellow
      rescue Mysigner::ClientError => e
        error "Failed to fetch organizations: #{e.message}"
        exit 1
      end
    end

    desc "switch", "Switch to a different organization"
    long_desc <<~DESC
      Switch to a different organization without logging out.
      
      This command will:
      - Show your current organization
      - List all available organizations
      - Let you select a new one
      - Update your configuration
    DESC
    def switch
      config = load_config
      client = create_client(config)

      say "🔄 Switch Organization", :cyan
      say ""

      begin
        # Get current org details
        current_org_response = client.get("/api/v1/organizations/#{config.organization_id}")
        current_org = current_org_response[:data]

        say "Current organization:", :yellow
        say "  #{current_org['name']} (ID: #{config.organization_id})"
        say ""

        # Fetch all organizations
        response = client.get('/api/v1/organizations')
        organizations = response[:data]['organizations']

        if organizations.length < 2
          say "You only have access to one organization.", :yellow
          say "Nothing to switch to!", :yellow
          return
        end

        # Show available organizations
        say "Available organizations:", :cyan
        organizations.each_with_index do |org, index|
          current = org['id'] == config.organization_id ? " (current)" : ""
          role = org['role'] || 'member'
          say "  #{index + 1}. #{org['name']}#{current} (#{role})"
        end
        say ""

        # Let user select
        org_index = ask("Select organization (1-#{organizations.length}):", limited_to: (1..organizations.length).map(&:to_s))
        selected_org = organizations[org_index.to_i - 1]

        if selected_org['id'] == config.organization_id
          say ""
          say "Already using this organization!", :yellow
          return
        end

        # Update config
        config.organization_id = selected_org['id']
        config.save

        say ""
        say "✓ Successfully switched!", :green
        say "New organization: #{selected_org['name']}", :green
        say ""
        say "Run 'mysigner status' to verify", :yellow
      rescue Mysigner::ClientError => e
        error "Failed to switch organization: #{e.message}"
        exit 1
      end
    end

    desc "config", "Show current configuration"
    def config
      config = Config.new

      unless config.exists?
        error "No configuration found. Run 'mysigner login' first."
        exit 1
      end

      config.load

      say "⚙️  Configuration", :cyan
      say ""
      config.display.each do |key, value|
        say "  #{key.to_s.ljust(20)}: #{value}"
      end
      say ""
      say "Config file: #{Config::CONFIG_FILE}"
    end

    desc "devices", "List devices"
    method_option :platform, type: :string, aliases: '-p', desc: 'Filter by platform (IOS, MAC_OS, TV_OS)'
    method_option :status, type: :string, aliases: '-s', desc: 'Filter by status (ENABLED, DISABLED)'
    method_option :search, type: :string, aliases: '-q', desc: 'Search by name or UDID'
    method_option :page, type: :numeric, default: 1, desc: 'Page number'
    method_option :per_page, type: :numeric, default: 50, desc: 'Devices per page'
    def devices
      config = load_config
      client = create_client(config)

      say "📱 Devices", :cyan
      say ""

      # Build query params
      params = {
        page: options[:page],
        per_page: options[:per_page]
      }
      params[:platform] = options[:platform].upcase if options[:platform]
      params[:status] = options[:status].upcase if options[:status]
      params[:q] = options[:search] if options[:search]

      begin
        response = client.get("/api/v1/organizations/#{config.organization_id}/devices", params: params)
        devices = response[:data]['devices']
        pagination = response[:data]['pagination']

        if devices.empty?
          say "No devices found", :yellow
          say ""
          say "Tip: Register a device with 'mysigner device add NAME UDID'", :yellow
          return
        end

        # Display devices
        devices.each do |device|
          status_icon = device['status'] == 'ENABLED' ? '✓' : '✗'
          status_color = device['status'] == 'ENABLED' ? :green : :red
          
          say "  #{status_icon} #{device['name']}", status_color
          say "    UDID: #{device['udid']}"
          say "    Platform: #{device['platform']} | Class: #{device['device_class']}"
          say "    Status: #{device['status']}"
          say ""
        end

        # Show pagination
        say "Page #{pagination['page']} of #{pagination['total_pages']} (#{pagination['total']} total)", :yellow
        
        if pagination['page'] < pagination['total_pages']
          say "Run with --page #{pagination['page'] + 1} to see more", :yellow
        end
      rescue Mysigner::ClientError => e
        error "Failed to fetch devices: #{e.message}"
        exit 1
      end
    end

    desc "device SUBCOMMAND", "Manage devices (add, update)"
    method_option :platform, type: :string, default: 'IOS', aliases: '-p', desc: 'Platform (IOS, MAC_OS, TV_OS)'
    def device(action, *args)
      config = load_config
      client = create_client(config)

      case action
      when 'add'
        if args.length < 2
          error "Usage: mysigner device add NAME UDID [--platform IOS]"
          exit 1
        end

        name = args[0]
        udid = args[1]
        platform = options[:platform].upcase

        say "📱 Registering device...", :cyan
        say ""

        begin
          response = client.post(
            "/api/v1/organizations/#{config.organization_id}/devices",
            body: {
              name: name,
              udid: udid,
              platform: platform
            }
          )

          device = response[:data]['device']
          say "✓ Device registered successfully!", :green
          say ""
          say "Details:", :bold
          say "  Name:     #{device['name']}"
          say "  UDID:     #{device['udid']}"
          say "  Platform: #{device['platform']}"
          say "  Status:   #{device['status']}"
        rescue Mysigner::ValidationError => e
          error "Validation failed:"
          if e.details
            e.details.each do |field, errors|
              say "  #{field}: #{errors.join(', ')}", :red
            end
          else
            say "  #{e.message}", :red
          end
          exit 1
        rescue Mysigner::ClientError => e
          if e.message.include?("already exists")
            error "Device with this UDID already exists"
          else
            error "Failed to register device: #{e.message}"
          end
          exit 1
        end
      when 'update'
        if args.length < 2
          error "Usage: mysigner device update ID NEW_NAME"
          exit 1
        end

        device_id = args[0]
        new_name = args[1]

        say "📱 Updating device...", :cyan
        say ""

        begin
          # Get device details first
          response = client.get("/api/v1/organizations/#{config.organization_id}/devices/#{device_id}")
          device = response[:data]

          say "Current name: #{device['name']}", :yellow
          say "New name:     #{new_name}", :green
          say ""

          # Update device
          response = client.patch(
            "/api/v1/organizations/#{config.organization_id}/devices/#{device_id}",
            body: { name: new_name }
          )

          updated_device = response[:data]['device']
          say "✓ Device updated successfully!", :green
          say ""
          say "Details:", :bold
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
      else
        error "Unknown action: #{action}"
        say "Available actions: add, update", :yellow
        exit 1
      end
    end

    desc "profiles", "List provisioning profiles"
    method_option :type, type: :string, aliases: '-t', desc: 'Filter by type (DEVELOPMENT, AD_HOC, APP_STORE, ENTERPRISE)'
    method_option :status, type: :string, aliases: '-s', desc: 'Filter by status (ACTIVE, EXPIRED, INVALID)'
    method_option :search, type: :string, aliases: '-q', desc: 'Search by name or identifier'
    method_option :page, type: :numeric, default: 1, desc: 'Page number'
    method_option :per_page, type: :numeric, default: 50, desc: 'Profiles per page'
    def profiles
      config = load_config
      client = create_client(config)

      say "📄 Provisioning Profiles", :cyan
      say ""

      # Build query params
      params = {
        page: options[:page],
        per_page: options[:per_page]
      }
      params[:type] = options[:type].upcase if options[:type]
      params[:state] = options[:status].upcase if options[:status]
      params[:q] = options[:search] if options[:search]

      begin
        response = client.get("/api/v1/organizations/#{config.organization_id}/profiles", params: params)
        profiles = response[:data]['profiles']
        pagination = response[:data]['pagination']

        if profiles.empty?
          say "No profiles found", :yellow
          say ""
          say "Tip: Profiles are created automatically when you request code signing", :yellow
          return
        end

        # Display profiles
        profiles.each do |profile|
          status_icon = profile['status'] == 'ACTIVE' ? '✓' : '✗'
          status_color = profile['status'] == 'ACTIVE' ? :green : :red
          
          say "  #{status_icon} #{profile['name']}", status_color
          say "    ID: #{profile['id']} | Type: #{profile['profile_type'] || 'N/A'}"
          say "    Bundle ID: #{profile['bundle_id'] || 'N/A'}"
          say "    Status: #{profile['status'] || 'UNKNOWN'}"
          
          if profile['expires_at']
            expires = Time.parse(profile['expires_at']).strftime('%Y-%m-%d')
            say "    Expires: #{expires}"
          end
          
          say ""
        end

        # Show pagination
        say "Page #{pagination['page']} of #{pagination['total_pages']} (#{pagination['total']} total)", :yellow
        
        if pagination['page'] < pagination['total_pages']
          say "Run with --page #{pagination['page'] + 1} to see more", :yellow
        end
      rescue Mysigner::ClientError => e
        error "Failed to fetch profiles: #{e.message}"
        exit 1
      end
    end

    desc "profile SUBCOMMAND", "Manage profiles (download, delete)"
    method_option :output, type: :string, aliases: '-o', desc: 'Output file path (default: profile name)'
    def profile(action, *args)
      config = load_config
      client = create_client(config)

      case action
      when 'download'
        if args.empty?
          error "Usage: mysigner profile download ID [--output path.mobileprovision]"
          exit 1
        end

        profile_id = args[0]

        say "📄 Downloading profile...", :cyan
        say ""

        begin
          # Get profile details first
          response = client.get("/api/v1/organizations/#{config.organization_id}/profiles/#{profile_id}")
          profile = response[:data]

          # Determine output path
          output_path = if options[:output]
            options[:output]
          else
            # Use profile name, sanitize it for filename
            name = profile['name'] || "profile_#{profile['id']}"
            filename = name.gsub(/[^0-9A-Za-z.\-]/, '_')
            "#{filename}.mobileprovision"
          end

          # Download the profile content using the client's connection with auth
          download_url = "/api/v1/organizations/#{config.organization_id}/profiles/#{profile_id}/download"
          
          say "Fetching profile content...", :yellow
          
          # Use Faraday directly with proper auth for binary download
          conn = Faraday.new(url: config.api_url) do |f|
            f.request :authorization, 'Bearer', config.api_token
            f.adapter Faraday.default_adapter
          end
          
          response = conn.get(download_url) do |req|
            req.options.timeout = 30  # 30 second timeout
            req.options.open_timeout = 10  # 10 second connection timeout
          end
          
          unless response.success?
            # Check if it's a JSON error response
            if response.headers['content-type']&.include?('json')
              begin
                error_data = JSON.parse(response.body)
                error "Download failed: #{error_data['message'] || error_data['error']}"
              rescue
                error "Download failed with status #{response.status}"
              end
            else
              error "Download failed with status #{response.status}"
            end
            exit 1
          end

          # Write binary content directly to file
          File.binwrite(output_path, response.body)

          say "✓ Profile downloaded successfully!", :green
          say ""
          say "Details:", :bold
          say "  Name:      #{profile['name']}"
          say "  Type:      #{profile['profile_type'] || 'N/A'}"
          say "  Bundle ID: #{profile['bundle_id_identifier'] || 'N/A'}"
          say "  Status:    #{profile['state'] || 'UNKNOWN'}"
          say "  File:      #{output_path}"
          say ""
          say "File size: #{response.body.bytesize} bytes", :yellow
        rescue Mysigner::NotFoundError
          error "Profile not found with ID: #{profile_id}"
          exit 1
        rescue Mysigner::ClientError => e
          error "Failed to download profile: #{e.message}"
          exit 1
        rescue => e
          error "Failed to save file: #{e.message}"
          exit 1
        end
      when 'delete'
        if args.empty?
          error "Usage: mysigner profile delete ID"
          exit 1
        end

        profile_id = args[0]

        say "📄 Deleting profile...", :cyan
        say ""

        begin
          # Get profile details first
          response = client.get("/api/v1/organizations/#{config.organization_id}/profiles/#{profile_id}")
          profile = response[:data]

          # Confirm deletion
          say "You are about to delete:", :yellow
          say "  Name: #{profile['name']}"
          say "  Type: #{profile['profile_type']}"
          say "  Bundle ID: #{profile['bundle_id_identifier'] || 'N/A'}"
          say ""

          if yes?("Are you sure you want to delete this profile? (y/n)")
            client.delete("/api/v1/organizations/#{config.organization_id}/profiles/#{profile_id}")
            say ""
            say "✓ Profile deleted successfully!", :green
          else
            say "Deletion cancelled", :yellow
          end
        rescue Mysigner::NotFoundError
          error "Profile not found with ID: #{profile_id}"
          exit 1
        rescue Mysigner::ClientError => e
          error "Failed to delete profile: #{e.message}"
          exit 1
        end
      else
        error "Unknown action: #{action}"
        say "Available actions: download, delete", :yellow
        exit 1
      end
    end

    desc "certificates", "List signing certificates"
    method_option :type, type: :string, aliases: '-t', desc: 'Filter by type (DEVELOPMENT, DISTRIBUTION)'
    method_option :status, type: :string, aliases: '-s', desc: 'Filter by status (ACTIVE, EXPIRED, REVOKED)'
    method_option :search, type: :string, aliases: '-q', desc: 'Search by name'
    method_option :page, type: :numeric, default: 1, desc: 'Page number'
    method_option :per_page, type: :numeric, default: 50, desc: 'Certificates per page'
    def certificates
      config = load_config
      client = create_client(config)

      say "🔐 Signing Certificates", :cyan
      say ""

      # Build query params
      params = {
        page: options[:page],
        per_page: options[:per_page]
      }
      params[:certificate_type] = options[:type].upcase if options[:type]
      params[:status] = options[:status].upcase if options[:status]
      params[:q] = options[:search] if options[:search]

      begin
        response = client.get("/api/v1/organizations/#{config.organization_id}/certificates", params: params)
        certificates = response[:data]['certificates']
        pagination = response[:data]['pagination']

        if certificates.empty?
          say "No certificates found", :yellow
          say ""
          say "Tip: Certificates are synced automatically from App Store Connect", :yellow
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
          
          say ""
        end

        # Show pagination
        say "Page #{pagination['page']} of #{pagination['total_pages']} (#{pagination['total']} total)", :yellow
        
        if pagination['page'] < pagination['total_pages']
          say "Run with --page #{pagination['page'] + 1} to see more", :yellow
        end
      rescue Mysigner::ClientError => e
        error "Failed to fetch certificates: #{e.message}"
        exit 1
      end
    end

    desc "certificate download ID", "Download a signing certificate"
    method_option :output, type: :string, aliases: '-o', desc: 'Output file path (default: certificate name)'
    def certificate(action, *args)
      config = load_config
      client = create_client(config)

      case action
      when 'download'
        if args.empty?
          error "Usage: mysigner certificate download ID [--output path.cer]"
          exit 1
        end

        certificate_id = args[0]

        say "🔐 Downloading certificate...", :cyan
        say ""

        begin
          # Get certificate details first
          response = client.get("/api/v1/organizations/#{config.organization_id}/certificates/#{certificate_id}")
          certificate = response[:data]

          # Determine output path
          output_path = if options[:output]
            options[:output]
          else
            # Use certificate name, sanitize it for filename
            name = certificate['name'] || "certificate_#{certificate['id']}"
            filename = name.gsub(/[^0-9A-Za-z.\-]/, '_')
            "#{filename}.cer"
          end

          # Download the certificate content (binary response)
          download_url = "/api/v1/organizations/#{config.organization_id}/certificates/#{certificate_id}/download"
          
          say "Fetching certificate content...", :yellow
          
          # Use Faraday directly with proper auth for binary download
          conn = Faraday.new(url: config.api_url) do |f|
            f.request :authorization, 'Bearer', config.api_token
            f.adapter Faraday.default_adapter
          end
          
          response = conn.get(download_url) do |req|
            req.options.timeout = 30  # 30 second timeout
            req.options.open_timeout = 10  # 10 second connection timeout
          end
          
          unless response.success?
            # Check if it's a JSON error response
            if response.headers['content-type']&.include?('json')
              begin
                error_data = JSON.parse(response.body)
                error "Download failed: #{error_data['message'] || error_data['error']}"
              rescue
                error "Download failed with status #{response.status}"
              end
            else
              error "Download failed with status #{response.status}"
            end
            exit 1
          end

          # Write binary content directly to file
          File.binwrite(output_path, response.body)

          say "✓ Certificate downloaded successfully!", :green
          say ""
          say "Details:", :bold
          say "  Name:      #{certificate['name']}"
          say "  Type:      #{certificate['certificate_type'] || 'N/A'}"
          say "  Serial:    #{certificate['serial_number'] || 'N/A'}"
          say "  Status:    #{certificate['status'] || 'UNKNOWN'}"
          say "  File:      #{output_path}"
          say ""
          say "File size: #{response.body.bytesize} bytes", :yellow
        rescue Mysigner::NotFoundError
          error "Certificate not found with ID: #{certificate_id}"
          exit 1
        rescue Mysigner::ClientError => e
          error "Failed to download certificate: #{e.message}"
          exit 1
        rescue => e
          error "Failed to save file: #{e.message}"
          exit 1
        end
      else
        error "Unknown action: #{action}"
        say "Available actions: download", :yellow
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

    private

    def load_config
      config = Config.new
      
      unless config.exists?
        error "Not logged in. Run 'mysigner login' first."
        exit 1
      end

      config.load

      unless config.valid?
        error "Invalid configuration. Please run 'mysigner login' again."
        exit 1
      end

      config
    end

    def create_client(config)
      Client.new(api_url: config.api_url, api_token: config.api_token)
    end

    def error(message)
      say "✗ Error: #{message}", :red
    end
  end
end

