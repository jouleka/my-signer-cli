# frozen_string_literal: true

module Mysigner
  class CLI < Thor
    module AuthCommands
      SETTABLE_CONFIG_KEYS = %w[local-only].freeze

      def self.included(base)
        base.class_eval do
          desc 'version', 'Show version information'
          def version
            say "My Signer CLI v#{Mysigner::VERSION}", :cyan
            say ''
            say "Ruby:        #{RUBY_VERSION} (#{RUBY_PLATFORM})", :white
            say "Install:     #{File.expand_path('../../..', __dir__)}", :white
            say "Config:      #{Config::CONFIG_FILE}", :white
            say ''
            say 'Repository:  https://github.com/mysigner-dev/mysigner-cli', :white
            say 'Issues:      https://github.com/mysigner-dev/mysigner-cli/issues', :white
            say ''
            say 'Docs:        https://mysigner.dev/docs/commands', :white
            say 'Support:     https://mysigner.dev/landing#contact', :white
          end

          desc 'login', "Log in with existing API token (⭐ first-timers: use 'onboard' instead)"
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
              say '⚠️  Already logged in', :yellow
              say ''
              say 'Current configuration:', :yellow
              say "  User: #{config.user_email || '(unknown)'}"
              say "  Organization: #{config.org_name || '(unknown)'} (ID: #{config.current_organization_id})"
              say "  API URL: #{config.api_url}"
              say ''

              if yes?('Do you want to logout and login with different user? (y/n)')
                config.clear
                say '✓ Logged out successfully', :green
                say ''
              else
                say "Login cancelled. Use 'mysigner logout' to logout first.", :yellow
                say ''
                say "💡 Tip: Use 'mysigner switch' to switch organizations for the same user", :yellow
                return
              end
            end

            say '🔐 My Signer Login', :cyan
            say '=' * 80, :cyan
            say ''

            # Get API URL with smart default
            api_url = prompt_api_url
            say ''

            # Get user email
            user_email = prompt_for_email
            say ''

            # Show guidance for getting token
            show_token_guidance(api_url)

            api_token = ask('API Token:', echo: false)
            say '' # New line after hidden input

            if api_token.empty?
              error 'API token cannot be empty'
              say ''
              say "💡 Tip: Run 'mysigner onboard' for detailed guidance", :yellow
              exit 1
            end

            say 'Validating token and email...', :yellow

            begin
              client = Client.new(api_url: api_url, api_token: api_token, user_email: user_email)
              response = client.test_connection

              if response[:success]
                say '✓ Token valid', :green
              else
                error 'Connection failed'
                handle_connection_failure(api_url)
                exit 1
              end

              # Fetch organization info (token can only access its own org)
              say 'Detecting organization...', :yellow

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
                error 'No organizations found for this token'
                say ''
                say 'This might mean:', :yellow
                say "  • Your token doesn't have access to any organizations", :yellow
                say '  • The token was created but the organization was deleted', :yellow
                say ''
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

              say 'DEBUG: Organization data received', :cyan if ENV['DEBUG']

              say "✓ Organization detected: #{org_data['name']}", :green
              say "✓ Email validated: #{user_email}", :green
              say ''

              # Save configuration with multi-token support
              config = Config.new
              config.api_url = api_url
              config.user_email = user_email # Save the verified email
              config.current_organization_id = org_id
              config.save_token_for_org(org_id, org_data['name'], api_token)
              config.save

              say ''
              say '=' * 80, :green
              say '✓ Successfully logged in!', :green
              say '=' * 80, :green
              say ''
              say "Organization: #{org_data['name']} (ID: #{org_id})", :cyan
              say "Role: #{org_data['role'] || 'viewer'}", :cyan
              say "Config saved to: #{Config::CONFIG_FILE}", :cyan
              say ''
              say '🔒 Security Note:', :yellow
              say '  Your token is organization-specific and can only access', :yellow
              say "  #{org_data['name']}. To access other organizations,", :yellow
              say "  use 'mysigner switch' to add tokens for those organizations.", :yellow
              say ''
              say '🚀 Next steps:', :bold
              say '  cd your-ios-project'
              say '  mysigner ship testflight'
              say ''
              say '💡 Helpful commands:', :cyan
              say '  • mysigner doctor     - Check your environment'
              say '  • mysigner orgs       - List all organizations'
              say '  • mysigner switch     - Switch to another organization'
              say ''
            rescue Mysigner::UnauthorizedError => e
              error 'Authentication failed'
              say ''

              # Check if it's an email validation error
              if e.message.include?("doesn't belong to") || e.message.include?('use your own token')
                say '⚠️  Token Email Mismatch', :yellow
                say ''
                say "The token you provided doesn't belong to #{user_email}.", :yellow
                say ''
                say 'This could mean:', :yellow
                say "  • You're using a token created by someone else", :yellow
                say "  • You're using a token from a different account", :yellow
                say ''
                say '💡 Solutions:', :cyan
                say '  1. Generate a new token from your own account at:', :cyan
                say "     #{api_url}", :cyan
                say "  2. Make sure you're logged in as #{user_email} on the web", :cyan
                say '  3. Check that you entered the correct email address', :cyan
              else
                handle_unauthorized_error(api_url)
              end
              exit 1
            rescue Mysigner::ConnectionError => e
              handle_connection_error(e, api_url)
              exit 1
            rescue StandardError => e
              handle_unexpected_error(e, api_url)
              exit 1
            end
          end

          desc 'onboard', '⭐ START HERE - Complete setup wizard for new users'
          long_desc <<~DESC
            Step-by-step guide to get started with My Signer CLI.

            This command will:
            1. Check if you have an account
            2. Guide you through creating an organization
            3. Help you generate an API token
            4. Configure your CLI
          DESC
          def onboard
            # mysigner-44 — local-only mode short-circuits the server-mediated
            # onboarding entirely. We never POST credentials and never ask the
            # user for an API token; everything is captured into the local
            # Keychain-backed store. The server-mediated path below is left
            # untouched for backward compatibility.
            if local_only?
              emit_local_only_banner
              return onboard_local_only
            end

            say '🚀 My Signer Setup Guide', :cyan
            say '=' * 80, :cyan
            say ''
            say "Welcome! Let's get you set up with My Signer.", :bold
            say ''

            # Check if already configured
            config = Config.new
            if config.exists? && config.api_token && config.current_organization_id
              say "✓ You're already logged in!", :green
              say ''
              say 'Current configuration:', :cyan
              say "  Email: #{config.user_email}"
              say "  Organization ID: #{config.current_organization_id}"
              say "  API URL: #{config.api_url}"
              say ''

              # Check App Store Connect status
              begin
                client = Client.new(api_url: config.api_url, api_token: config.api_token, user_email: config.user_email)
                org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                org_data = org_response[:data]

                asc_configured = org_data['app_store_connect_configured'] || false

                if asc_configured
                  # Already fully configured
                  say '✓ App Store Connect: Configured', :green
                  say "  Team ID: #{org_data['app_store_connect_team_id']}" if org_data['app_store_connect_team_id']
                  say ''
                  say "You're all set! 🎉", :bold
                  say ''
                  say 'What would you like to do?', :bold
                  say '  1. Check status'
                  say '  2. Switch to another organization'
                  say '  3. Log out and start fresh'
                  say '  4. Exit'
                  say ''

                  choice = ask('Select (1-4):', limited_to: %w[1 2 3 4])
                  say ''

                  case choice
                  when '1'
                    invoke :status
                    return
                  when '2'
                    invoke :switch
                    return
                  when '3'
                    say 'Clearing configuration...', :yellow
                    say ''
                    # Continue with full onboarding
                  when '4'
                    say 'No changes made.', :green
                    return
                  end
                else
                  # Missing ASC credentials - offer to add them
                  say '⚠️  App Store Connect: Not configured', :yellow
                  say ''
                  say 'What would you like to do?', :bold
                  say '  1. Set up App Store Connect credentials now'
                  say "  2. Check status with 'mysigner status'"
                  say '  3. Log out and start fresh'
                  say '  4. Exit'
                  say ''

                  choice = ask('Select (1-4):', limited_to: %w[1 2 3 4])
                  say ''

                  case choice
                  when '1'
                    # Go directly to ASC setup
                    say '🚀 Setting up App Store Connect credentials...', :cyan
                    say ''
                    asc_configured = setup_app_store_connect_credentials(client, config, config.current_organization_id)

                    say ''
                    say '=' * 80, :green
                    if asc_configured
                      say '✓ App Store Connect configured successfully!', :green
                    else
                      say '⚠️  Setup incomplete', :yellow
                      say "Run 'mysigner onboard' again or use 'mysigner doctor'", :yellow
                    end
                    say '=' * 80, :green
                    return
                  when '2'
                    invoke :status
                    return
                  when '3'
                    say 'Clearing configuration...', :yellow
                    say ''
                    # Continue with full onboarding
                  when '4'
                    say 'No changes made.', :green
                    return
                  end
                end
              rescue StandardError => e
                say "⚠️  Could not check organization status: #{e.message}", :yellow
                say ''

                unless yes_with_default?('Do you want to re-configure from scratch?', :yellow)
                  say ''
                  say 'Keeping existing configuration.', :green
                  say ''
                  say "💡 Tip: Use 'mysigner status' to check your setup", :cyan
                  say "💡 Tip: Use 'mysigner switch' to add another organization", :cyan
                  return
                end

                say ''
                say 'Clearing existing configuration...', :yellow
                say ''
              end
            end

            # Get API URL
            api_url = prompt_api_url
            say ''

            # Step 1: Check if user has account
            say 'Step 1: Account Setup', :cyan
            say '-' * 80
            say ''
            say 'Do you have a My Signer account?', :bold
            say '  1. Yes, I have an account'
            say '  2. No, I need to sign up'
            say ''

            choice = ask('Select (1-2):', limited_to: %w[1 2])
            say ''

            if choice == '2'
              # Guide to signup
              say "📝 Let's create your account:", :cyan
              say ''
              say '1. Open your browser and go to:', :bold
              say "   #{api_url}", :green
              say ''
              say "2. Click 'Sign Up' and create your account", :bold
              say ''
              say '3. Verify your email (check your inbox)', :bold
              say ''

              unless yes_with_default?('Have you created your account?', :green)
                say ''
                say "Come back and run 'mysigner onboard' when you're ready!", :yellow
                return
              end
              say ''
            end

            # Step 2: Organization
            say 'Step 2: Organization Setup', :cyan
            say '-' * 80
            say ''
            say 'Do you have an organization?', :bold
            say '  1. Yes, I have an organization'
            say '  2. No, I need to create one'
            say ''

            choice = ask('Select (1-2):', limited_to: %w[1 2])
            say ''

            if choice == '2'
              # Guide to create org
              say "🏢 Let's create your organization:", :cyan
              say ''
              say '1. Go to the dashboard:', :bold
              say "   #{api_url}", :green
              say ''
              say '2. Sign in with your account', :bold
              say ''
              say "3. Click 'Create Organization'", :bold
              say ''
              say "4. Enter your organization name (e.g., 'My Startup')", :bold
              say ''

              unless yes_with_default?('Have you created your organization?', :green)
                say ''
                say "Come back and run 'mysigner onboard' when you're ready!", :yellow
                return
              end
              say ''
            end

            # Step 3: API Token
            say 'Step 3: Generate API Token', :cyan
            say '-' * 80
            say ''
            say "Now let's generate your API token:", :bold
            say ''
            say '1. Go to API Tokens:', :bold
            say "   #{api_url}/organizations/YOUR_ORG_ID/api_tokens", :green
            say ''
            say '   Or navigate: Dashboard → Your Organization → API Tokens', :cyan
            say ''
            say "2. Click 'Create Token'", :bold
            say ''
            say '3. Fill in the details:', :bold
            say "   • Name: 'CLI Access' (or anything you like)"
            say '   • Scopes: ✓ read  ✓ write  (minimum required)'
            say "   • Expiration: Choose 'Never' or '1 year'"
            say ''
            say "4. Click 'Create' and COPY the token", :bold
            say "   ⚠️  You'll only see it once!", :yellow
            say ''

            unless yes_with_default?('Have you generated and copied your token?', :green)
              say ''
              say "Come back and run 'mysigner onboard' when you have your token!", :yellow
              return
            end
            say ''

            # Step 4: Login
            say 'Step 4: Login to CLI', :cyan
            say '-' * 80
            say ''
            say "Great! Now let's log you in.", :bold
            say ''

            # Get user email
            user_email = prompt_for_email
            say ''

            api_token = ask('Paste your API Token:', echo: false)
            say ''

            if api_token.empty?
              error 'Token cannot be empty'
              say "Run 'mysigner onboard' again when you have your token", :yellow
              return
            end

            say 'Validating token and email...', :yellow

            begin
              client = Client.new(api_url: api_url, api_token: api_token, user_email: user_email)
              response = client.test_connection

              unless response[:success]
                error 'Connection test failed'
                return
              end

              response = client.get('/api/v1/organizations')
              organizations = response[:data]['organizations']

              if organizations.empty?
                error 'No organizations found'
                say 'Please check that your token is associated with an organization', :yellow
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

              # Step 5: App Store Connect Setup (Optional)
              say ''
              say 'Step 5: App Store Connect Setup (optional but recommended)', :cyan
              say '-' * 80
              say ''

              # Check if already configured
              asc_configured = org_data['app_store_connect_configured'] || false

              if asc_configured
                say '✓ App Store Connect is already configured!', :green
                say ''
                say 'Current setup:', :cyan
                say "  • Team ID: #{org_data['app_store_connect_team_id']}" if org_data['app_store_connect_team_id']
                say '  • Status: Active'
                say ''
                say 'You can manage credentials in the web dashboard:', :cyan
                say "  #{api_url}/organizations/#{org_id}", :green
                say ''
                say '💡 Tip: You can add multiple credentials (for different teams)', :cyan
                say ''
              else
                say 'To upload to TestFlight/App Store, we need your API credentials.', :bold
                say ''
                say 'Do you want to set this up now?', :bold
                say '  1. Yes, guide me through it (recommended)'
                say '  2. Skip for now (you can do this later)'
                say ''

                asc_choice = ask('Select (1-2):', limited_to: %w[1 2])
                say ''

                if asc_choice == '1'
                  asc_configured = setup_app_store_connect_credentials(client, config, org_id)
                else
                  say '⏭️  Skipped App Store Connect setup', :yellow
                  say ''
                  say 'You can set this up later by:', :cyan
                  say '  • Running: mysigner doctor'
                  say '  • Or via the web dashboard'
                  say ''
                end
              end

              say ''
              say '=' * 80, :green
              say '🎉 Setup Complete!', :green
              say '=' * 80, :green
              say ''
              say "You're all set up and ready to go!", :bold
              say ''
              say "User: #{user_email}", :cyan
              say "Organization: #{org_data['name']} (ID: #{org_id})", :cyan
              say "Config saved to: #{Config::CONFIG_FILE}", :cyan

              # Show App Store Connect status
              say ''
              if asc_configured
                say '✓ App Store Connect: Configured', :green
              elsif defined?(asc_choice) && asc_choice == '1'
                say '⚠️  App Store Connect:', :yellow
                say '  Setup was attempted but not completed', :yellow
                say "  Run 'mysigner doctor' to configure it", :yellow
              else
                say '⚠️  App Store Connect: Not configured', :yellow
                say "  Run 'mysigner doctor' to set it up", :yellow
              end

              say ''
              say '🔒 Security Note:', :yellow
              say "  Your token is organization-specific. Use 'mysigner switch'", :yellow
              say '  to add tokens for other organizations.', :yellow
              say ''
              say '🚀 Try your first ship:', :bold
              say ''
              say '  cd your-ios-project'
              say '  mysigner ship testflight'
              say ''
              say '💡 Tips:', :cyan
              say "  • Run 'mysigner doctor' to check your environment"
              say "  • Run 'mysigner --help' to see all commands"
              say "  • Run 'mysigner status' to verify your setup"
              say ''
            rescue Mysigner::UnauthorizedError => e
              error 'Authentication failed'
              say ''

              # Check if it's an email validation error
              if e.message.include?("doesn't belong to") || e.message.include?('use your own token')
                say '⚠️  Token Email Mismatch', :yellow
                say ''
                say "The token you provided doesn't belong to #{user_email}.", :yellow
                say ''
                say 'Please make sure you:', :yellow
                say "  1. Are logged in as #{user_email} on the web dashboard", :yellow
                say "  2. Generate the token while logged in as #{user_email}", :yellow
                say '  3. Enter the correct email address', :yellow
              else
                say 'The token you entered is invalid. Please:', :yellow
                say '  1. Check you copied the entire token'
                say "  2. Make sure the token hasn't been revoked"
                say '  3. Generate a new token if needed'
              end
              say ''
              say "Run 'mysigner onboard' to try again", :yellow
            rescue StandardError => e
              error "Setup failed: #{e.message}"
              say ''
              say "Run 'mysigner onboard' to try again", :yellow
            end
          end

          desc 'logout', 'Log out and clear stored credentials'
          long_desc <<~DESC
            Log out of MySigner. Always clears local CLI config.

            By default, ALSO asks whether to delete your stored credentials
            (App Store Connect .p8 keys, Apple Search Ads keys, Google Play
            service-account JSON, Android keystores) on the server and in
            your local Keychain. The prompt defaults to No — the safer
            choice — because logging out and back in restores access to
            them otherwise.

              --purge      Skip the prompt and DELETE the credentials.
              --no-purge   Skip the prompt and KEEP them on the server.

            In non-interactive contexts (CI, pipes), the prompt defaults
            to No as well, matching `yes_with_default?` elsewhere.

            See docs/policy/credential-retention.md (server repo) for the
            authoritative retention policy.
          DESC
          method_option :purge, type: :boolean, default: nil,
                                desc: 'Also delete stored credentials on the server and in local Keychain (skips prompt)'
          def logout
            config = Config.new

            unless config.exists?
              say 'No stored credentials found', :yellow
              return
            end

            # Preserve the existing "Are you sure?" gate. Tests pin this exact
            # prompt and a No answer must abort the entire logout. With
            # --purge / --no-purge a user has already declared intent, but
            # we still require the top-level confirmation when interactive —
            # less surprising than two layered changes in one release.
            unless yes?('Are you sure you want to logout? (y/n)')
              say 'Logout cancelled', :yellow
              return
            end

            # Now we know the local logout is happening. Decide whether to
            # ALSO purge server + local-Keychain credentials. Resolution
            # order: explicit flag > interactive prompt > non-TTY default No.
            should_purge = resolve_purge_decision(options[:purge])

            if should_purge
              # Load the config so we have the api_url/token/email needed
              # for the server call. Failure here is loud — we don't fall
              # back to "local-only clear" silently, that would leave the
              # user's server credentials on disk against their explicit
              # request.
              begin
                config.load
                purge_server_credentials(config)
                purge_local_credentials
              rescue Mysigner::ClientError, Mysigner::ConfigError => e
                error "Failed to purge credentials on the server: #{e.message}"
                say ''
                say 'Local config was NOT cleared so you can retry. Options:', :yellow
                say "  • Re-run 'mysigner logout --purge' once the server is reachable", :yellow
                say "  • Run 'mysigner logout --no-purge' to log out locally only", :yellow
                exit 1
              end
            end

            config.clear
            say '✓ Successfully logged out', :green
            say "Config file removed: #{Config::CONFIG_FILE}", :green
          end

          desc 'status', 'Check connection, credentials, and App Store Connect setup'
          def status
            config = load_config

            say '📊 My Signer Status', :cyan
            say ''
            say 'Configuration:', :bold
            say "  API URL:         #{config.api_url}"
            say "  User:            #{config.user_email || '(unknown)'}"
            say "  Encryption:      #{config.encrypted_config? ? '✓ Enabled' : '✗ Disabled'}"
            say ''

            # Show current organization
            if config.current_organization_id
              say 'Current Organization:', :bold
              say "  Name:  #{config.org_name || '(unknown)'}"
              say "  ID:    #{config.current_organization_id}"
              say "  Token: #{config.display[:current_token]}"
              say ''
            end

            # Show all saved organizations
            if config.organization_ids.length > 1
              say "Saved Organizations: (#{config.organization_ids.length})", :bold
              config.organization_ids.each do |org_id|
                current_marker = org_id == config.current_organization_id ? ' (current)' : ''
                org_name = config.org_name(org_id) || 'Unknown'
                say "  • #{org_name}#{current_marker} (ID: #{org_id})"
              end
              say ''
            end

            # Test connection
            say 'Connection:', :bold

            begin
              client = Client.new(api_url: config.api_url, api_token: config.api_token)
              client.test_connection

              say '  Status: ✓ Connected', :green

              # Get organization details
              if config.current_organization_id
                org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
                org = org_response[:data]

                say "  Role:   #{org['role'] || 'viewer'}"
                say "  Members: #{org['member_count'] || 0}"
                say ''

                # Show App Store Connect status
                say 'App Store Connect:', :bold
                if org['app_store_connect_configured']
                  say '  ✓ Configured', :green
                  say "  Team ID: #{org['app_store_connect_team_id']}" if org['app_store_connect_team_id']
                else
                  say '  ✗ Not configured', :yellow
                  say "  Run 'mysigner doctor' to set it up"
                end
              end
            rescue Mysigner::UnauthorizedError
              say '  Status: ✗ Unauthorized (invalid token)', :red
              exit 1
            rescue Mysigner::ConnectionError => e
              say '  Status: ✗ Connection failed', :red
              say "  Error: #{e.message}", :red
              exit 1
            rescue StandardError => e
              say '  Status: ✗ Error', :red
              say "  Error: #{e.message}", :red
              exit 1
            end
          end

          desc 'orgs', "List all organizations you're a member of"
          def orgs
            config = load_config
            client = create_client(config)

            say '📋 Organizations', :cyan
            say ''

            begin
              # Fetch ALL organizations the user is a member of (not restricted by token's org)
              response = client.get('/api/v1/user/organizations')
              api_organizations = response[:data]['organizations']

              # Get all org IDs from both config and API
              all_org_ids = (config.organization_ids + api_organizations.map { |o| o['id'] }).uniq

              if all_org_ids.empty?
                say 'No organizations found', :yellow
                return
              end

              all_org_ids.each do |org_id|
                has_token = config.has_token_for_org?(org_id)
                is_current = org_id == config.current_organization_id

                # Get org details
                org_name = config.org_name(org_id)
                api_org = api_organizations.find { |o| o['id'] == org_id }
                org_name = api_org['name'] if api_org && (org_name.nil? || org_name == 'Unknown')

                current_marker = is_current ? ' (current)' : ''
                token_status = has_token ? '✓' : '⚠️'

                say "  #{token_status} #{org_name}#{current_marker}", :green

                if api_org
                  role = api_org['role'] || 'viewer'
                  say "    ID: #{org_id} | Role: #{role} | Members: #{api_org['member_count'] || 0}"
                else
                  say "    ID: #{org_id} | #{has_token ? 'Token saved' : 'Need token to access'}"
                end
                say ''
              end

              say "Total: #{all_org_ids.length} organization(s)", :white
              say ''
              say 'Legend: ✓ = Has token | ⚠️  = Need token', :white
              say ''
              say "💡 Tip: Use 'mysigner switch' to change organizations", :yellow
            rescue Mysigner::ClientError => e
              error "Failed to fetch organizations: #{e.message}"
              exit 1
            end
          end

          desc 'switch [ORG_ID]', 'Switch between organizations (for multi-org users)'
          long_desc <<~DESC
            Switch to a different organization.

            Interactive (no argument): prompts you with a numbered list.
            Non-interactive: pass an organization ID directly, e.g.
                mysigner switch 7

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
          def switch(target_org_id = nil)
            config = load_config
            client = create_client(config)

            say '🔄 Switch Organization', :cyan
            say ''

            begin
              # Get current org details
              current_org_response = client.get("/api/v1/organizations/#{config.current_organization_id}")
              current_org = current_org_response[:data]

              say 'Current organization:', :yellow
              say "  #{current_org['name']} (ID: #{config.current_organization_id})", :green
              say ''

              # Fetch ALL organizations the user is a member of (not restricted by token's org)
              response = client.get('/api/v1/user/organizations')
              api_organizations = response[:data]['organizations']

              # Build comprehensive list: stored orgs + API orgs
              all_org_ids = (config.organization_ids + api_organizations.map { |o| o['id'] }).uniq

              if all_org_ids.length < 2
                say 'You only have access to one organization.', :yellow
                say 'Nothing to switch to!', :yellow
                say ''
                say "💡 Tip: If you're a member of other organizations, you'll need", :cyan
                say '   to generate tokens for them first (in the web dashboard).', :cyan
                return
              end

              # Show available organizations
              say 'Available organizations:', :cyan
              say ''
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

                status = has_token ? '✓' : '⚠️ '
                current_marker = is_current ? ' (current)' : ''

                say "  #{index + 1}. #{status} #{org_name}#{current_marker}"
                say "      ID: #{org_id} | #{has_token ? 'Token saved' : 'Need token'}", :white

                organizations_list << { id: org_id, name: org_name, has_token: has_token }
              end

              say ''
              say 'Legend: ✓ = Has token | ⚠️  = Needs token', :white
              say ''

              # Non-interactive selection via positional arg (`mysigner switch 7`)
              selected_org = if target_org_id
                               match = organizations_list.find { |o| o[:id].to_s == target_org_id.to_s }
                               unless match
                                 error "Organization #{target_org_id} not found among your memberships"
                                 say ''
                                 say "  Available IDs: #{organizations_list.map { |o| o[:id] }.join(', ')}", :yellow
                                 exit 1
                               end
                               match
                             else
                               org_index = ask("Select organization (1-#{organizations_list.length}, or 'q' to cancel):")

                               if org_index.downcase == 'q'
                                 say 'Cancelled', :yellow
                                 return
                               end

                               unless org_index.match(/^\d+$/) && org_index.to_i.between?(1, organizations_list.length)
                                 error 'Invalid selection'
                                 return
                               end

                               organizations_list[org_index.to_i - 1]
                             end

              if selected_org[:id] == config.current_organization_id
                say ''
                say 'Already using this organization!', :yellow
                return
              end

              # Check if we have a token for this org
              unless selected_org[:has_token]
                say ''
                say "⚠️  You don't have a token for '#{selected_org[:name]}' yet.", :yellow
                say ''
                say 'To switch to this organization:', :cyan
                say "  1. Go to: #{config.api_url}/organizations/#{selected_org[:id]}/api_tokens"
                say '  2. Generate a new API token'
                say '  3. Paste it below'
                say ''

                new_token = ask("Paste API token for '#{selected_org[:name]}' (or 'q' to cancel):", echo: false)
                say ''

                if new_token.downcase == 'q' || new_token.empty?
                  say 'Cancelled', :yellow
                  return
                end

                # Validate the new token (with email validation)
                say 'Validating token...', :yellow

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
                    error 'This token belongs to a different organization!'
                    say ''
                    say "The token you provided is for organization ID #{token_org_data['token_organization_id']},",
                        :yellow
                    say "but you're trying to access organization ID #{selected_org[:id]}.", :yellow
                    say ''
                    say 'Please generate a token from the correct organization.', :yellow
                    exit 1
                  end

                  say '✓ Token validated successfully', :green

                  # Save the token
                  config.save_token_for_org(selected_org[:id], selected_org[:name], new_token)
                rescue Mysigner::UnauthorizedError => e
                  error 'Token validation failed'
                  say ''

                  # Check if it's an email validation error
                  if e.message.include?("doesn't belong to") || e.message.include?('use your own token')
                    say "⚠️  This token doesn't belong to #{config.user_email}!", :yellow
                    say ''
                    say "You can only use tokens from your own account (#{config.user_email}).", :yellow
                    say "Please generate a token while logged in as #{config.user_email} on the web.", :yellow
                  else
                    say 'The token you provided is not valid.', :yellow
                  end
                  exit 1
                rescue StandardError => e
                  error "Token validation failed: #{e.message}"
                  exit 1
                end
              end

              # Update config to switch to the new org
              config.current_organization_id = selected_org[:id]
              config.save

              say ''
              say "✓ Successfully switched to: #{selected_org[:name]}", :green
              say ''
              say "💡 Run 'mysigner status' to verify your new configuration", :cyan
            rescue Mysigner::ClientError => e
              error "Failed to switch organization: #{e.message}"
              exit 1
            end
          end

          desc 'config [ACTION] [KEY] [VALUE]',
               'Show or set CLI configuration (e.g. `mysigner config set local-only true`)'
          long_desc <<~DESC
            Without arguments: prints the current configuration.

            Set a value:
              mysigner config set local-only true
              mysigner config set local-only false

            Settable keys: local-only

            `set` does NOT require a MySigner login — it is the bootstrap path
            for users who want to use local-only mode from a fresh machine.
          DESC
          def config(action = nil, key = nil, value = nil)
            return config_set(key, value) if action == 'set'

            if action && action != 'set'
              error "Unknown config action: #{action}"
              say 'Did you mean: `mysigner config set <key> <value>`?', :yellow
              exit 1
            end

            cfg = Config.new

            unless cfg.exists?
              error "No configuration found. Run 'mysigner login' first."
              exit 1
            end

            cfg.load

            say '⚙️  Configuration', :cyan
            say ''
            cfg.display.each do |key, val|
              say "  #{key.to_s.ljust(20)}: #{val}"
            end
            say "  #{'local-only'.ljust(20)}: #{cfg.local_only}"
            say ''
            say "Config file: #{Config::CONFIG_FILE}"
          end

          no_commands do
            def config_set(key, value)
              if key.nil? || value.nil?
                error 'Usage: mysigner config set <key> <value>'
                say "Settable keys: #{SETTABLE_CONFIG_KEYS.join(', ')}", :yellow
                exit 1
              end

              unless SETTABLE_CONFIG_KEYS.include?(key)
                error "Unknown config key: #{key}"
                say "Settable keys: #{SETTABLE_CONFIG_KEYS.join(', ')}", :yellow
                exit 1
              end

              case key
              when 'local-only'
                bool = parse_bool_or_exit(value, key)
                cfg = Config.new
                cfg.load if cfg.exists?
                cfg.local_only = bool
                cfg.save
                say "✓ Saved #{key}: #{bool}", :green
                say "  #{key}: #{bool}"
              end
            end

            def parse_bool_or_exit(value, key)
              case value.to_s.downcase
              when 'true', '1', 'yes', 'on'  then true
              when 'false', '0', 'no', 'off' then false
              else
                error "Invalid boolean for #{key}: #{value}"
                say 'Use: true / false (also accepts 1/0, yes/no, on/off)', :yellow
                exit 1
              end
            end

            # Helper method for yes/no prompts with Enter defaulting to yes.
            # Defaults to NO when stdin is not a TTY so automation (CI, pipes)
            # never silently opts-in to mutating operations.
            def yes_with_default?(statement, color = nil)
              unless $stdin.tty?
                say "#{statement} [Y/n] (non-interactive: assuming no)", color
                return false
              end
              response = ask("#{statement} [Y/n]", color).to_s.strip.downcase
              response.empty? || response == 'y' || response == 'yes'
            end

            # Default-NO variant of yes_with_default? — used when the
            # destructive answer must be opt-in (mysigner-47 logout purge).
            # Non-TTY also defaults to No so CI never silently wipes server
            # credentials. Only an explicit "y" or "yes" returns true.
            def no_default_yes?(statement, color = nil)
              unless $stdin.tty?
                say "#{statement} [y/N] (non-interactive: assuming no)", color
                return false
              end
              response = ask("#{statement} [y/N]", color).to_s.strip.downcase
              %w[y yes].include?(response)
            end

            # mysigner-47 — resolve the purge decision for `mysigner logout`.
            # `flag` is options[:purge] (true / false / nil).
            #   true  → --purge passed; skip prompt, purge
            #   false → --no-purge passed; skip prompt, keep
            #   nil   → no flag; ask the user (default No), CI defaults to No
            def resolve_purge_decision(flag)
              return flag unless flag.nil?

              no_default_yes?(
                'Also delete your stored credentials on the server? ' \
                'They will be gone forever.',
                :yellow
              )
            end

            # mysigner-47 — call DELETE /api/v1/organizations/:org/credentials
            # using the loaded config. Surfaces per-kind counts on success.
            # Raises Mysigner::ClientError on transport/auth failure so the
            # caller can decide whether to abort the local clear.
            def purge_server_credentials(config)
              org_id = config.current_organization_id
              if org_id.nil?
                say '⚠️  No active organization in local config; skipping server purge.', :yellow
                return
              end

              client = Client.new(
                api_url: config.api_url,
                api_token: config.api_token,
                user_email: config.user_email
              )

              say 'Deleting stored credentials on the server...', :yellow
              response = client.delete("/api/v1/organizations/#{org_id}/credentials")

              deleted = response.dig(:data, 'deleted') || {}
              asc   = deleted['asc'].to_i
              ads   = deleted['apple_ads'].to_i
              gp    = deleted['google_play'].to_i
              ks    = deleted['android_keystore'].to_i

              say '✓ Server credentials deleted:', :green
              say "  • App Store Connect: #{asc}"
              say "  • Apple Search Ads:  #{ads}"
              say "  • Google Play:       #{gp}"
              say "  • Android keystore:  #{ks}"
            end

            # mysigner-47 — wipe every locally stored credential the
            # LocalCredentials store knows about, across all four kinds.
            # We swallow per-entry deletion errors with a loud log line
            # rather than aborting (Rule 12 — fail loud, but a corrupted
            # Keychain entry must not block the rest of the wipe).
            def purge_local_credentials
              return unless defined?(Mysigner::LocalCredentials)

              total = 0
              Mysigner::LocalCredentials::KINDS.each do |kind|
                ids = Mysigner::LocalCredentials.list(kind: kind)
                ids.each do |id|
                  Mysigner::LocalCredentials.delete(kind: kind, id: id)
                  total += 1
                rescue Mysigner::LocalCredentials::LocalCredentialsError => e
                  say "⚠️  Failed to delete local credential #{kind}/#{id}: #{e.message}", :yellow
                end
              end

              if total.positive?
                say "✓ Local Keychain / file credentials deleted: #{total}", :green
              else
                say 'No local-only credentials to delete.', :white
              end
            end

            # Helper method for App Store Connect credential setup
            # Returns true if successfully configured, false otherwise
            def setup_app_store_connect_credentials(client, _config, org_id)
              say '📱 App Store Connect API Key Setup', :cyan
              say ''
              say "Let's set up your App Store Connect credentials.", :bold
              say ''
              say "Step 1: Create an API Key (if you don't have one)", :bold
              say ''
              say '1. Go to:', :cyan
              say '   https://appstoreconnect.apple.com/access/api', :green
              say ''
              say "2. Click the '+' button to create a new key", :cyan
              say ''
              say '3. Select access:', :cyan
              say '   • App Manager (for uploading builds)'
              say '   • Or Admin (full access)'
              say ''
              say '4. Download the .p8 file', :cyan
              say '   ⚠️  Save it securely - you can only download it once!', :yellow
              say ''

              unless yes_with_default?('Have you created and downloaded your API key?', :green)
                say ''
                say '⏭️  You can set this up later with:', :yellow
                say '   • mysigner doctor', :cyan
                say '   • Or via the web dashboard', :cyan
                return false
              end
              say ''

              # Prompt for .p8 file path with retry
              max_retries = 3
              attempts = 0
              p8_path = nil
              private_key = nil

              while attempts < max_retries
                say 'Step 2: Locate your .p8 file', :bold
                say ''
                say '💡 Tip: You can drag & drop the file into terminal to get the path', :cyan
                say ''
                p8_path = ask('Enter the path to your .p8 file:').strip.gsub(/^['"]|['"]$/, '') # Remove quotes
                say ''

                # Expand ~ to home directory
                p8_path = File.expand_path(p8_path)

                if File.exist?(p8_path)
                  # Read private key
                  begin
                    private_key = File.read(p8_path).strip

                    # Validate it looks like a private key
                    unless private_key.include?('BEGIN PRIVATE KEY') || private_key.include?('BEGIN EC PRIVATE KEY')
                      error "This doesn't look like a valid .p8 private key file"
                      attempts += 1
                      next
                    end

                    break # Success!
                  rescue StandardError => e
                    error "Failed to read file: #{e.message}"
                    attempts += 1
                    next
                  end
                else
                  error "File not found: #{p8_path}"
                  attempts += 1

                  if attempts < max_retries
                    say ''
                    say "Please try again (attempt #{attempts + 1}/#{max_retries})", :yellow
                    say ''
                  end
                end
              end

              unless private_key
                say ''
                error "Could not read .p8 file after #{max_retries} attempts"
                say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                return false
              end

              # Auto-extract Key ID from filename (e.g., AuthKey_ABC123.p8 → ABC123)
              filename = File.basename(p8_path)
              key_id = nil
              if filename =~ /AuthKey_([A-Z0-9]+)\.p8/i
                key_id = ::Regexp.last_match(1)
                say "✓ Auto-detected Key ID: #{key_id}", :green
                say ''
              end

              # Prompt for Key ID if not auto-detected
              unless key_id
                say 'Could not auto-detect Key ID from filename.', :yellow
                say ''
                say 'Find your Key ID in App Store Connect:', :cyan
                say '  https://appstoreconnect.apple.com/access/api', :green
                say ''
                key_id = ask('Enter your Key ID (e.g., ABC12345):').strip
                say ''

                if key_id.empty?
                  error 'Key ID cannot be empty'
                  say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                  return false
                end
              end

              # Prompt for Issuer ID
              say 'Step 3: Find your Issuer ID', :bold
              say ''
              say 'Find it in App Store Connect (top right of Keys page):', :cyan
              say '  https://appstoreconnect.apple.com/access/api', :green
              say ''
              issuer_id = ask('Enter your Issuer ID (UUID format):').strip
              say ''

              if issuer_id.empty?
                error 'Issuer ID cannot be empty'
                say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                return false
              end

              # Basic UUID format validation
              unless issuer_id.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
                say "⚠️  Warning: Issuer ID doesn't look like a UUID format", :yellow
                say '   Expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx', :yellow
                say ''
                unless yes_with_default?('Continue anyway?', :yellow)
                  say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                  return false
                end
                say ''
              end

              # Prompt for credential name
              say 'Step 4: Name this credential', :bold
              say ''
              say "Choose a name to identify this API key (e.g., 'Production Key', 'Team A Key')", :cyan
              say "Default: 'CLI Setup' - just press Enter to use it", :cyan
              say ''

              credential_name = nil
              while credential_name.nil? || credential_name.empty?
                name_input = ask('Credential name:').strip
                credential_name = name_input.empty? ? 'CLI Setup' : name_input

                if credential_name.empty?
                  error 'Name cannot be empty'
                  say ''
                end
              end
              say ''
              say "→ Using name: '#{credential_name}'", :cyan
              say ''

              # Validate and upload
              say 'Step 5: Validating credentials with Apple...', :bold
              say ''
              say 'This may take a few seconds...', :yellow
              say ''

              begin
                response = client.post("/api/v1/organizations/#{org_id}/app_store_connect_credentials",
                                       body: {
                                         app_store_connect_credential: {
                                           name: credential_name,
                                           key_id: key_id,
                                           issuer_id: issuer_id,
                                           private_key: private_key
                                         }
                                       })

                if response[:success]
                  data = response[:data]
                  team_id = data['team_id']

                  say '✓ Credentials validated successfully!', :green
                  say ''
                  say 'Details:', :cyan
                  say "  • Name: #{credential_name}"
                  say "  • Key ID: #{key_id}"
                  say "  • Issuer ID: #{issuer_id}"
                  if team_id
                    say "  • Team ID: #{team_id}"
                  else
                    say '  • Team ID: (will be extracted after first sync)'
                  end
                  say '  • Status: Active ✓'
                  say ''
                  say '🎉 App Store Connect is now configured!', :green
                  say ''
                  true # Success!
                else
                  error 'Validation failed'
                  say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                  false
                end
              rescue Mysigner::ClientError => e
                error_msg = e.message

                # Check for duplicate name error
                if error_msg.include?('Name has already been taken') || error_msg.include?('validation_failed')
                  error "A credential with the name '#{credential_name}' already exists"
                  say ''
                  say 'Please choose a different name and try again.', :yellow
                  say 'Or manage credentials via the web dashboard:', :cyan
                  say "  #{client.api_url}/organizations/#{org_id}", :green
                else
                  error "Failed to configure credentials: #{error_msg}"
                  say ''
                  say 'Common issues:', :yellow
                  say '  • Invalid Key ID or Issuer ID'
                  say '  • Incorrect .p8 file content'
                  say "  • API key doesn't have proper permissions"
                  say '  • API key may be revoked or expired'
                end

                say ''
                say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                false
              rescue StandardError => e
                error "Unexpected error: #{e.message}"
                say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                false
              end
            end

            # Setup Google Play credentials
            def setup_google_play_credentials(client, _config, org_id)
              say '🤖 Google Play Service Account Setup', :cyan
              say ''
              say "Let's set up your Google Play credentials.", :bold
              say ''
              say "Step 1: Create a Service Account (if you don't have one)", :bold
              say ''
              say '1. Go to Google Play Console:', :cyan
              say '   https://play.google.com/console', :green
              say ''
              say '2. Navigate to: Settings → API access', :cyan
              say ''
              say "3. Click 'Create new service account' or 'Link existing service account'", :cyan
              say ''
              say '4. In Google Cloud Console, create a Service Account with:', :cyan
              say "   • Name: 'My Signer CLI' (or anything)"
              say '   • Role: Editor or Admin'
              say ''
              say '5. Create a JSON key for the service account', :cyan
              say '   • Click on the service account → Keys → Add Key → JSON'
              say '   • Download the JSON file'
              say ''
              say '6. Back in Play Console, grant the service account access:', :cyan
              say "   • Click 'Done' in the modal"
              say '   • Click on the service account'
              say '   • Set permissions: Release apps, Manage production releases'
              say ''

              unless yes_with_default?('Have you created and downloaded your service account JSON?', :green)
                say ''
                say '⏭️  You can set this up later with:', :yellow
                say '   • mysigner doctor (will prompt for setup)', :cyan
                say '   • Or via the web dashboard', :cyan
                return false
              end
              say ''

              # Prompt for JSON file path with retry
              max_retries = 3
              attempts = 0
              json_path = nil
              service_account_json = nil

              while attempts < max_retries
                say 'Step 2: Locate your service account JSON file', :bold
                say ''
                say '💡 Tip: You can drag & drop the file into terminal to get the path', :cyan
                say ''
                json_path = ask('Enter the path to your service account JSON file:').strip.gsub(/^['"]|['"]$/, '')
                say ''

                # Expand ~ to home directory
                json_path = File.expand_path(json_path)

                if File.exist?(json_path)
                  begin
                    service_account_json = File.read(json_path).strip

                    # Validate it looks like a service account JSON
                    parsed = JSON.parse(service_account_json)
                    unless parsed['type'] == 'service_account' && parsed['client_email'] && parsed['private_key']
                      error "This doesn't look like a valid service account JSON file"
                      say "Expected: type: 'service_account', client_email, and private_key fields", :yellow
                      attempts += 1
                      next
                    end

                    say '✓ Valid service account JSON detected', :green
                    say "  Email: #{parsed['client_email']}", :cyan
                    say ''
                    break # Success!
                  rescue JSON::ParserError => e
                    error "Invalid JSON file: #{e.message}"
                    attempts += 1
                    next
                  rescue StandardError => e
                    error "Failed to read file: #{e.message}"
                    attempts += 1
                    next
                  end
                else
                  error "File not found: #{json_path}"
                  attempts += 1

                  if attempts < max_retries
                    say ''
                    say "Please try again (attempt #{attempts + 1}/#{max_retries})", :yellow
                    say ''
                  end
                end
              end

              unless service_account_json
                say ''
                error "Could not read JSON file after #{max_retries} attempts"
                say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                return false
              end

              # Prompt for credential name
              say 'Step 3: Name this credential', :bold
              say ''
              say "Choose a name to identify this service account (e.g., 'Production', 'CI/CD')", :cyan
              say "Default: 'CLI Setup' - just press Enter to use it", :cyan
              say ''

              credential_name = nil
              while credential_name.nil? || credential_name.empty?
                name_input = ask('Credential name:').strip
                credential_name = name_input.empty? ? 'CLI Setup' : name_input

                if credential_name.empty?
                  error 'Name cannot be empty'
                  say ''
                end
              end
              say ''
              say "→ Using name: '#{credential_name}'", :cyan
              say ''

              # Validate and upload
              say 'Step 4: Saving credentials...', :bold
              say ''

              begin
                response = client.post("/api/v1/organizations/#{org_id}/google_play_credentials",
                                       body: {
                                         google_play_credential: {
                                           name: credential_name,
                                           service_account_json: service_account_json,
                                           active: true
                                         }
                                       })

                say '✓ Google Play credentials saved!', :green
                say ''
                say 'Details:', :cyan
                say "  • Name: #{credential_name}"
                say '  • Status: Active ✓'
                say ''

                # Test the connection
                say 'Testing connection to Google Play...', :yellow

                begin
                  cred_id = response[:data]['id']
                  client.post("/api/v1/organizations/#{org_id}/google_play_credentials/#{cred_id}/test")
                  say '✓ Successfully connected to Google Play API!', :green
                rescue StandardError => e
                  say "⚠️  Connection test failed: #{e.message}", :yellow
                  say '   The credentials are saved but may need verification', :yellow
                end

                say ''
                say '🎉 Google Play is now configured!', :green
                say ''
                true
              rescue Mysigner::ClientError => e
                error_msg = e.message

                if error_msg.include?('already been taken') || error_msg.include?('validation')
                  error "A credential with the name '#{credential_name}' already exists"
                  say ''
                  say 'Please choose a different name and try again.', :yellow
                else
                  error "Failed to configure credentials: #{error_msg}"
                end

                say ''
                say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                false
              rescue StandardError => e
                error "Unexpected error: #{e.message}"
                say "Setup skipped. Run 'mysigner doctor' to try again.", :yellow
                false
              end
            end

            # mysigner-44 — local-only onboarding. Captures ASC and/or Google
            # Play credentials and persists them via LocalCredentials (Keychain
            # on macOS, encrypted file fallback elsewhere). Never calls the
            # server. Raises LocalOnlyOnboardError on invalid input so callers
            # see the failure (Rule 12 — fail loud).
            def onboard_local_only
              say '🚀 My Signer Setup (local-only)', :cyan
              say '=' * 80, :cyan
              say ''
              say 'Local-only mode: credentials stay on this machine.', :bold
              say ''

              # mysigner-22 Phase 5 — discovery first. If the user already
              # has credentials elsewhere (env vars, ~/.appstoreconnect, a
              # service-account JSON at the project root, GOOGLE_APPLICATION_
              # CREDENTIALS) we tell them they don't need to onboard for that
              # platform. We avoid prompting on discovery itself by using a
              # non-TTY stdin proxy, so the resolver fails fast on miss
              # instead of blocking the user.
              asc_already, asc_hint   = discover_local_asc_silently
              play_already, play_hint = discover_local_play_silently

              if asc_already
                say "✓ Detected App Store Connect credentials (#{asc_hint}). No onboarding needed.", :green
                say ''
              end
              if play_already
                say "✓ Detected Google Play credentials (#{play_hint}). No onboarding needed.", :green
                say ''
              end

              stored_asc = []
              stored_play = []

              if !asc_already && yes_with_default?('Set up App Store Connect credentials now?', :cyan)
                say ''
                stored_asc = collect_local_asc_credential
              end
              say ''

              if !play_already && yes_with_default?('Set up Google Play credentials now?', :cyan)
                say ''
                stored_play = collect_local_google_play_credential
              end

              say ''
              say '=' * 80, :green
              say '✓ Local-only setup complete.', :green
              say '=' * 80, :green
              say ''
              if stored_asc.empty? && stored_play.empty?
                say 'No credentials were stored.', :yellow
                say "Re-run 'mysigner --local-only onboard' when you're ready.", :yellow
              else
                say 'Stored credentials:', :cyan
                stored_asc.each  { |id| say "  • ASC key:        #{id}" }
                stored_play.each { |id| say "  • Google Play SA: #{id}" }
                say ''
                say 'To ship:', :bold
                say '  mysigner --local-only ship appstore' unless stored_asc.empty?
                say '  mysigner --local-only ship play'     unless stored_play.empty?
              end
              say ''
            end

            # Returns Array<String> of ids actually stored (empty on skip).
            def collect_local_asc_credential
              say '📱 App Store Connect (local-only)', :cyan
              say ''

              p8_path = ask('Path to your .p8 private key:').to_s.strip.gsub(/^['"]|['"]$/, '')
              p8_path = File.expand_path(p8_path)
              raise_local_onboard_error!(".p8 file not found: #{p8_path}") unless File.exist?(p8_path)

              p8_pem = File.read(p8_path)
              validate_p8_pem!(p8_pem)

              # Auto-detect Key ID from filename (AuthKey_ABC123.p8 → ABC123).
              key_id = nil
              if File.basename(p8_path) =~ /AuthKey_([A-Z0-9]+)\.p8/i
                key_id = ::Regexp.last_match(1)
                say "✓ Auto-detected Key ID: #{key_id}", :green
              end
              key_id = ask('Enter your Key ID (e.g., ABC12345):').to_s.strip if key_id.nil? || key_id.empty?
              raise_local_onboard_error!('Key ID cannot be empty') if key_id.empty?

              issuer_id = ask('Enter your Issuer ID (UUID):').to_s.strip
              raise_local_onboard_error!('Issuer ID cannot be empty') if issuer_id.empty?

              # Storage shape matches mysigner-42's Option A: id == key_id,
              # secret is a JSON envelope so AscJwtMinter can reconstruct
              # (key_id, issuer_id, p8_pem) from one lookup.
              secret = JSON.generate('issuer_id' => issuer_id, 'p8_pem' => p8_pem)
              Mysigner::LocalCredentials.store(kind: :asc, id: key_id, secret: secret)

              say '✓ ASC credential stored locally.', :green
              [key_id]
            end

            # Returns Array<String> of ids actually stored (empty on skip).
            def collect_local_google_play_credential
              say '🤖 Google Play (local-only)', :cyan
              say ''

              json_path = ask('Path to your service-account JSON:').to_s.strip.gsub(/^['"]|['"]$/, '')
              json_path = File.expand_path(json_path)
              raise_local_onboard_error!("SA-JSON file not found: #{json_path}") unless File.exist?(json_path)

              raw = File.read(json_path)
              parsed = validate_sa_json!(raw)
              client_email = parsed['client_email']

              Mysigner::LocalCredentials.store(kind: :google_play, id: client_email, secret: raw)

              say "✓ Google Play credential stored locally (#{client_email}).", :green
              [client_email]
            end

            # Verifies the file looks like an EC private key in the form
            # AscJwtMinter requires. Fails loud — any malformed input raises
            # before we touch the Keychain.
            def validate_p8_pem!(pem)
              key = OpenSSL::PKey.read(pem.to_s)
              return if key.is_a?(OpenSSL::PKey::EC)

              raise_local_onboard_error!("invalid .p8: expected EC private key, got #{key.class}")
            rescue OpenSSL::PKey::PKeyError => e
              raise_local_onboard_error!("invalid .p8: #{e.message}")
            end

            # Returns the parsed hash. Validates the three fields the
            # GoogleOauthMinter (and the SA JWT spec) actually need.
            def validate_sa_json!(raw)
              parsed = JSON.parse(raw)
              missing = []
              missing << "type=='service_account'"   unless parsed['type'] == 'service_account'
              missing << 'client_email'              if parsed['client_email'].to_s.empty?
              missing << 'private_key'               if parsed['private_key'].to_s.empty?
              raise_local_onboard_error!("invalid service-account JSON (missing/wrong: #{missing.join(', ')})") if missing.any?

              parsed
            rescue JSON::ParserError => e
              raise_local_onboard_error!("invalid service-account JSON: #{e.message}")
            end

            def raise_local_onboard_error!(message)
              raise Mysigner::CLI::LocalOnlyOnboardError, message
            end

            # mysigner-22 Phase 5 — silent ASC discovery for onboard. Returns
            # [bool, hint_string]. We feed the resolver a non-TTY stdin proxy
            # so the prompt tier is OFF — discovery either resolves from a
            # higher tier or returns false-with-no-hint. Any structural
            # surprises (Keychain corruption, multiple disk files needing
            # disambiguation) bubble out as "no, prompt for it" rather than
            # crashing the onboard flow.
            def discover_local_asc_silently
              require 'mysigner/credential_resolver'
              no_tty = Object.new
              def no_tty.tty?
                false
              end
              creds = Mysigner::CredentialResolver.resolve_asc(stdin: no_tty, stderr: StringIO.new)
              hint = case creds.source
                     when :flag     then 'from --asc-* flags'
                     when :env      then 'from APP_STORE_CONNECT_API_KEY_* env vars'
                     when :keychain then "from Keychain (#{creds.key_id})"
                     when :disk     then "from #{Mysigner::CredentialResolver::APPLE_PRIVATE_KEYS_DIR}/AuthKey_#{creds.key_id}.p8"
                     else 'from cascade'
                     end
              [true, hint]
            rescue Mysigner::CredentialResolver::CredentialNotFoundError,
                   Mysigner::CredentialResolver::AmbiguousCredentialsError
              [false, nil]
            end

            def discover_local_play_silently
              require 'mysigner/credential_resolver'
              no_tty = Object.new
              def no_tty.tty?
                false
              end
              creds = Mysigner::CredentialResolver.resolve_play(stdin: no_tty, stderr: StringIO.new)
              hint = case creds.source
                     when :flag     then 'from --play-credentials flag'
                     when :env      then 'from GOOGLE_APPLICATION_CREDENTIALS'
                     when :keychain then "from Keychain (#{creds.client_email})"
                     when :disk     then "from project (#{creds.client_email})"
                     else 'from cascade'
                     end
              [true, hint]
            rescue Mysigner::CredentialResolver::CredentialNotFoundError,
                   Mysigner::CredentialResolver::AmbiguousCredentialsError
              [false, nil]
            end
          end
        end
      end
    end

    # Raised by `onboard` in local-only mode when user input is unusable
    # (missing file, malformed PEM, malformed SA-JSON). Surfaces the failure
    # to the caller rather than silently writing a broken credential.
    class LocalOnlyOnboardError < StandardError; end
  end
end
