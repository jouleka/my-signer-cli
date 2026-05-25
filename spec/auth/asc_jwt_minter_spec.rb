# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'json'
require 'openssl'
require 'jwt'
require 'mysigner/auth/asc_jwt_minter'

RSpec.describe Mysigner::Auth::AscJwtMinter do
  # Generating a real EC keypair on prime256v1 (the curve Apple's .p8 keys use)
  # takes ~1ms. We do it once for the whole file because every test needs the
  # same private key bytes AND a way to verify the signature with the matching
  # public key — i.e. exactly what a real Apple .p8 round-trip looks like.
  before(:all) do
    @ec_key = OpenSSL::PKey::EC.generate('prime256v1')
    @p8_pem = @ec_key.to_pem
    @public_key = OpenSSL::PKey::EC.new(@ec_key.public_to_pem)
  end

  let(:key_id)    { 'ABC123DEFG' }
  let(:issuer_id) { '69a6de70-1234-47e3-e053-5b8c7c11a4d1' }

  def new_minter(**overrides)
    described_class.new(
      key_id: overrides.fetch(:key_id, key_id),
      issuer_id: overrides.fetch(:issuer_id, issuer_id),
      p8_pem: overrides.fetch(:p8_pem, @p8_pem)
    )
  end

  # Apple sends the JWT in an Authorization header; the minimum guarantee a
  # consumer relies on is "three base64url segments joined by dots". If we ever
  # accidentally returned the segments unjoined (or DER-wrapped), every ASC
  # request would fail with an opaque 401.
  it 'returns a String with three base64url segments separated by dots' do
    token = new_minter.mint
    expect(token).to be_a(String)
    parts = token.split('.')
    expect(parts.length).to eq(3)
    parts.each { |p| expect(p).to match(/\A[A-Za-z0-9_-]+\z/) }
  end

  # Header shape is part of Apple's contract. If we drop `kid` or use the wrong
  # alg, Apple rejects the token with a generic 401 — verifying the decoded
  # header exactly catches that regression at unit-test time.
  it 'encodes the header with alg=ES256, typ=JWT, and the supplied kid' do
    token = new_minter.mint
    header_b64 = token.split('.').first
    header = JSON.parse(Base64.urlsafe_decode64(pad(header_b64)))
    expect(header).to eq({ 'alg' => 'ES256', 'kid' => key_id, 'typ' => 'JWT' })
  end

  # Claims shape is the other half of Apple's contract. `aud` is a constant
  # Apple matches verbatim; `iss` is the team's issuer_id; `iat`/`exp` bound
  # token lifetime. Drift here would silently break ASC authentication.
  it 'encodes claims with iss, iat, exp, and the fixed audience' do
    fixed_now = Time.utc(2026, 1, 1)
    token = new_minter.mint(now: fixed_now)
    claims_b64 = token.split('.')[1]
    claims = JSON.parse(Base64.urlsafe_decode64(pad(claims_b64)))
    expect(claims).to eq(
      'iss' => issuer_id,
      'iat' => fixed_now.to_i,
      'exp' => fixed_now.to_i + described_class::DEFAULT_TTL,
      'aud' => 'appstoreconnect-v1'
    )
  end

  # Apple rejects tokens with lifetime > 20 minutes. The 19-minute default
  # leaves 60s of headroom; if anyone bumps DEFAULT_TTL past 20 min, this test
  # fails before users hit a confusing 401.
  it 'defaults to a 19-minute lifetime, comfortably under Apple\'s 20-minute cap' do
    expect(described_class::DEFAULT_TTL).to eq(19 * 60)
    expect(described_class::DEFAULT_TTL).to be < 20 * 60
  end

  # The clock is injectable so this minter can be exercised deterministically
  # by upstream tests; the ticket specifies a concrete expected value.
  it 'honours the injected clock and ttl' do
    token = new_minter.mint(ttl: 600, now: Time.utc(2026, 1, 1))
    claims = JSON.parse(Base64.urlsafe_decode64(pad(token.split('.')[1])))
    expect(claims['iat']).to eq(1_767_225_600)
    expect(claims['exp']).to eq(1_767_226_200)
  end

  # The whole point of local minting is that the signature is real. Re-deriving
  # the public key from the .p8 PEM and verifying the JWT round-trips is the
  # closest a unit test can get to "Apple would actually accept this token".
  it 'produces a signature that verifies with the matching EC public key' do
    token = new_minter.mint
    decoded, header = JWT.decode(token, @public_key, true, { algorithm: 'ES256' })
    expect(header['alg']).to eq('ES256')
    expect(decoded['aud']).to eq('appstoreconnect-v1')
  end

  describe 'fail-loud validation' do
    it 'raises ArgumentError when key_id is nil' do
      expect { new_minter(key_id: nil) }.to raise_error(ArgumentError, /key_id/)
    end

    it 'raises ArgumentError when key_id is empty' do
      expect { new_minter(key_id: '') }.to raise_error(ArgumentError, /key_id/)
    end

    it 'raises ArgumentError when issuer_id is nil' do
      expect { new_minter(issuer_id: nil) }.to raise_error(ArgumentError, /issuer_id/)
    end

    it 'raises ArgumentError when issuer_id is empty' do
      expect { new_minter(issuer_id: '') }.to raise_error(ArgumentError, /issuer_id/)
    end

    it 'raises ArgumentError when p8_pem is nil' do
      expect { new_minter(p8_pem: nil) }.to raise_error(ArgumentError, /p8_pem/)
    end

    it 'raises ArgumentError when p8_pem is empty' do
      expect { new_minter(p8_pem: '') }.to raise_error(ArgumentError, /p8_pem/)
    end

    it 'raises ArgumentError when p8_pem is not parseable as a PEM' do
      expect { new_minter(p8_pem: 'this is not a pem') }
        .to raise_error(ArgumentError, /could not be parsed/)
    end

    # If someone hands in an RSA .pem instead of Apple's .p8 EC key we must
    # fail at init, not at sign time with a cryptic OpenSSL error.
    it 'raises ArgumentError when the key is not an EC key' do
      rsa_pem = OpenSSL::PKey::RSA.new(2048).to_pem
      expect { new_minter(p8_pem: rsa_pem) }
        .to raise_error(ArgumentError, /EC private key/)
    end
  end

  def pad(b64url)
    b64url + ('=' * ((4 - (b64url.length % 4)) % 4))
  end
end
