# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'mysigner/config'
require 'mysigner/client'
require 'stringio'

RSpec.describe 'mysigner login' do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'http://test.example.com' }
  let(:api_token) { 'test_token_123' }

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(Mysigner::Client).to receive(:new).and_return(client)
    allow(config).to receive(:save)
  end

  describe 'successful login flow' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:show_token_guidance)
      allow(cli).to receive(:ask).with('API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_return({ success: true })
      allow(client).to receive(:get).with('/api/v1/organizations').and_return({
                                                                                data: {
                                                                                  'organizations' => [
                                                                                    { 'id' => '1',
                                                                                      'name' => 'Test Organization' }
                                                                                  ]
                                                                                }
                                                                              })
      allow(config).to receive(:api_url=)
      allow(config).to receive(:api_token=)
      allow(config).to receive(:organization_id=)
    end

    it 'prompts for API URL' do
      expect(cli).to receive(:prompt_api_url).and_return(api_url)
      cli.login
    end

    it 'shows token guidance' do
      expect(cli).to receive(:show_token_guidance).with(api_url)
      cli.login
    end

    it 'prompts for API token with hidden input' do
      expect(cli).to receive(:ask).with('API Token:', echo: false).and_return(api_token)
      cli.login
    end

    it 'tests connection with provided credentials' do
      expect(client).to receive(:test_connection)
      cli.login
    end

    it 'fetches organizations' do
      expect(client).to receive(:get).with('/api/v1/organizations')
      cli.login
    end

    it 'saves configuration' do
      expect(config).to receive(:api_url=).with(api_url)
      expect(config).to receive(:api_token=).with(api_token)
      expect(config).to receive(:organization_id=).with('1')
      expect(config).to receive(:save)
      cli.login
    end

    it 'shows success message' do
      expect { cli.login }.to output(/Successfully logged in/).to_stdout
    end

    it 'shows organization name' do
      expect { cli.login }.to output(/Test Organization/).to_stdout
    end

    it 'shows config file location' do
      expect { cli.login }.to output(/Config saved to/).to_stdout
    end

    it 'shows next steps' do
      expect { cli.login }.to output(/Next steps/).to_stdout
      expect { cli.login }.to output(/mysigner ship testflight/).to_stdout
    end

    it 'suggests running doctor' do
      expect { cli.login }.to output(/mysigner doctor/).to_stdout
    end
  end

  describe 'when already logged in' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:organization_id).and_return('1')
      allow(config).to receive(:api_url).and_return(api_url)
    end

    context 'user chooses to re-login' do
      before do
        allow(cli).to receive(:yes?).and_return(true)
        allow(config).to receive(:clear)
        allow(cli).to receive(:prompt_api_url).and_return(api_url)
        allow(cli).to receive(:show_token_guidance)
        allow(cli).to receive(:ask).with('API Token:', echo: false).and_return(api_token)
        allow(client).to receive(:test_connection).and_return({ success: true })
        allow(client).to receive(:get).with('/api/v1/organizations').and_return({
                                                                                  data: {
                                                                                    'organizations' => [
                                                                                      { 'id' => '1',
                                                                                        'name' => 'Test Organization' }
                                                                                    ]
                                                                                  }
                                                                                })
        allow(config).to receive(:api_url=)
        allow(config).to receive(:api_token=)
        allow(config).to receive(:organization_id=)
      end

      it 'shows already logged in warning' do
        expect { cli.login }.to output(/Already logged in/).to_stdout
      end

      it 'shows current configuration' do
        expect { cli.login }.to output(/Current configuration/).to_stdout
        expect { cli.login }.to output(/Organization ID/).to_stdout
      end

      it 'prompts for confirmation' do
        expect(cli).to receive(:yes?).with(/logout and login/)
        cli.login
      end

      it 'clears old config' do
        expect(config).to receive(:clear)
        cli.login
      end

      it 'shows logout success' do
        expect { cli.login }.to output(/Logged out successfully/).to_stdout
      end

      it 'proceeds with login' do
        expect { cli.login }.to output(/Successfully logged in/).to_stdout
      end
    end

    context 'user cancels re-login' do
      before do
        allow(cli).to receive(:yes?).and_return(false)
      end

      it 'shows cancel message' do
        expect { cli.login }.to output(/Login cancelled/).to_stdout
      end

      it 'suggests logout command' do
        expect { cli.login }.to output(/mysigner logout/).to_stdout
      end

      it 'does not proceed with login' do
        output = capture_stdout { cli.login }
        expect(output).not_to match(/Testing connection/)
      end

      it 'does not clear config' do
        expect(config).not_to receive(:clear)
        cli.login
      end
    end
  end

  describe 'error handling - empty token' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:show_token_guidance)
      allow(cli).to receive(:ask).with('API Token:', echo: false).and_return('')
      allow(cli).to receive(:error)
      allow(cli).to receive(:exit) # Stub but don't raise - code continues
    end

    it 'shows error message' do
      # Stub methods called after exit for this test
      allow(client).to receive(:test_connection)
      allow(client).to receive(:get)
      allow(config).to receive(:api_url=)
      allow(config).to receive(:api_token=)
      allow(config).to receive(:organization_id=)

      expect(cli).to receive(:error).with('API token cannot be empty')
      cli.login
    end

    it 'shows setup tip' do
      # Stub methods called after exit for this test
      allow(client).to receive(:test_connection)
      allow(client).to receive(:get)
      allow(config).to receive(:api_url=)
      allow(config).to receive(:api_token=)
      allow(config).to receive(:organization_id=)

      expect { cli.login }.to output(/mysigner onboard/).to_stdout
    end

    it 'exits with error code' do
      # Stub methods called after exit for this test
      allow(client).to receive(:test_connection)
      allow(client).to receive(:get)
      allow(config).to receive(:api_url=)
      allow(config).to receive(:api_token=)
      allow(config).to receive(:organization_id=)

      expect(cli).to receive(:exit).with(1)
      cli.login
    end
  end

  describe 'error handling - unauthorized (401)' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:show_token_guidance)
      allow(cli).to receive(:ask).with('API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_raise(Mysigner::UnauthorizedError)
      allow(cli).to receive(:handle_unauthorized_error)
      allow(cli).to receive(:exit)
    end

    it 'catches unauthorized error' do
      expect(cli).to receive(:handle_unauthorized_error).with(api_url)
      cli.login
    end

    it 'exits with error code' do
      expect(cli).to receive(:exit).with(1)
      cli.login
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.login
    end
  end

  describe 'error handling - connection error' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:show_token_guidance)
      allow(cli).to receive(:ask).with('API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_raise(Mysigner::ConnectionError.new('Network error'))
      allow(cli).to receive(:handle_connection_error)
      allow(cli).to receive(:exit)
    end

    it 'catches connection error' do
      expect(cli).to receive(:handle_connection_error)
      cli.login
    end

    it 'exits with error code' do
      expect(cli).to receive(:exit).with(1)
      cli.login
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.login
    end
  end

  describe 'error handling - connection test fails' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:show_token_guidance)
      allow(cli).to receive(:ask).with('API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_return({ success: false })
      allow(cli).to receive(:error)
      allow(cli).to receive(:handle_connection_failure)
      allow(cli).to receive(:exit)
      # Stub methods called after exit
      allow(client).to receive(:get)
      allow(config).to receive(:api_url=)
      allow(config).to receive(:api_token=)
      allow(config).to receive(:organization_id=)
    end

    it 'shows connection failed error' do
      expect(cli).to receive(:error).with('Connection failed')
      cli.login
    end

    it 'calls connection failure handler' do
      expect(cli).to receive(:handle_connection_failure).with(api_url)
      cli.login
    end

    it 'exits with error code' do
      expect(cli).to receive(:exit).with(1)
      cli.login
    end
  end

  describe 'error handling - no organizations found' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:show_token_guidance)
      allow(cli).to receive(:ask).with('API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_return({ success: true })
      allow(client).to receive(:get).with('/api/v1/organizations').and_return({
                                                                                data: { 'organizations' => [] }
                                                                              })
      allow(cli).to receive(:error)
      allow(cli).to receive(:show_create_org_guidance)
      allow(cli).to receive(:exit)
      # Stub methods called after exit
      allow(config).to receive(:api_url=)
      allow(config).to receive(:api_token=)
      allow(config).to receive(:organization_id=)
    end

    it 'shows no organizations error' do
      expect(cli).to receive(:error).with('No organizations found for this token')
      cli.login
    end

    it 'explains possible causes' do
      expect { cli.login }.to output(/This might mean/).to_stdout
      expect { cli.login }.to output(/doesn't have access/).to_stdout
    end

    it 'shows organization creation guidance' do
      expect(cli).to receive(:show_create_org_guidance).with(api_url)
      cli.login
    end

    it 'exits with error code' do
      expect(cli).to receive(:exit).with(1)
      cli.login
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.login
    end
  end

  describe 'error handling - unexpected error' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(cli).to receive(:prompt_api_url).and_return(api_url)
      allow(cli).to receive(:show_token_guidance)
      allow(cli).to receive(:ask).with('API Token:', echo: false).and_return(api_token)
      allow(client).to receive(:test_connection).and_raise(StandardError, 'Something went wrong')
      allow(cli).to receive(:handle_unexpected_error)
      allow(cli).to receive(:exit)
    end

    it 'catches unexpected errors' do
      expect(cli).to receive(:handle_unexpected_error)
      cli.login
    end

    it 'exits with error code' do
      expect(cli).to receive(:exit).with(1)
      cli.login
    end

    it 'does not save config' do
      expect(config).not_to receive(:save)
      cli.login
    end
  end

  describe 'help text' do
    it 'has description' do
      command = Mysigner::CLI.commands['login']
      expect(command.description).to include('Authenticate')
    end

    it 'has long description' do
      command = Mysigner::CLI.commands['login']
      long_desc = command.long_description
      expect(long_desc).to include('API token')
      expect(long_desc).to include('setup')
      expect(long_desc).to include('~/.mysigner/config.yml')
    end

    it 'mentions setup for new users' do
      command = Mysigner::CLI.commands['login']
      expect(command.long_description).to include('New user')
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
