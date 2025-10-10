require 'spec_helper'
require 'mysigner/cli'
require 'mysigner/config'
require 'mysigner/client'
require 'open3'
require 'stringio'

RSpec.describe 'mysigner onboard' do
  let(:cli) { Mysigner::CLI.new }
  let(:exe_path) { File.expand_path('../../exe/mysigner', __dir__) }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'http://test.example.com' }
  let(:api_token) { 'test_token_123' }

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(Mysigner::Client).to receive(:new).and_return(client)
    allow(config).to receive(:save)
  end

  describe 'successful setup - user has everything' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      # User has account
      allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('1', '1')
      # User has token
      allow(cli).to receive(:yes?).with(/Have you generated/).and_return(true)
      # Provide token
      allow(cli).to receive(:ask).with("Paste your API Token:", echo: false).and_return(api_token)
      # Success responses
      allow(client).to receive(:test_connection).and_return({ success: true })
      allow(client).to receive(:get).with('/api/v1/organizations').and_return({
        data: { 'organizations' => [{ 'id' => '1', 'name' => 'Test Org' }] }
      })
      allow(config).to receive(:api_url=)
      allow(config).to receive(:api_token=)
      allow(config).to receive(:organization_id=)
    end

    it 'shows welcome message' do
      expect { cli.onboard }.to output(/Welcome/).to_stdout
    end

    it 'asks about account' do
      expect { cli.onboard }.to output(/Do you have a My Signer account/).to_stdout
    end

    it 'asks about organization' do
      expect { cli.onboard }.to output(/Do you have an organization/).to_stdout
    end

    it 'shows token generation step' do
      output = capture_stdout { cli.onboard }
      expect(output).to include('Generate API Token')
      expect(output).to include('Create Token')
    end

    it 'tests connection' do
      expect(client).to receive(:test_connection)
      cli.onboard
    end

    it 'fetches organizations' do
      expect(client).to receive(:get).with('/api/v1/organizations')
      cli.onboard
    end

    it 'saves configuration' do
      expect(config).to receive(:api_url=).with(api_url)
      expect(config).to receive(:api_token=).with(api_token)
      expect(config).to receive(:organization_id=).with('1')
      expect(config).to receive(:save)
      cli.onboard
    end

    it 'shows success message' do
      expect { cli.onboard }.to output(/Setup Complete/).to_stdout
    end

    it 'shows organization name' do
      expect { cli.onboard }.to output(/Test Org/).to_stdout
    end

    it 'shows next steps' do
      expect { cli.onboard }.to output(/mysigner ship testflight/).to_stdout
    end
  end

  describe 'user needs to create account' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
    end

    context 'user confirms account created' do
      before do
        # User needs account (first ask call)
        allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('2', '1')
        # Confirms account created
        allow(cli).to receive(:yes?).with(/Have you created your account/).and_return(true)
        # Has token
        allow(cli).to receive(:yes?).with(/Have you generated/).and_return(true)
        allow(cli).to receive(:ask).with("Paste your API Token:", echo: false).and_return(api_token)
        allow(client).to receive(:test_connection).and_return({ success: true })
        allow(client).to receive(:get).with('/api/v1/organizations').and_return({
          data: { 'organizations' => [{ 'id' => '1', 'name' => 'Test Org' }] }
        })
        allow(config).to receive(:api_url=)
        allow(config).to receive(:api_token=)
        allow(config).to receive(:organization_id=)
      end

      it 'shows signup guidance' do
        expect { cli.onboard }.to output(/Let's create your account/).to_stdout
      end

      it 'shows signup steps' do
        expect { cli.onboard }.to output(/Click 'Sign Up'/).to_stdout
      end

      it 'continues to next step' do
        expect { cli.onboard }.to output(/Organization Setup/).to_stdout
      end
    end

    context 'user has not created account' do
      before do
        # User needs account
        allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('2')
        allow(cli).to receive(:yes?).with(/Have you created your account/).and_return(false)
      end

      it 'shows signup guidance' do
        expect { cli.onboard }.to output(/Let's create your account/).to_stdout
      end

      it 'exits early' do
        expect { cli.onboard }.to output(/Come back and run/).to_stdout
      end

      it 'does not save config' do
        expect(config).not_to receive(:save)
        cli.onboard
      end
    end
  end

  describe 'user needs to create organization' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
    end

    context 'user confirms organization created' do
      before do
        # Has account, needs org
        allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('1', '2')
        allow(cli).to receive(:yes?).with(/Have you created your organization/).and_return(true)
        # Has token
        allow(cli).to receive(:yes?).with(/Have you generated/).and_return(true)
        allow(cli).to receive(:ask).with("Paste your API Token:", echo: false).and_return(api_token)
        allow(client).to receive(:test_connection).and_return({ success: true })
        allow(client).to receive(:get).with('/api/v1/organizations').and_return({
          data: { 'organizations' => [{ 'id' => '1', 'name' => 'Test Org' }] }
        })
        allow(config).to receive(:api_url=)
        allow(config).to receive(:api_token=)
        allow(config).to receive(:organization_id=)
      end

      it 'shows organization guidance' do
        expect { cli.onboard }.to output(/Let's create your organization/).to_stdout
      end

      it 'shows organization steps' do
        expect { cli.onboard }.to output(/Click 'Create Organization'/).to_stdout
      end

      it 'continues to next step' do
        expect { cli.onboard }.to output(/Generate API Token/).to_stdout
      end
    end

    context 'user has not created organization' do
      before do
        # Has account, needs org
        allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('1', '2')
        allow(cli).to receive(:yes?).with(/Have you created your organization/).and_return(false)
      end

      it 'shows organization guidance' do
        expect { cli.onboard }.to output(/Let's create your organization/).to_stdout
      end

      it 'exits early' do
        expect { cli.onboard }.to output(/Come back and run/).to_stdout
      end

      it 'does not save config' do
        expect(config).not_to receive(:save)
        cli.onboard
      end
    end
  end

  describe 'user does not have token yet' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      # Has account and org
      allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('1', '1')
      # No token yet
      allow(cli).to receive(:yes?).with(/Have you generated/).and_return(false)
    end

    it 'shows token generation guidance' do
      expect { cli.onboard }.to output(/Generate API Token/).to_stdout
      expect { cli.onboard }.to output(/Click 'Create Token'/).to_stdout
    end

    it 'exits early' do
      expect { cli.onboard }.to output(/Come back and run/).to_stdout
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'error handling - empty token' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('1', '1')
      allow(cli).to receive(:yes?).with(/Have you generated/).and_return(true)
      allow(cli).to receive(:ask).with("Paste your API Token:", echo: false).and_return('')
      allow(cli).to receive(:error)
    end

    it 'shows error message' do
      expect(cli).to receive(:error).with("Token cannot be empty")
      cli.onboard
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end

    it 'suggests running setup again' do
      expect { cli.onboard }.to output(/Run 'mysigner onboard' again/).to_stdout
    end
  end

  describe 'error handling - invalid token' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('1', '1')
      allow(cli).to receive(:yes?).with(/Have you generated/).and_return(true)
      allow(cli).to receive(:ask).with("Paste your API Token:", echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_raise(Mysigner::UnauthorizedError)
      allow(cli).to receive(:error)
    end

    it 'shows invalid token error' do
      expect(cli).to receive(:error).with("Invalid token")
      cli.onboard
    end

    it 'shows helpful guidance' do
      expect { cli.onboard }.to output(/The token you entered is invalid/).to_stdout
      expect { cli.onboard }.to output(/Make sure the token hasn't been revoked/).to_stdout
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'error handling - connection test fails' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('1', '1')
      allow(cli).to receive(:yes?).with(/Have you generated/).and_return(true)
      allow(cli).to receive(:ask).with("Paste your API Token:", echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_return({ success: false })
      allow(cli).to receive(:error)
    end

    it 'shows connection error' do
      expect(cli).to receive(:error).with("Connection test failed")
      cli.onboard
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'error handling - no organizations' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('1', '1')
      allow(cli).to receive(:yes?).with(/Have you generated/).and_return(true)
      allow(cli).to receive(:ask).with("Paste your API Token:", echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_return({ success: true })
      allow(client).to receive(:get).with('/api/v1/organizations').and_return({
        data: { 'organizations' => [] }
      })
      allow(cli).to receive(:error)
    end

    it 'shows no organizations error' do
      expect(cli).to receive(:error).with("No organizations found")
      cli.onboard
    end

    it 'shows helpful guidance' do
      expect { cli.onboard }.to output(/check that your token is associated/).to_stdout
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'error handling - unexpected error' do
    before do
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:ask).with("Select (1-2):", limited_to: ['1', '2']).and_return('1', '1')
      allow(cli).to receive(:yes?).with(/Have you generated/).and_return(true)
      allow(cli).to receive(:ask).with("Paste your API Token:", echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_raise(StandardError, "Network error")
      allow(cli).to receive(:error)
    end

    it 'shows setup failed error' do
      expect(cli).to receive(:error).with(/Setup failed/)
      cli.onboard
    end

    it 'suggests running setup again' do
      expect { cli.onboard }.to output(/Run 'mysigner onboard' to try again/).to_stdout
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.onboard
    end
  end

  describe 'help text' do
    it 'has description' do
      command = Mysigner::CLI.commands['onboard']
      expect(command.description).to include('Interactive onboarding guide')
    end

    it 'has long description' do
      command = Mysigner::CLI.commands['onboard']
      long_desc = command.long_description
      expect(long_desc).to include('Step-by-step')
      expect(long_desc).to include('organization')
      expect(long_desc).to include('API token')
    end
  end

  describe 'integration tests' do
    it 'shows help for onboard command' do
      stdout, _, status = Open3.capture3("#{exe_path} help onboard 2>&1")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('Usage:')
      expect(stdout).to include('mysigner onboard')
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

