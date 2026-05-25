# frozen_string_literal: true

require 'json'
require 'stringio'
require 'googleauth'

module Mysigner
  module Auth
    # Mints a short-lived Google OAuth2 access_token from a service-account
    # JSON key, locally — without going through the MySigner server. The
    # service-account JSON never leaves the caller's process.
    #
    # Delegates the JWT mint + assertion exchange + caching to googleauth
    # (Google::Auth::ServiceAccountCredentials), which is already a runtime
    # dependency for the Play Publishing API client.
    class GoogleOauthMinter
      DEFAULT_SCOPE = 'https://www.googleapis.com/auth/androidpublisher'
      REQUIRED_KEYS = %w[type client_email private_key project_id].freeze

      # @param service_account_json [String, Hash] the raw JSON string or an
      #   already-parsed Hash. Validated for required keys.
      # @raise [ArgumentError] when input is nil/empty, unparseable, or missing
      #   any of {REQUIRED_KEYS}.
      def initialize(service_account_json)
        @json_hash = coerce_to_hash(service_account_json)
        validate_required_keys!(@json_hash)
      end

      # @param scope [String] OAuth2 scope. Defaults to the Play Publishing
      #   scope used by `ship play`. Override for other Google APIs.
      # @return [String] a non-empty access_token (e.g. "ya29...").
      def mint(scope: DEFAULT_SCOPE)
        token_data = fetch_token(scope)
        token_data['access_token'] || token_data[:access_token]
      end

      # Variant that returns both the token and its expiry timestamp, for
      # callers that want to manage caching themselves.
      # @return [TokenWithExpiry] members :access_token, :expires_at (Time or nil)
      def mint_with_expiry(scope: DEFAULT_SCOPE)
        token_data = fetch_token(scope)
        access_token = token_data['access_token'] || token_data[:access_token]
        expires_in = token_data['expires_in'] || token_data[:expires_in]
        expires_at = expires_in ? Time.now + expires_in.to_i : nil
        TokenWithExpiry.new(access_token, expires_at)
      end

      TokenWithExpiry = Struct.new(:access_token, :expires_at)

      private

      def fetch_token(scope)
        creds = Google::Auth::ServiceAccountCredentials.make_creds(
          json_key_io: StringIO.new(JSON.dump(@json_hash)),
          scope: scope
        )
        creds.fetch_access_token!
      end

      def coerce_to_hash(input)
        raise ArgumentError, 'service_account_json is required' if input.nil?

        case input
        when Hash
          raise ArgumentError, 'service_account_json hash is empty' if input.empty?

          input.transform_keys(&:to_s)
        when String
          raise ArgumentError, 'service_account_json is required' if input.strip.empty?

          begin
            JSON.parse(input)
          rescue JSON::ParserError => e
            raise ArgumentError, "service_account_json is not valid JSON: #{e.message}"
          end
        else
          raise ArgumentError, "service_account_json must be a String or Hash, got #{input.class}"
        end
      end

      def validate_required_keys!(hash)
        missing = REQUIRED_KEYS.reject { |key| hash[key].is_a?(String) && !hash[key].strip.empty? }
        return if missing.empty?

        raise ArgumentError, "service_account_json is missing required keys: #{missing.join(', ')}"
      end
    end
  end
end
