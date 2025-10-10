module Mysigner
  class CLI < Thor
    module AuthCommands
      def self.included(base)
        base.class_eval do
          desc "version", "Show version information"
          def version
            say "My Signer CLI v#{Mysigner::VERSION}", :cyan
            say ""
            say "Ruby:        #{RUBY_VERSION} (#{RUBY_PLATFORM})", :white
            say "Install:     #{File.expand_path('../../../..', __FILE__)}", :white
            say "Config:      #{Config::CONFIG_FILE}", :white
            say ""
            say "Repository:  https://github.com/yourusername/my-signer-cli", :white
            say "Issues:      https://github.com/yourusername/my-signer-cli/issues", :white
          end

          desc "login", "Authenticate with My Signer API"
          long_desc <<~DESC
            Authenticate with My Signer API using an API token.
            
            New user? Run 'mysigner onboard' for step-by-step guidance.
            
            Your credentials will be stored securely in ~/.mysigner/config.yml
            
            Note: API tokens are organization-specific. This token will only
            grant access to the organization it was created in.
          DESC
          def login
            # Check if already logged in
            config = Config.new
            if config.exists?
              config.load
              say "⚠️  Already logged in", :yellow
              say ""
              say "Current configuration:", :yellow
              say "  User: #{config.user_email || '(unknown)'}"
              say "  Organization: #{config.org_name || '(unknown)'} (ID: #{config.current_organization_id})"
              say "  API URL: #{config.api_url}"
              say ""
              
              if yes?("Do you want to logout and login with different user? (y/n)")
                config.clear
                say "✓ Logged out successfully", :green
                say ""
              else
                say "Login cancelled. Use 'mysigner logout' to logout first.", :yellow
                say ""
                say "💡 Tip: Use 'mysigner switch' to switch organizations for the same user", :yellow
                return
              end
            end

            say "🔐 My Signer Login", :cyan
            say "=" * 80, :cyan
            say ""

            # Get API URL with smart default
            api_url = prompt_api_url
            say ""
            
            # Get user email
            user_email = prompt_for_email
            say ""
            
            # Show guidance for getting token
            show_token_guidance(api_url)
            
            api_token = ask("API Token:", echo: false)
            say "" # New line after hidden input
            
            if api_token.empty?
              error "API token cannot be empty"
              say ""
              say "💡 Tip: Run 'mysigner onboard' for detailed guidance", :yellow
              exit 1
            end

            say "Validating token and email...", :yellow
            
            begin
              client = Client.new(api_url: api_url, api_token: api_token, user_email: user_email)
              response = client.test_connection
              
              if response[:success]
                say "✓ Token valid", :green
              else
                error "Connection failed"
                handle_connection_failure(api_url)
                exit 1
              end
              
              # Fetch organization info (token can only access its own org)
              say "Detecting organization...", :yellow
              
              # Try to fetch organizations - with org-specific tokens, this will return only the token's org
              orgs_response = client.get('/api/v1/organizations')
              organizations = orgs_response[:data]['organizations']
              
              if ENV['DEBUG']
                say "DEBUG: Found #{organizations.length} organizations", :cyan
                organizations.each do |org|
                  say "DEBUG:   - #{org['name']} (ID: #{org['id']})", :cyan
                end
              end
              
              if organizations.empty?
                error "No organizations found for this token"
                say ""
                say "This might mean:", :yellow
                say "  • Your token doesn't have access to any organizations", :yellow
                say "  • The token was created but the organization was deleted", :yellow
                say ""
                show_create_org_guidance(api_url)
                exit 1
              end

              # With org-specific tokens, there should only be one organization
              selected_org = organizations.first
              org_id = selected_org['id']
              
              say "DEBUG: Fetching details for organization #{org_id}...", :cyan if ENV['DEBUG']
              
              # Get detailed org info to extract user email and token_organization_id
              org_response = client.get("/api/v1/organizations/#{org_id}")
              org_data = org_response[:data]
              
              say "DEBUG: Organization data received", :cyan if ENV['DEBUG']
              
              say "✓ Organization detected: #{org_data['name']}", :green
              say "✓ Email validated: #{user_email}", :green
              say ""
              
              # Save configuration with multi-token support
              config = Config.new
              config.api_url = api_url
              config.user_email = user_email # Save the verified email
              config.current_organization_id = org_id
              config.save_token_for_org(org_id, org_data['name'], api_token)
              config.save

              say ""
              say "=" * 80, :green
              say "✓ Successfully logged in!", :green
              say "=" * 80, :green
              say ""
              say "Organization: #{org_data['name']} (ID: #{org_id})", :cyan
              say "Role: #{org_data['role'] || 'member'}", :cyan
              say "Config saved to: #{Config::CONFIG_FILE}", :cyan
              say ""
              say "🔒 Security Note:", :yellow
              say "  Your token is organization-specific and can only access", :yellow
              say "  #{org_data['name']}. To access other organizations,", :yellow
              say "  use 'mysigner switch' to add tokens for those organizations.", :yellow
              say ""
              say "🚀 Next steps:", :bold
              say "  cd your-ios-project"
              say "  mysigner ship testflight"
              say ""
              say "💡 Helpful commands:", :cyan
              say "  • mysigner doctor     - Check your environment"
              say "  • mysigner orgs       - List all organizations"
              say "  • mysigner switch     - Switch to another organization"
              say ""
              
            rescue Mysigner::UnauthorizedError => e
              error "Authentication failed"
              say ""
              
              # Check if it's an email validation error
              if e.message.include?("doesn't belong to") || e.message.include?("use your own token")
                say "⚠️  Token Email Mismatch", :yellow
                say ""
                say "The token you provided doesn't belong to #{user_email}.", :yellow
                say ""
                say "This could mean:", :yellow
                say "  • You're using a token created by someone else", :yellow
                say "  • You're using a token from a different account", :yellow
                say ""
                say "💡 Solutions:", :cyan
                say "  1. Generate a new token from your own account at:", :cyan
                say "     #{api_url}", :cyan
                say "  2. Make sure you're logged in as #{user_email} on the web", :cyan
                say "  3. Check that you entered the correct email address", :cyan
              else
                handle_unauthorized_error(api_url)
              end
              exit 1
            rescue Mysigner::ConnectionError => e
              handle_connection_error(e, api_url)
              exit 1
            rescue => e
              handle_unexpected_error(e, api_url)
              exit 1
            end
          end

          desc "onboard", "Interactive onboarding guide for first-time users"
          long_desc <<~DESC
            Step-by-step guide to get started with My Signer CLI.
            
            This command will:
            1. Check if you have an account
            2. Guide you through creating an organization
            3. Help you generate an API token
            4. Configure your CLI
          DESC
          def onboard
            say "🚀 My Signer Setup Guide", :cyan
            say "=" * 80, :cyan
            say ""
            say "Welcome! Let's get you set up with My Signer.", :bold
            say ""

            # Get API URL
            api_url = prompt_api_url
            say ""

            # Step 1: Check if user has account
            say "Step 1: Account Setup", :cyan
            say "-" * 80
            say ""
            say "Do you have a My Signer account?", :bold
            say "  1. Yes, I have an account"
            say "  2. No, I need to sign up"
            say ""
            
            choice = ask("Select (1-2):", limited_to: ['1', '2'])
            say ""
            
            if choice == '2'
              # Guide to signup
              say "📝 Let's create your account:", :cyan
              say ""
              say "1. Open your browser and go to:", :bold
              say "   #{api_url}", :green
              say ""
              say "2. Click 'Sign Up' and create your account", :bold
              say ""
              say "3. Verify your email (check your inbox)", :bold
              say ""
              
              unless yes?("Have you created your account? (y/n)")
                say ""
                say "Come back and run 'mysigner onboard' when you're ready!", :yellow
                return
              end
              say ""
            end

            # Step 2: Organization
            say "Step 2: Organization Setup", :cyan
            say "-" * 80
            say ""
            say "Do you have an organization?", :bold
            say "  1. Yes, I have an organization"
            say "  2. No, I need to create one"
            say ""
            
            choice = ask("Select (1-2):", limited_to: ['1', '2'])
            say ""
            
            if choice == '2'
              # Guide to create org
              say "🏢 Let's create your organization:", :cyan
              say ""
              say "1. Go to the dashboard:", :bold
              say "   #{api_url}", :green
              say ""
              say "2. Sign in with your account", :bold
              say ""
              say "3. Click 'Create Organization'", :bold
              say ""
              say "4. Enter your organization name (e.g., 'My Startup')", :bold
              say ""
              
              unless yes?("Have you created your organization? (y/n)")
                say ""
                say "Come back and run 'mysigner onboard' when you're ready!", :yellow
                return
              end
              say ""
            end

            # Step 3: API Token
            say "Step 3: Generate API Token", :cyan
            say "-" * 80
            say ""
            say "Now let's generate your API token:", :bold
            say ""
            say "1. Go to API Tokens:", :bold
            say "   #{api_url}/organizations/YOUR_ORG_ID/api_tokens", :green
            say ""
            say "   Or navigate: Dashboard → Your Organization → API Tokens", :cyan
            say ""
            say "2. Click 'Create Token'", :bold
            say ""
            say "3. Fill in the details:", :bold
            say "   • Name: 'CLI Access' (or anything you like)"
            say "   • Scopes: ✓ read  ✓ write  (minimum required)"
            say "   • Expiration: Choose 'Never' or '1 year'"
            say ""
            say "4. Click 'Create' and COPY the token", :bold
            say "   ⚠️  You'll only see it once!", :yellow
            say ""
            
            unless yes?("Have you generated and copied your token? (y/n)")
              say ""
              say "Come back and run 'mysigner onboard' when you have your token!", :yellow
              return
            end
            say ""

            # Step 4: Login
            say "Step 4: Login to CLI", :cyan
            say "-" * 80
            say ""
            say "Great! Now let's log you in.", :bold
            say ""
            
            # Get user email
            user_email = prompt_for_email
            say ""
            
            api_token = ask("Paste your API Token:", echo: false)
            say ""
            
            if api_token.empty?
              error "Token cannot be empty"
              say "Run 'mysigner onboard' again when you have your token", :yellow
              return
            end

            say "Validating token and email...", :yellow
            
            begin
              client = Client.new(api_url: api_url, api_token: api_token, user_email: user_email)
              response = client.test_connection
              
              unless response[:success]
                error "Connection test failed"
                return
              end
              
              response = client.get('/api/v1/organizations')
              organizations = response[:data]['organizations']
              
              if organizations.empty?
                error "No organizations found"
                say "Please check that your token is associated with an organization", :yellow
                return
              end

              selected_org = organizations.first
              org_id = selected_org['id']
              
              # Get detailed org info
              org_response = client.get("/api/v1/organizations/#{org_id}")
              org_data = org_response[:data]
              
              config = Config.new
              config.api_url = api_url
              config.user_email = user_email # Save the verified email
              config.current_organization_id = org_id
              config.save_token_for_org(org_id, org_data['name'], api_token)
              config.save

              say ""
              say "=" * 80, :green
              say "🎉 Setup Complete!", :green
              say "=" * 80, :green
              say ""
              say "You're all set up and ready to go!", :bold
              say ""
              say "User: #{user_email}", :cyan
              say "Organization: #{org_data['name']} (ID: #{org_id})", :cyan
              say "Config saved to: #{Config::CONFIG_FILE}", :cyan
              say ""
              say "🔒 Security Note:", :yellow
              say "  Your token is organization-specific. Use 'mysigner switch'", :yellow
              say "  to add tokens for other organizations.", :yellow
              say ""
              say "🚀 Try your first ship:", :bold
              say ""
              say "  cd your-ios-project"
              say "  mysigner ship testflight"
              say ""
              say "💡 Tips:", :cyan
              say "  • Run 'mysigner doctor' to check your environment"
              say "  • Run 'mysigner --help' to see all commands"
              say "  • Run 'mysigner status' to verify your setup"
              say ""
              
            rescue Mysigner::UnauthorizedError => e
              error "Authentication failed"
              say ""
              
              # Check if it's an email validation error
              if e.message.include?("doesn't belong to") || e.message.include?("use your own token")
                say "⚠️  Token Email Mismatch", :yellow
                say ""
                say "The token you provided doesn't belong to #{user_email}.", :yellow
                say ""
                say "Please make sure you:", :yellow
                say "  1. Are logged in as #{user_email} on the web dashboard", :yellow
                say "  2. Generate the token while logged in as #{user_email}", :yellow
                say "  3. Enter the correct email address", :yellow
              else
                say "The token you entered is invalid. Please:", :yellow
                say "  1. Check you copied the entire token"
                say "  2. Make sure the token hasn't been revoked"
                say "  3. Generate a new token if needed"
              end
              say ""
              say "Run 'mysigner onboard' to try again", :yellow
            rescue => e
              error "Setup failed: #{e.message}"
              say ""
              say "Run 'mysigner onboard' to try again", :yellow
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
            say "  User:            #{config.user_email || '(unknown)'}"
            say "  Encryption:      #{config.encrypted_config? ? '✓ Enabled' : '✗ Disabled'}"
            say ""

            # Show current organization
            if config.current_organization_id
              say "Current Organization:", :bold
              say "  Name:  #{config.org_name || '(unknown)'}"
              say "  ID:    #{config.current_organization_id}"
              say "  Token: #{config.display[:current_token]}"
              say ""
            end

            # Show all saved organizations
            if config.organization_ids.length > 1
              say "Saved Organizations: (#{config.organization_ids.length})", :bold
              config.organization_ids.each do |org_id|
                current_marker = org_id == config.current_organization_id ? " (current)" : ""
                org_name = config.org_name(org_id) || "Unknown"
                say "  • #{org_name}#{current_marker} (ID: #{org_id})"
              end
              say ""
            end

            # Test connection
            say "Connection:", :bold
            
            begin
              client = Client.new(api_url: config.api_url, api_token: config.api_token)
              response = client.test_connection
              
              say "  Status: ✓ Connected", :green
              
              # Get organization details
              if config.current_organization_id
                org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                org = org_response[:data]
                
                say "  Role:   #{org['role'] || 'member'}"
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
              # Fetch ALL organizations the user is a member of (not restricted by token's org)
              response = client.get('/api/v1/user/organizations')
              api_organizations = response[:data]['organizations']

              # Get all org IDs from both config and API
              all_org_ids = (config.organization_ids + api_organizations.map { |o| o['id'] }).uniq

              if all_org_ids.empty?
                say "No organizations found", :yellow
                return
              end

              all_org_ids.each do |org_id|
                has_token = config.has_token_for_org?(org_id)
                is_current = org_id == config.current_organization_id
                
                # Get org details
                org_name = config.org_name(org_id)
                api_org = api_organizations.find { |o| o['id'] == org_id }
                org_name = api_org['name'] if api_org && (org_name.nil? || org_name == 'Unknown')
                
                current_marker = is_current ? " (current)" : ""
                token_status = has_token ? "✓" : "⚠️"
                
                say "  #{token_status} #{org_name}#{current_marker}", :green
                
                if api_org
                  role = api_org['role'] || 'member'
                  say "    ID: #{org_id} | Role: #{role} | Members: #{api_org['member_count'] || 0}"
                else
                  say "    ID: #{org_id} | #{has_token ? 'Token saved' : 'Need token to access'}"
                end
                say ""
              end

              say "Total: #{all_org_ids.length} organization(s)", :white
              say ""
              say "Legend: ✓ = Has token | ⚠️  = Need token", :white
              say ""
              say "💡 Tip: Use 'mysigner switch' to change organizations", :yellow
            rescue Mysigner::ClientError => e
              error "Failed to fetch organizations: #{e.message}"
              exit 1
            end
          end

          desc "switch", "Switch to a different organization"
          long_desc <<~DESC
            Switch to a different organization.
            
            With organization-specific tokens, you'll need a token for each
            organization you want to access. This command will:
            - Show all organizations you're a member of
            - Indicate which ones you have tokens for (✓) or need tokens (⚠️)
            - Prompt for a token if switching to an org without one
            - Validate the token belongs to the target organization
            - Update your configuration
            
            Note: You need to be the same user in all organizations. Tokens
            from different user accounts will be rejected.
          DESC
          def switch
            config = load_config
            client = create_client(config)

            say "🔄 Switch Organization", :cyan
            say ""

            begin
              # Get current org details
              current_org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
              current_org = current_org_response[:data]

              say "Current organization:", :yellow
              say "  #{current_org['name']} (ID: #{config.current_organization_id})", :green
              say ""

              # Fetch ALL organizations the user is a member of (not restricted by token's org)
              response = client.get('/api/v1/user/organizations')
              api_organizations = response[:data]['organizations']
              
              # Build comprehensive list: stored orgs + API orgs
              all_org_ids = (config.organization_ids + api_organizations.map { |o| o['id'] }).uniq
              
              if all_org_ids.length < 2
                say "You only have access to one organization.", :yellow
                say "Nothing to switch to!", :yellow
                say ""
                say "💡 Tip: If you're a member of other organizations, you'll need", :cyan
                say "   to generate tokens for them first (in the web dashboard).", :cyan
                return
              end

              # Show available organizations
              say "Available organizations:", :cyan
              say ""
              organizations_list = []
              
              all_org_ids.each_with_index do |org_id, index|
                has_token = config.has_token_for_org?(org_id)
                is_current = org_id == config.current_organization_id
                
                # Get org name from config or API
                org_name = config.org_name(org_id)
                if org_name.nil? || org_name == 'Unknown'
                  # Try to fetch from API if we have a token
                  api_org = api_organizations.find { |o| o['id'] == org_id }
                  org_name = api_org['name'] if api_org
                end
                
                status = has_token ? "✓" : "⚠️ "
                current_marker = is_current ? " (current)" : ""
                
                say "  #{index + 1}. #{status} #{org_name}#{current_marker}"
                say "      ID: #{org_id} | #{has_token ? 'Token saved' : 'Need token'}", :white
                
                organizations_list << { id: org_id, name: org_name, has_token: has_token }
              end
              
              say ""
              say "Legend: ✓ = Has token | ⚠️  = Needs token", :white
              say ""

              # Let user select
              org_index = ask("Select organization (1-#{organizations_list.length}, or 'q' to cancel):")
              
              if org_index.downcase == 'q'
                say "Cancelled", :yellow
                return
              end
              
              unless org_index.match(/^\d+$/) && org_index.to_i.between?(1, organizations_list.length)
                error "Invalid selection"
                return
              end
              
              selected_org = organizations_list[org_index.to_i - 1]

              if selected_org[:id] == config.current_organization_id
                say ""
                say "Already using this organization!", :yellow
                return
              end

              # Check if we have a token for this org
              unless selected_org[:has_token]
                say ""
                say "⚠️  You don't have a token for '#{selected_org[:name]}' yet.", :yellow
                say ""
                say "To switch to this organization:", :cyan
                say "  1. Go to: #{config.api_url}/organizations/#{selected_org[:id]}/api_tokens"
                say "  2. Generate a new API token"
                say "  3. Paste it below"
                say ""
                
                new_token = ask("Paste API token for '#{selected_org[:name]}' (or 'q' to cancel):", echo: false)
                say ""
                
                if new_token.downcase == 'q' || new_token.empty?
                  say "Cancelled", :yellow
                  return
                end
                
                # Validate the new token (with email validation)
                say "Validating token...", :yellow
                
                begin
                  # Use stored email from config for validation
                  temp_client = Client.new(
                    api_url: config.api_url,
                    api_token: new_token,
                    user_email: config.user_email
                  )
                  
                  # Try to fetch the target organization with the new token
                  validation_response = temp_client.get("/api/v1/organizations/#{selected_org[:id]}")
                  token_org_data = validation_response[:data]
                  
                  # Check if token_organization_id matches (new backend feature)
                  if token_org_data['token_organization_id'] && token_org_data['token_organization_id'] != selected_org[:id]
                    error "This token belongs to a different organization!"
                    say ""
                    say "The token you provided is for organization ID #{token_org_data['token_organization_id']},", :yellow
                    say "but you're trying to access organization ID #{selected_org[:id]}.", :yellow
                    say ""
                    say "Please generate a token from the correct organization.", :yellow
                    exit 1
                  end
                  
                  say "✓ Token validated successfully", :green
                  
                  # Save the token
                  config.save_token_for_org(selected_org[:id], selected_org[:name], new_token)
                  
                rescue Mysigner::UnauthorizedError => e
                  error "Token validation failed"
                  say ""
                  
                  # Check if it's an email validation error
                  if e.message.include?("doesn't belong to") || e.message.include?("use your own token")
                    say "⚠️  This token doesn't belong to #{config.user_email}!", :yellow
                    say ""
                    say "You can only use tokens from your own account (#{config.user_email}).", :yellow
                    say "Please generate a token while logged in as #{config.user_email} on the web.", :yellow
                  else
                    say "The token you provided is not valid.", :yellow
                  end
                  exit 1
                rescue => e
                  error "Token validation failed: #{e.message}"
                  exit 1
                end
              end

              # Update config to switch to the new org
              config.current_organization_id = selected_org[:id]
              config.save

              say ""
              say "✓ Successfully switched to: #{selected_org[:name]}", :green
              say ""
              say "💡 Run 'mysigner status' to verify your new configuration", :cyan
              
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
        end
      end
    end
  end
end
