# frozen_string_literal: true

require 'jwt'
require 'openssl'

module Mysigner
  module Auth
    # Mints an Apple App Store Connect API JWT locally from a .p8 private key.
    #
    # Used by the CLI's local-only mode (epic mysigner-22) so credentials never
    # leave the user's machine. The MySigner server path mints the same shape
    # server-side; this class produces a token equivalent to what the server
    # would return, so downstream ASC callers (e.g. Mysigner::Upload::AscRestUploader)
    # are agnostic to where the token came from.
    #
    # Apple's spec (https://developer.apple.com/documentation/appstoreconnectapi/
    # generating-tokens-for-api-requests):
    #   - header: { alg: ES256, kid: <key_id>, typ: JWT }
    #   - claims: iss=<issuer_id>, iat=<now>, exp=<iat+TTL>, aud=appstoreconnect-v1
    #   - signed ES256 over base64url(header).base64url(claims) with the .p8 EC key
    #
    # Apple caps token lifetime at 20 minutes. We default to 19 minutes so
    # consumers can safely reuse a token throughout a typical ASC upload session
    # without bumping into the cap mid-request.
    class AscJwtMinter
      DEFAULT_TTL = 19 * 60
      AUDIENCE    = 'appstoreconnect-v1'

      def initialize(key_id:, issuer_id:, p8_pem:)
        @key_id    = present!(key_id, 'key_id')
        @issuer_id = present!(issuer_id, 'issuer_id')
        @ec_key    = parse_ec_key(present!(p8_pem, 'p8_pem'))
      end

      # Returns a String JWT. `now` is injectable for testability.
      def mint(ttl: DEFAULT_TTL, now: Time.now)
        iat = now.to_i
        payload = {
          iss: @issuer_id,
          iat: iat,
          exp: iat + ttl,
          aud: AUDIENCE
        }
        headers = { kid: @key_id, typ: 'JWT' }
        # JWT.encode with ES256 produces a fixed-width raw r||s signature per
        # JWA RFC 7518, which is what Apple requires.
        JWT.encode(payload, @ec_key, 'ES256', headers)
      end

      private

      def present!(value, name)
        raise ArgumentError, "#{name} must be present" if value.nil? || value.to_s.empty?

        value
      end

      def parse_ec_key(p8_pem)
        key = OpenSSL::PKey.read(p8_pem.to_s)
        raise ArgumentError, "p8_pem must be an EC private key (got #{key.class})" unless key.is_a?(OpenSSL::PKey::EC)

        key
      rescue OpenSSL::PKey::PKeyError => e
        raise ArgumentError, "p8_pem could not be parsed as a private key: #{e.message}"
      end
    end
  end
end
