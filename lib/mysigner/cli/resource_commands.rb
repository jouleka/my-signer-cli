module Mysigner
  class CLI < Thor
    module ResourceCommands
      def self.included(base)
        base.class_eval do
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
          method_option :type, type: :string, aliases: '-p', desc: 'Filter by type (DEVELOPMENT, DISTRIBUTION)'
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

          desc "certificate ACTION", "Manage signing certificates (check, download)"
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
              
              say "🔍 Checking local certificates...", :cyan
              say ""
              
              checker = Signing::CertificateChecker.new
              
              begin
                certificates = checker.check!
                
                if certificates.empty?
                  say "No code signing certificates found in local Keychain", :yellow
                  say ""
                  say "⚠️  Important:", :yellow
                  say "  This command checks certificates INSTALLED ON YOUR MAC.", :white
                  say "  Certificates in My Signer API are not automatically installed locally.", :white
                  say ""
                  say "To install certificates:", :cyan
                  say "  1. List certificates in My Signer: mysigner certificates", :white
                  say "  2. Download one: mysigner certificate download <ID>", :white
                  say "  3. Double-click the .cer file to install in Keychain", :white
                  say ""
                  say "Or download from Apple Developer:", :cyan
                  say "  https://developer.apple.com/account/resources/certificates/list", :white
                  return
                end
                
                # Group by status
                by_status = checker.by_status
                
                # Show valid certificates
                if by_status[:valid].any?
                  say "✓ Valid Certificates (#{by_status[:valid].count})", :green
                  say ""
                  by_status[:valid].each do |cert|
                    say "  #{cert[:name]}", :green
                    say "    Type: #{cert[:type]}"
                    say "    Team: #{cert[:team_id] || 'Unknown'}"
                    say "    Expires: #{cert[:expires_at].strftime('%Y-%m-%d')} (#{cert[:days_until_expiry]} days)", :white
                    say ""
                  end
                end
                
                # Show expiring soon certificates
                if by_status[:expiring_soon].any?
                  say "⚠️  Expiring Soon (#{by_status[:expiring_soon].count})", :yellow
                  say ""
                  by_status[:expiring_soon].each do |cert|
                    say "  #{cert[:name]}", :yellow
                    say "    Type: #{cert[:type]}"
                    say "    Team: #{cert[:team_id] || 'Unknown'}"
                    say "    Expires: #{cert[:expires_at].strftime('%Y-%m-%d')} (#{cert[:days_until_expiry]} days)", :yellow
                    say ""
                  end
                  say "Renew these certificates soon to avoid build failures!", :yellow
                  say ""
                end
                
                # Show expired certificates
                if by_status[:expired].any?
                  say "✗ Expired Certificates (#{by_status[:expired].count})", :red
                  say ""
                  by_status[:expired].each do |cert|
                    say "  #{cert[:name]}", :red
                    say "    Type: #{cert[:type]}"
                    say "    Team: #{cert[:team_id] || 'Unknown'}"
                    say "    Expired: #{cert[:expires_at].strftime('%Y-%m-%d')} (#{cert[:days_until_expiry].abs} days ago)", :red
                    say ""
                  end
                  say "These certificates will cause build failures. Renew them at:", :red
                  say "  https://developer.apple.com/account/resources/certificates/list", :white
                  say ""
                end
                
                # Summary
                say "─" * 80, :cyan
                say "Total: #{certificates.count} certificate#{certificates.count == 1 ? '' : 's'} installed locally", :cyan
                if checker.has_issues?
                  say "Status: ⚠️  Action required", :yellow
                else
                  say "Status: ✓ All certificates valid", :green
                end
                say ""
                say "💡 Tip: These are certificates INSTALLED ON YOUR MAC.", :cyan
                say "    To see all certificates in My Signer API, run: mysigner certificates", :white
                
              rescue Signing::CertificateChecker::CheckError => e
                error "Certificate check failed: #{e.message}"
                say ""
                say "This usually means:", :yellow
                say "  • Keychain is locked", :white
                say "  • No certificates installed", :white
                say "  • Security command not available", :white
                exit 1
              end
              
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
        end
      end
    end
  end
end
