# frozen_string_literal: true

module Mysigner
  class CLI < Thor
    module Concerns
      module Helpers
        # Helper for timing operations
        def with_timing(_label)
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
          # CI/CD mode: prefer environment variables when set
          return Config.from_env if Config.env_configured?

          config = Config.new

          unless config.exists?
            error "Not logged in. Run 'mysigner login' first."
            say ''
            say 'Tip: For CI/CD, set these environment variables instead:', :yellow
            say '  export MYSIGNER_API_TOKEN=your_token', :yellow
            say '  export MYSIGNER_ORG_ID=your_org_id', :yellow
            say '  export MYSIGNER_API_URL=https://mysigner.dev  # optional', :yellow
            say '  export MYSIGNER_EMAIL=you@example.com          # optional', :yellow
            exit 1
          end

          config.load
          config
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
