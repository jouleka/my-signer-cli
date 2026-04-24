# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'digest'
require 'tempfile'
require 'mysigner/upload/asc_rest_uploader'

RSpec.describe Mysigner::Upload::AscRestUploader do
  let(:client) do
    instance_double('Mysigner::Client').tap do |c|
      allow(c).to receive(:post).and_return({ data: {
                                              'build_upload_id' => 1,
                                              'upload_operations' => [
                                                { 'method' => 'PUT', 'url' => 'https://s3.example/chunk1',
                                                  'offset' => 0, 'length' => 5, 'requestHeaders' => [] }
                                              ]
                                            } })
      allow(c).to receive(:patch).and_return({ data: { 'state' => 'uploaded', 'apple_state' => 'PROCESSING' } })
      allow(c).to receive(:get).and_return({ data: { 'apple_state' => 'COMPLETE' } })
    end
  end

  let(:ipa) do
    Tempfile.new(['test', '.ipa']).tap do |f|
      f.write('hello')
      f.close
    end
  end

  it 'drives the full upload flow and reports COMPLETE' do
    stub_request(:put, 'https://s3.example/chunk1').to_return(status: 200)
    uploader = described_class.new(
      client: client, organization_id: 1, ipa_path: ipa.path,
      apple_app_id: 42, cf_bundle_version: '1', cf_bundle_short_version_string: '1.0',
      platform: 'IOS'
    )
    result = uploader.call
    expect(result[:final_state]).to eq('COMPLETE')
    expect(a_request(:put, 'https://s3.example/chunk1').with(body: 'hello')).to have_been_made.once
  end
end
