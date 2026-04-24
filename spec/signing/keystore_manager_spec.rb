# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/signing/keystore_manager'

RSpec.describe Mysigner::Signing::KeystoreManager do
  let(:client) { instance_double(Mysigner::Client) }
  let(:org_id) { 42 }
  subject(:manager) { described_class.new(client, org_id) }

  describe '#fetch_secrets' do
    let(:keystore_id) { 7 }
    let(:secrets_response) do
      {
        data: {
          'keystore_password' => 'sekret-store',
          'key_password' => 'sekret-key',
          'key_alias' => 'upload'
        }
      }
    end

    before do
      allow(client).to receive(:post).with(
        "/api/v1/organizations/#{org_id}/android_keystores/#{keystore_id}/secrets"
      ).and_return(secrets_response)
    end

    it 'POSTs to the dedicated /secrets endpoint' do
      expect(client).to receive(:post).with(
        "/api/v1/organizations/#{org_id}/android_keystores/#{keystore_id}/secrets"
      ).and_return(secrets_response)
      manager.fetch_secrets(keystore_id)
    end

    it 'returns a hash with the expected secret keys' do
      secrets = manager.fetch_secrets(keystore_id)
      expect(secrets).to eq(
        'keystore_password' => 'sekret-store',
        'key_password' => 'sekret-key',
        'key_alias' => 'upload'
      )
    end
  end

  describe '#list' do
    let(:list_response) do
      { data: { 'android_keystores' => [{ 'id' => 1, 'active' => true }] } }
    end

    it 'does not pass include_secrets even if provided (deprecated)' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/android_keystores",
        params: {}
      ).and_return(list_response)
      manager.list(include_secrets: true)
    end

    it 'filters by android_app_id when given' do
      expect(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/android_keystores",
        params: { android_app_id: 99 }
      ).and_return(list_response)
      manager.list(android_app_id: 99)
    end
  end

  describe '#active_keystore' do
    let(:keystores) do
      [
        { 'id' => 1, 'active' => false },
        { 'id' => 2, 'active' => true, 'name' => 'Release' }
      ]
    end

    before do
      allow(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/android_keystores",
        params: {}
      ).and_return({ data: { 'android_keystores' => keystores } })
    end

    it 'returns the first keystore flagged active' do
      expect(manager.active_keystore).to eq(keystores[1])
    end

    it 'silently ignores a legacy include_secrets keyword arg' do
      expect { manager.active_keystore(include_secrets: true) }.not_to raise_error
    end
  end

  describe '#get_or_download TTL' do
    let(:keystore_id) { 3 }
    let(:keystore) { { 'id' => 3, 'name' => 'Release', 'key_alias' => 'upload' } }
    let(:filename) { 'Release.jks' }
    let(:local_path) { File.join(Mysigner::Signing::KeystoreManager::KEYSTORES_DIR, filename) }
    let(:downloaded_result) do
      { path: local_path, name: 'Release', key_alias: 'upload', id: 3 }
    end

    before do
      allow(client).to receive(:get).with(
        "/api/v1/organizations/#{org_id}/android_keystores",
        params: {}
      ).and_return({ data: { 'android_keystores' => [keystore] } })
    end

    it 're-downloads when cached file is older than max_age_hours' do
      stale_mtime = Time.now - ((24 * 3600) + 60) # 24h + 1min old
      allow(File).to receive(:exist?).with(local_path).and_return(true)
      allow(File).to receive(:mtime).with(local_path).and_return(stale_mtime)
      expect(File).to receive(:delete).with(local_path)
      expect(manager).to receive(:download).with(keystore_id).and_return(downloaded_result)

      result = manager.get_or_download(keystore_id)
      expect(result[:cached]).to eq(false)
    end

    it 'uses cached file when within TTL' do
      fresh_mtime = Time.now - 3600 # 1 hour old
      allow(File).to receive(:exist?).with(local_path).and_return(true)
      allow(File).to receive(:mtime).with(local_path).and_return(fresh_mtime)
      expect(File).not_to receive(:delete).with(local_path)
      expect(manager).not_to receive(:download)

      result = manager.get_or_download(keystore_id)
      expect(result[:cached]).to eq(true)
      expect(result[:path]).to eq(local_path)
    end

    it 'respects MYSIGNER_KEYSTORE_CACHE_HOURS override' do
      one_hour_old = Time.now - 3600
      allow(File).to receive(:exist?).with(local_path).and_return(true)
      allow(File).to receive(:mtime).with(local_path).and_return(one_hour_old)

      # With TTL of 0 (effectively always stale), re-download is required.
      original_ttl = ENV.fetch('MYSIGNER_KEYSTORE_CACHE_HOURS', nil)
      ENV['MYSIGNER_KEYSTORE_CACHE_HOURS'] = '0'
      begin
        expect(File).to receive(:delete).with(local_path)
        expect(manager).to receive(:download).with(keystore_id).and_return(downloaded_result)
        manager.get_or_download(keystore_id)
      ensure
        ENV['MYSIGNER_KEYSTORE_CACHE_HOURS'] = original_ttl
      end
    end
  end
end
