# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'base64'
require 'openssl'
require 'json'
require 'mysigner/auth/google_oauth_minter'

RSpec.describe Mysigner::Auth::GoogleOauthMinter do
  # Generate one RSA key for the whole spec — keygen is slow (~1s) and the
  # key's only job is to satisfy googleauth's signer; the test never verifies
  # the JWT signature server-side because WebMock intercepts the exchange.
  before(:all) { @rsa_key = OpenSSL::PKey::RSA.new(2048) }
  let(:rsa_key) { @rsa_key }

  let(:sa_hash) do
    {
      'type' => 'service_account',
      'project_id' => 'my-project',
      'private_key_id' => 'kid-abc',
      'private_key' => rsa_key.to_pem,
      'client_email' => 'svc@my-project.iam.gserviceaccount.com',
      'client_id' => '1234567890',
      'auth_uri' => 'https://accounts.google.com/o/oauth2/auth',
      'token_uri' => 'https://oauth2.googleapis.com/token'
    }
  end
  let(:sa_json) { JSON.dump(sa_hash) }
  let(:token_response_body) do
    { access_token: 'ya29.LOCAL_TEST_TOKEN', expires_in: 3599, token_type: 'Bearer' }.to_json
  end

  describe '#initialize validation' do
    it 'raises ArgumentError when input is nil' do
      expect { described_class.new(nil) }.to raise_error(ArgumentError, /required/)
    end

    it 'raises ArgumentError when input is an empty string' do
      expect { described_class.new('') }.to raise_error(ArgumentError, /required/)
      expect { described_class.new('   ') }.to raise_error(ArgumentError, /required/)
    end

    it 'raises ArgumentError when input is an empty hash' do
      expect { described_class.new({}) }.to raise_error(ArgumentError, /empty/)
    end

    it 'raises ArgumentError when JSON is unparseable' do
      expect { described_class.new('{not json') }.to raise_error(ArgumentError, /not valid JSON/)
    end

    it 'raises ArgumentError listing every missing required key' do
      partial = { 'type' => 'service_account' }
      expect { described_class.new(partial) }.to raise_error(
        ArgumentError, /missing required keys:.*client_email.*private_key.*project_id/
      )
    end

    it 'treats blank string values for required keys as missing' do
      partial = sa_hash.merge('client_email' => '   ')
      expect { described_class.new(partial) }.to raise_error(ArgumentError, /client_email/)
    end

    it 'accepts a Hash with symbol keys' do
      symbol_hash = sa_hash.transform_keys(&:to_sym)
      expect { described_class.new(symbol_hash) }.not_to raise_error
    end

    it 'accepts a JSON string' do
      expect { described_class.new(sa_json) }.not_to raise_error
    end
  end

  describe '#mint' do
    let(:minter) { described_class.new(sa_json) }

    before do
      # Allow any request body — body shape is asserted separately so a single
      # stub response is reused across the assertions in this describe block.
      stub_request(:post, %r{https://(www\.googleapis\.com/oauth2/v4|oauth2\.googleapis\.com)/token})
        .to_return(
          status: 200,
          body: token_response_body,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'returns the access_token string from the OAuth2 exchange' do
      expect(minter.mint).to eq('ya29.LOCAL_TEST_TOKEN')
    end

    it 'POSTs the JWT-bearer grant to Google\'s token endpoint' do
      minter.mint

      # Verifying the wire format is the WHOLE point of building this locally:
      # if the grant_type or assertion shape regresses, Google rejects the
      # exchange and `ship play` breaks. Encode that contract in the test.
      expect(WebMock).to(have_requested(
        :post, %r{https://(www\.googleapis\.com/oauth2/v4|oauth2\.googleapis\.com)/token}
      ).with do |req|
        body = URI.decode_www_form(req.body).to_h
        body['grant_type'] == 'urn:ietf:params:oauth:grant-type:jwt-bearer' &&
          body['assertion']&.start_with?('eyJ') # JWT header always base64url-encodes to "eyJ..."
      end)
    end

    it 'embeds the default Play Publishing scope in the JWT assertion' do
      minter.mint

      assertion = captured_assertion
      payload = decode_jwt_payload(assertion)
      expect(payload['scope']).to eq(described_class::DEFAULT_SCOPE)
      expect(payload['iss']).to eq('svc@my-project.iam.gserviceaccount.com')
      # `aud` must match the token endpoint googleauth actually POSTs to.
      # Google accepts either of these two equivalent token URLs.
      expect(payload['aud']).to match(
        %r{https://(www\.googleapis\.com/oauth2/v4|oauth2\.googleapis\.com)/token}
      )
    end

    it 'passes through a custom scope override' do
      custom_scope = 'https://www.googleapis.com/auth/cloud-platform'
      minter.mint(scope: custom_scope)

      payload = decode_jwt_payload(captured_assertion)
      expect(payload['scope']).to eq(custom_scope)
    end
  end

  describe '#mint_with_expiry' do
    let(:minter) { described_class.new(sa_json) }

    before do
      stub_request(:post, %r{https://(www\.googleapis\.com/oauth2/v4|oauth2\.googleapis\.com)/token})
        .to_return(
          status: 200,
          body: token_response_body,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'returns the access_token and a computed expires_at' do
      result = minter.mint_with_expiry
      expect(result.access_token).to eq('ya29.LOCAL_TEST_TOKEN')
      expect(result.expires_at).to be_within(5).of(Time.now + 3599)
    end
  end

  # --- helpers ---

  def captured_assertion
    last_request = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last
    body = URI.decode_www_form(last_request.body).to_h
    body['assertion']
  end

  # Decode the JWT payload (middle segment) without verifying the signature —
  # signature verification needs the public key Google holds, which is outside
  # the scope of this unit test.
  def decode_jwt_payload(jwt)
    payload_segment = jwt.split('.')[1]
    # JWT uses base64url without padding; pad it back so Ruby can decode.
    padded = payload_segment + ('=' * ((4 - (payload_segment.length % 4)) % 4))
    JSON.parse(Base64.urlsafe_decode64(padded))
  end
end
