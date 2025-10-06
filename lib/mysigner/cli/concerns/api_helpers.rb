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

        # Prompt for API URL with smart default
        def prompt_api_url
          default = default_api_url
          say "API URL: #{default}", :cyan
          
          custom = ask("Press Enter to use default, or type custom URL:", default: "")
          custom.empty? ? default : custom.strip
        end
      end
    end
  end
end
