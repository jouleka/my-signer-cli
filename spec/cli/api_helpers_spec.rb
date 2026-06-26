# frozen_string_literal: true

require 'spec_helper'

# Transport-security hardening for the API URL helpers: a scheme-less host
# must default to https (not http), and a plain-http URL is only acceptable
# for a loopback dev host — never a remote server the API token would be
# sent to in cleartext.
RSpec.describe Mysigner::CLI do
  subject(:cli) { described_class.new([], {}, {}) }

  describe '#normalize_api_url' do
    it 'adds https:// to a scheme-less non-loopback host' do
      expect(cli.send(:normalize_api_url, 'api.example.com')).to eq('https://api.example.com')
    end

    it 'adds http:// to a scheme-less loopback host (local dev)' do
      expect(cli.send(:normalize_api_url, 'localhost:3000')).to eq('http://localhost:3000')
    end

    it 'leaves an explicit https URL unchanged (minus trailing slash)' do
      expect(cli.send(:normalize_api_url, 'https://x.example.com/')).to eq('https://x.example.com')
    end
  end

  describe '#valid_api_url?' do
    it 'rejects plain http to a non-loopback host' do
      expect(cli.send(:valid_api_url?, 'http://api.evil.example')).to be false
    end

    it 'accepts https to any host' do
      expect(cli.send(:valid_api_url?, 'https://x.example.com')).to be true
    end

    it 'accepts http to localhost (local dev)' do
      expect(cli.send(:valid_api_url?, 'http://localhost:3000')).to be true
    end

    it 'accepts http to a loopback IP' do
      expect(cli.send(:valid_api_url?, 'http://127.0.0.1:8080')).to be true
    end
  end
end
