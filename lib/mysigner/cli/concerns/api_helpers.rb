module Mysigner
  class CLI < Thor
    module Concerns
      module ApiHelpers
        # Smart API URL detection
        def default_api_url
          # Priority:
          # 1. Environment variable
          # 2. Check if localhost is running
          # 3. Production default
          
          return ENV['MYSIGNER_API_URL'] if ENV['MYSIGNER_API_URL']
          
          # Check if localhost:3000 is accessible
          localhost_url = 'http://localhost:3000'
          if localhost_accessible?(localhost_url)
            return localhost_url
          end
          
          # Default to production
          'https://api.mysigner.app'
        end

        def localhost_accessible?(url)
          require 'net/http'
          require 'uri'
          
          begin
            uri = URI.parse(url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 1
            http.read_timeout = 1
            request = Net::HTTP::Get.new('/up')
            response = http.request(request)
            response.code == '200'
          rescue
            false
          end
        end

        # Prompt for API URL with smart default and validation
        def prompt_api_url
          default = default_api_url
          say "API URL: #{default}", :cyan
          
          loop do
            custom = ask("Press Enter to use default, or type custom URL:", default: "")
            
            # Use default if empty or nil
            if custom.nil? || custom.empty?
              return default
            end
            
            # Validate and normalize the custom URL
            normalized_url = normalize_api_url(custom.strip)
            
            if valid_api_url?(normalized_url)
              return normalized_url
            else
              error "Invalid URL format"
              say "Please enter a valid URL (e.g., http://localhost:3000 or https://api.example.com)", :yellow
              say ""
            end
          end
        end

        # Normalize API URL (add protocol, remove trailing slash)
        def normalize_api_url(url)
          # Add http:// if no protocol specified
          url = "http://#{url}" unless url.match?(/^https?:\/\//)
          
          # Remove trailing slash
          url = url.chomp('/')
          
          url
        end

        # Validate API URL format
        def valid_api_url?(url)
          begin
            uri = URI.parse(url)
            
            # Must have http or https scheme
            return false unless uri.scheme.to_s.match?(/^https?$/)
            
            # Must have a host
            return false if uri.host.nil? || uri.host.empty?
            
            # Valid formats:
            # - http://localhost:3000
            # - https://api.example.com
            # - http://192.168.1.1:8080
            true
          rescue URI::InvalidURIError
            false
          end
        end

        # Prompt for user email with validation
        def prompt_for_email
          loop do
            email = ask("Your Email:").to_s.strip
            
            if email.empty?
              error "Email cannot be empty"
              say ""
              next
            end
            
            unless valid_email?(email)
              error "Invalid email format"
              say "Please enter a valid email address (e.g., user@example.com)", :yellow
              say ""
              next
            end
            
            return email
          end
        end

        # Basic email validation
        def valid_email?(email)
          # Simple regex for basic email validation
          # Format: local@domain.tld
          email_regex = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
          email.match?(email_regex)
        end
      end
    end
  end
end
