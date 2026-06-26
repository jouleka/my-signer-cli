# frozen_string_literal: true

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
          return localhost_url if localhost_accessible?(localhost_url)

          # Default to production
          'https://mysigner.dev'
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
          rescue StandardError
            false
          end
        end

        # Prompt for API URL with smart default and validation
        def prompt_api_url
          default = default_api_url
          say "API URL: #{default}", :cyan

          loop do
            custom = ask('Press Enter to use default, or type custom URL:', default: '')

            # Use default if empty or nil
            return default if custom.nil? || custom.empty?

            # Validate and normalize the custom URL
            normalized_url = normalize_api_url(custom.strip)

            return normalized_url if valid_api_url?(normalized_url)

            error 'Invalid URL format'
            say 'Please enter a valid URL (e.g., http://localhost:3000 or https://api.example.com)', :yellow
            say ''
          end
        end

        # Normalize API URL (add protocol, remove trailing slash)
        def normalize_api_url(url)
          url = url.to_s.strip

          # Add a scheme if none was given. Default to https; fall back to
          # http ONLY for an obvious loopback host, so a scheme-less remote
          # host never silently downgrades the API token to cleartext.
          unless url.match?(%r{^https?://})
            bare_host = url[%r{\A[^/:]+}].to_s.downcase
            scheme = Mysigner::Client::LOOPBACK_HOSTS.include?(bare_host) ? 'http' : 'https'
            url = "#{scheme}://#{url}"
          end

          # Remove trailing slash
          url.chomp('/')
        end

        # Validate API URL format
        def valid_api_url?(url)
          uri = URI.parse(url)

          # Must have http or https scheme
          return false unless uri.scheme.to_s.match?(/^https?$/)

          # Must have a host
          return false if uri.host.nil? || uri.host.empty?

          # Plain http may only target a loopback host (local dev). The API
          # token is sent as a Bearer header, so http to a remote host would
          # leak it in cleartext. uri.hostname strips IPv6 brackets ([::1]).
          return false if uri.scheme == 'http' &&
                          !Mysigner::Client::LOOPBACK_HOSTS.include?(uri.hostname.downcase)

          # Valid formats:
          # - http://localhost:3000
          # - https://api.example.com
          true
        rescue URI::InvalidURIError
          false
        end

        # Prompt for user email with validation
        def prompt_for_email
          loop do
            email = ask('Your Email:').to_s.strip

            if email.empty?
              error 'Email cannot be empty'
              say ''
              next
            end

            unless valid_email?(email)
              error 'Invalid email format'
              say 'Please enter a valid email address (e.g., user@example.com)', :yellow
              say ''
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
