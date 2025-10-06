module Mysigner
  class CLI < Thor
    module Concerns
      module ErrorHandlers
        # Show guidance for getting a token
        def show_token_guidance(api_url)
          say "Don't have a token yet?", :yellow
          say "  1. Go to: #{api_url}", :cyan
          say "  2. Navigate to: Your Organization → API Tokens", :cyan
          say "  3. Click 'Create Token'", :cyan
          say "  4. Copy the token (you'll only see it once!)", :cyan
          say ""
          say "💡 Or run 'mysigner setup' for step-by-step guidance", :yellow
          say ""
        end

        # Handle connection failure
        def handle_connection_failure(api_url)
          say ""
          say "Possible issues:", :yellow
          say "  • API server is not running at #{api_url}"
          say "  • Network connectivity problems"
          say "  • Incorrect API URL"
          say ""
          say "💡 Try:", :cyan
          say "  • Check the API URL is correct"
          say "  • Verify the server is running"
          say "  • Run 'mysigner setup' for guided setup"
        end

        # Show guidance for creating an organization
        def show_create_org_guidance(api_url)
          say "To create an organization:", :cyan
          say "  1. Go to: #{api_url}"
          say "  2. Sign in to your account"
          say "  3. Click 'Create Organization'"
          say "  4. Then generate a new API token for that organization"
          say ""
          say "💡 Run 'mysigner setup' for step-by-step guidance", :yellow
        end

        # Handle unauthorized error
        def handle_unauthorized_error(api_url)
          say ""
          say "=" * 80, :red
          say "✗ Authentication Failed", :red
          say "=" * 80, :red
          say ""
          say "Your API token is invalid or has been revoked.", :bold
          say ""
          say "Common reasons:", :yellow
          say "  • Token was copied incorrectly (missing characters)"
          say "  • Token was revoked in the web dashboard"
          say "  • Token has expired"
          say "  • You're using the wrong API URL"
          say ""
          say "To fix this:", :cyan
          say "  1. Go to: #{api_url}/organizations/YOUR_ORG/api_tokens"
          say "  2. Check if your token is still active"
          say "  3. If revoked or expired, create a new token"
          say "  4. Copy the NEW token carefully (entire string)"
          say "  5. Run 'mysigner login' again"
          say ""
          say "💡 Or run 'mysigner setup' for guided setup", :yellow
          say ""
        end

        # Handle connection error
        def handle_connection_error(error, api_url)
          say ""
          say "=" * 80, :red
          say "✗ Connection Failed", :red
          say "=" * 80, :red
          say ""
          say "Error: #{error.message}", :red
          say ""
          say "Possible causes:", :yellow
          say "  • My Signer API is not running at #{api_url}"
          say "  • Network connectivity issues"
          say "  • Firewall blocking the connection"
          say "  • Incorrect API URL"
          say ""
          say "To fix this:", :cyan
          say ""
          if api_url.include?('localhost')
            say "  For local development:", :bold
            say "    1. Make sure Rails server is running:"
            say "       cd path/to/my-signer"
            say "       bin/rails server"
            say ""
            say "    2. Verify it's accessible:"
            say "       curl #{api_url}/up"
            say ""
          else
            say "  For production:", :bold
            say "    1. Check the API URL is correct"
            say "    2. Verify the service is running"
            say "    3. Check your internet connection"
            say ""
          end
          say "  Or set a custom API URL:", :bold
          say "    export MYSIGNER_API_URL=http://your-server.com"
          say ""
          say "💡 Run 'mysigner setup' to reconfigure", :yellow
          say ""
        end

        # Handle unexpected error
        def handle_unexpected_error(error, api_url)
          say ""
          say "=" * 80, :red
          say "✗ Unexpected Error", :red
          say "=" * 80, :red
          say ""
          say "Error: #{error.message}", :red
          say "Type: #{error.class}", :red if ENV['DEBUG']
          say ""
          say "This is unexpected. Please try:", :yellow
          say "  1. Run 'mysigner setup' to reconfigure"
          say "  2. Check #{api_url} is accessible"
          say "  3. Run 'mysigner doctor' to check your environment"
          say ""
          if ENV['DEBUG']
            say "Stack trace:", :red
            say error.backtrace.first(5).join("\n"), :red
            say ""
          else
            say "💡 For more details, run with DEBUG=1", :yellow
            say ""
          end
        end
      end
    end
  end
end
