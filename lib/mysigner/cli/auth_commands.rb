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
            
            New user? Run 'mysigner setup' for step-by-step guidance.
            
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
            say "=" * 80, :cyan
            say ""

            # Get API URL with smart default
            api_url = prompt_api_url
            say ""
            
            # Show guidance for getting token
            show_token_guidance(api_url)
            
            api_token = ask("API Token:", echo: false)
            say "" # New line after hidden input
            
            if api_token.empty?
              error "API token cannot be empty"
              say ""
              say "💡 Tip: Run 'mysigner setup' for detailed guidance", :yellow
              exit 1
            end

            say "Testing connection...", :yellow
            
            begin
              client = Client.new(api_url: api_url, api_token: api_token)
              response = client.test_connection
              
              if response[:success]
                say "✓ Connection successful", :green
                say ""
              else
                error "Connection failed"
                handle_connection_failure(api_url)
                exit 1
              end
              
              # Fetch organizations (to get the token's organization)
              response = client.get('/api/v1/organizations')
              organizations = response[:data]['organizations']
              
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

              # Token is org-specific, so we know which org
              selected_org = organizations.first
              
              # Save configuration
              config = Config.new
              config.api_url = api_url
              config.api_token = api_token
              config.organization_id = selected_org['id']
              config.save

              say ""
              say "=" * 80, :green
              say "✓ Successfully logged in!", :green
              say "=" * 80, :green
              say ""
              say "Organization: #{selected_org['name']}", :cyan
              say "Config saved to: #{Config::CONFIG_FILE}", :cyan
              say ""
              say "🚀 Next steps:", :bold
              say "  cd your-ios-project"
              say "  mysigner ship testflight"
              say ""
              say "💡 Run 'mysigner doctor' to check your environment", :yellow
              say ""
              
            rescue Mysigner::UnauthorizedError
              handle_unauthorized_error(api_url)
              exit 1
            rescue Mysigner::ConnectionError => e
              handle_connection_error(e, api_url)
              exit 1
            rescue => e
              handle_unexpected_error(e, api_url)
              exit 1
            end
          end

          desc "setup", "Interactive setup guide for first-time users"
          long_desc <<~DESC
            Step-by-step guide to get started with My Signer CLI.
            
            This command will:
            1. Check if you have an account
            2. Guide you through creating an organization
            3. Help you generate an API token
            4. Configure your CLI
          DESC
          def setup
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
                say "Come back and run 'mysigner setup' when you're ready!", :yellow
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
                say "Come back and run 'mysigner setup' when you're ready!", :yellow
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
              say "Come back and run 'mysigner setup' when you have your token!", :yellow
              return
            end
            say ""

            # Step 4: Login
            say "Step 4: Login to CLI", :cyan
            say "-" * 80
            say ""
            say "Great! Now let's log you in.", :bold
            say ""
            
            api_token = ask("Paste your API Token:", echo: false)
            say ""
            
            if api_token.empty?
              error "Token cannot be empty"
              say "Run 'mysigner setup' again when you have your token", :yellow
              return
            end

            say "Testing your token...", :yellow
            
            begin
              client = Client.new(api_url: api_url, api_token: api_token)
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
              
              config = Config.new
              config.api_url = api_url
              config.api_token = api_token
              config.organization_id = selected_org['id']
              config.save

              say ""
              say "=" * 80, :green
              say "🎉 Setup Complete!", :green
              say "=" * 80, :green
              say ""
              say "You're all set up and ready to go!", :bold
              say ""
              say "Organization: #{selected_org['name']}", :cyan
              say "Config saved to: #{Config::CONFIG_FILE}", :cyan
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
              
            rescue Mysigner::UnauthorizedError
              error "Invalid token"
              say ""
              say "The token you entered is invalid. Please:", :yellow
              say "  1. Check you copied the entire token"
              say "  2. Make sure the token hasn't been revoked"
              say "  3. Generate a new token if needed"
              say ""
              say "Run 'mysigner setup' to try again", :yellow
            rescue => e
              error "Setup failed: #{e.message}"
              say ""
              say "Run 'mysigner setup' to try again", :yellow
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
        end
      end
    end
  end
end
