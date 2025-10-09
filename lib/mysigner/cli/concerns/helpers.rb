module Mysigner
  class CLI < Thor
    module Concerns
      module Helpers
        # Helper for timing operations
        def with_timing(label)
          start = Time.now
          result = yield
          duration = Time.now - start
          [result, duration]
        end

        def format_duration(seconds)
          if seconds < 60
            "#{seconds.round}s"
          elsif seconds < 3600
            minutes = (seconds / 60).floor
            secs = (seconds % 60).round
            "#{minutes}m #{secs}s"
          else
            hours = (seconds / 3600).floor
            minutes = ((seconds % 3600) / 60).floor
            "#{hours}h #{minutes}m"
          end
        end

        def format_bytes(bytes)
          if bytes < 1024
            "#{bytes} B"
          elsif bytes < 1024 * 1024
            "#{(bytes / 1024.0).round(1)} KB"
          else
            "#{(bytes / (1024.0 * 1024)).round(1)} MB"
          end
        end

        def load_config
          config = Config.new

          unless config.exists?
            error "Not logged in. Run 'mysigner login' first."
            exit 1
          end

          config.load
          
          # Check if email migration is needed
          if config.needs_email_migration?
            migrate_config_email(config)
          end
          
          config
        end

        # Migrate config to include user email
        def migrate_config_email(config)
          say ""
          say "=" * 80, :yellow
          say "⚠️  Configuration Update Required", :yellow
          say "=" * 80, :yellow
          say ""
          say "We've added email validation for enhanced security.", :bold
          say "Please provide your email address to continue.", :bold
          say ""
          say "This is a one-time setup and will be saved to your config.", :cyan
          say ""
          
          user_email = prompt_for_email
          
          say ""
          say "Validating email with your existing token...", :yellow
          
          begin
            # Test the token with the provided email
            client = Client.new(
              api_url: config.api_url,
              api_token: config.api_token,
              user_email: user_email
            )
            
            # Try a simple API call to validate
            response = client.test_connection
            
            if response[:success]
              # Save the email
              config.user_email = user_email
              config.save
              
              say "✓ Email validated and saved successfully!", :green
              say ""
            else
              error "Could not validate your configuration"
              say "Please run 'mysigner login' to reconfigure", :yellow
              exit 1
            end
          rescue Mysigner::UnauthorizedError => e
            error "Email validation failed"
            say ""
            
            if e.message.include?("doesn't belong to") || e.message.include?("use your own token")
              say "⚠️  The stored token doesn't belong to #{user_email}.", :yellow
              say ""
              say "This means you're using a token from a different account.", :yellow
              say "Please run 'mysigner login' to login with your own account.", :yellow
            else
              say "Your stored token is invalid or expired.", :yellow
              say "Please run 'mysigner login' to re-authenticate.", :yellow
            end
            
            exit 1
          rescue => e
            error "Migration failed: #{e.message}"
            say "Please run 'mysigner login' to reconfigure", :yellow
            exit 1
          end
        end

        def create_client(config)
          Client.new(
            api_url: config.api_url,
            api_token: config.api_token,
            user_email: config.user_email
          )
        end

        def error(message)
          say "✗ Error: #{message}", :red
        end
      end
    end
  end
end
