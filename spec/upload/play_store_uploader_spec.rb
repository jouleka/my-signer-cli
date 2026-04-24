# frozen_string_literal: true

require 'spec_helper'
require 'google/apis/androidpublisher_v3'
require 'mysigner/upload/play_store_uploader'

RSpec.describe Mysigner::Upload::PlayStoreUploader do
  let(:aab_path) { '/tmp/fixtures/app-release.aab' }
  let(:package_name) { 'com.example.app' }
  let(:access_token) { 'ya29.FAKE_TOKEN_FOR_TESTS' }
  let(:service) do
    instance_double(
      Google::Apis::AndroidpublisherV3::AndroidPublisherService,
      :authorization= => nil,
      :client_options => instance_double('ClientOptions', :open_timeout_sec= => nil, :read_timeout_sec= => nil),
      :request_options => instance_double('RequestOptions', :retries= => nil)
    )
  end

  before do
    allow(File).to receive(:exist?).with(aab_path).and_return(true)
    allow(File).to receive(:size).with(aab_path).and_return(50_000_000)
    allow(Google::Apis::AndroidpublisherV3::AndroidPublisherService).to receive(:new).and_return(service)
  end

  describe '#initialize' do
    it 'assigns the bare access_token string to service.authorization' do
      expect(service).to receive(:authorization=).with(access_token)

      described_class.new(
        aab_path: aab_path,
        access_token: access_token,
        package_name: package_name
      )
    end

    it 'raises CredentialsError when access_token is nil' do
      expect do
        described_class.new(
          aab_path: aab_path,
          access_token: nil,
          package_name: package_name
        )
      end.to raise_error(Mysigner::Upload::PlayStoreUploader::CredentialsError, /access_token is required/i)
    end

    it 'raises CredentialsError when access_token is an empty string' do
      expect do
        described_class.new(
          aab_path: aab_path,
          access_token: '',
          package_name: package_name
        )
      end.to raise_error(Mysigner::Upload::PlayStoreUploader::CredentialsError, /access_token is required/i)
    end

    it 'does not accept legacy service_account_json keyword' do
      expect do
        described_class.new(
          aab_path: aab_path,
          service_account_json: '{"type":"service_account"}',
          package_name: package_name
        )
      end.to raise_error(ArgumentError)
    end
  end
end
