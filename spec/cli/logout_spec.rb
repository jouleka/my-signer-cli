# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'mysigner/config'
require 'open3'
require 'stringio'

RSpec.describe 'mysigner logout' do
  let(:cli) { Mysigner::CLI.new }
  let(:exe_path) { File.expand_path('../../exe/mysigner', __dir__) }
  let(:config) { instance_double(Mysigner::Config) }

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
  end

  describe 'when logged in' do
    before do
      allow(config).to receive(:exists?).and_return(true)
    end

    context 'user confirms logout' do
      before do
        allow(cli).to receive(:yes?).and_return(true)
        allow(config).to receive(:clear)
      end

      it 'prompts for confirmation' do
        expect(cli).to receive(:yes?).with(/Are you sure/)
        cli.logout
      end

      it 'clears config' do
        expect(config).to receive(:clear)
        cli.logout
      end

      it 'shows success message' do
        expect { cli.logout }.to output(/Successfully logged out/).to_stdout
      end

      it 'shows config file location' do
        expect { cli.logout }.to output(/Config file removed/).to_stdout
        expect { cli.logout }.to output(/#{Regexp.escape(Mysigner::Config::CONFIG_FILE)}/).to_stdout
      end

      it 'does not show cancelled message' do
        output = capture_stdout { cli.logout }
        expect(output).not_to match(/cancelled/)
      end
    end

    context 'user cancels logout' do
      before do
        allow(cli).to receive(:yes?).and_return(false)
      end

      it 'prompts for confirmation' do
        expect(cli).to receive(:yes?).with(/Are you sure/)
        cli.logout
      end

      it 'does not clear config' do
        expect(config).not_to receive(:clear)
        cli.logout
      end

      it 'shows cancelled message' do
        expect { cli.logout }.to output(/Logout cancelled/).to_stdout
      end

      it 'does not show success message' do
        output = capture_stdout { cli.logout }
        expect(output).not_to match(/Successfully logged out/)
      end
    end
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
    end

    it 'shows no credentials message' do
      expect { cli.logout }.to output(/No stored credentials found/).to_stdout
    end

    it 'does not prompt for confirmation' do
      expect(cli).not_to receive(:yes?)
      cli.logout
    end

    it 'does not clear config' do
      expect(config).not_to receive(:clear)
      cli.logout
    end

    it 'returns gracefully' do
      expect { cli.logout }.not_to raise_error
    end
  end

  describe 'help text' do
    it 'has description' do
      command = Mysigner::CLI.commands['logout']
      expect(command.description).to eq('Log out and clear stored credentials')
    end

    it 'is listed in help' do
      help_output = capture_stdout { Mysigner::CLI.start(['help']) }
      expect(help_output).to include('logout')
    end

    it 'documents --purge / --no-purge in long_desc' do
      command = Mysigner::CLI.commands['logout']
      long = command.long_description.to_s
      expect(long).to include('--purge')
      expect(long).to include('--no-purge')
    end
  end

  # mysigner-47 — purge flow. Verifies the WHY: a `mysigner logout --purge`
  # must (1) call the server's DELETE /credentials endpoint with the
  # current org's API token + email, (2) wipe local Keychain entries
  # across all four LocalCredentials kinds, and (3) STILL clear local
  # config at the end. The non-purge path must NOT touch either store.
  describe 'with --purge / --no-purge flags' do
    let(:client) { instance_double(Mysigner::Client) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      # `yes?` here is the top-level "Are you sure you want to logout?"
      # gate, NOT the purge prompt. Tests pin yes? to true to ensure the
      # logout proceeds; the purge prompt is bypassed by the explicit flag.
      allow(cli).to receive(:yes?).and_return(true)
      allow(config).to receive(:clear)
    end

    context 'when --no-purge is passed' do
      before { cli.options = { purge: false } }

      it 'never loads config' do
        expect(config).not_to receive(:load)
        cli.logout
      end

      it 'never builds a Mysigner::Client' do
        expect(Mysigner::Client).not_to receive(:new)
        cli.logout
      end

      it 'never touches LocalCredentials' do
        expect(Mysigner::LocalCredentials).not_to receive(:list)
        expect(Mysigner::LocalCredentials).not_to receive(:delete)
        cli.logout
      end

      it 'still clears local config' do
        expect(config).to receive(:clear)
        cli.logout
      end
    end

    context 'when --purge is passed' do
      before do
        cli.options = { purge: true }
        allow(config).to receive(:load).and_return(true)
        allow(config).to receive(:api_url).and_return('https://mysigner.dev')
        allow(config).to receive(:api_token).and_return('test-token')
        allow(config).to receive(:user_email).and_return('owner@example.com')
        allow(config).to receive(:current_organization_id).and_return(42)
        allow(Mysigner::Client).to receive(:new).and_return(client)
        # Default success response; per-example overrides where needed.
        allow(client).to receive(:delete).and_return(
          success: true,
          status: 200,
          data: { 'deleted' => { 'asc' => 2, 'apple_ads' => 1, 'google_play' => 3, 'android_keystore' => 1 } },
          headers: {}
        )
        # No local creds by default; per-example overrides.
        allow(Mysigner::LocalCredentials).to receive(:list).and_return([])
      end

      it 'calls DELETE /api/v1/organizations/<org>/credentials with org id from config' do
        expect(client).to receive(:delete).with('/api/v1/organizations/42/credentials')
        cli.logout
      end

      it 'builds the client with api_url, api_token, and user_email from config' do
        expect(Mysigner::Client).to receive(:new).with(
          api_url: 'https://mysigner.dev',
          api_token: 'test-token',
          user_email: 'owner@example.com'
        ).and_return(client)
        cli.logout
      end

      it 'prints the per-kind delete counts from the server response' do
        output = capture_stdout { cli.logout }
        expect(output).to include('App Store Connect: 2')
        expect(output).to include('Apple Search Ads:  1')
        expect(output).to include('Google Play:       3')
        expect(output).to include('Android keystore:  1')
      end

      it 'wipes every LocalCredentials entry across all four kinds' do
        # Each kind has one entry to delete.
        Mysigner::LocalCredentials::KINDS.each do |kind|
          allow(Mysigner::LocalCredentials).to receive(:list).with(kind: kind).and_return(["#{kind}-id-1"])
          expect(Mysigner::LocalCredentials).to receive(:delete).with(kind: kind, id: "#{kind}-id-1")
        end
        cli.logout
      end

      it 'still clears local config after the purge succeeds' do
        expect(config).to receive(:clear)
        cli.logout
      end

      it 'aborts WITHOUT clearing local config when the server purge fails' do
        allow(client).to receive(:delete).and_raise(Mysigner::ConnectionError.new('boom'))
        expect(config).not_to receive(:clear)
        expect { cli.logout }.to raise_error(SystemExit)
      end

      it 'skips the server call when current_organization_id is nil' do
        allow(config).to receive(:current_organization_id).and_return(nil)
        expect(Mysigner::Client).not_to receive(:new)
        cli.logout
      end
    end

    context 'when neither flag is passed (interactive mode)' do
      before do
        cli.options = {}
        # Non-TTY path of no_default_yes? returns false → no purge.
        allow($stdin).to receive(:tty?).and_return(false)
      end

      it 'defaults to NO purge in non-TTY context' do
        expect(Mysigner::Client).not_to receive(:new)
        expect(Mysigner::LocalCredentials).not_to receive(:list)
        cli.logout
      end

      it 'still clears local config' do
        expect(config).to receive(:clear)
        cli.logout
      end
    end
  end

  describe 'integration tests', :integration do
    it 'runs successfully when logged in' do
      # Can't easily test interactive prompt in integration, but verify command exists
      stdout, _, status = Open3.capture3("#{exe_path} help logout 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('logout')
    end

    it 'shows help for logout command' do
      stdout, _, status = Open3.capture3("#{exe_path} help logout 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner logout')
    end
  end

  # Helper method
  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end
end
