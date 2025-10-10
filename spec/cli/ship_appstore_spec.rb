require 'spec_helper'
require 'mysigner/cli'
require 'mysigner/upload/app_store_submission'

RSpec.describe 'App Store Distribution', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) do
    double('Config', 
      api_token: 'test_token',
      organization_id: 'org-123',
      user_email: 'test@example.com'
    )
  end
  let(:client) { double('Client') }
  
  before do
    allow(cli).to receive(:config).and_return(config)
    allow(cli).to receive(:load_config).and_return(config)
    allow(cli).to receive(:create_client).and_return(client)
    allow(cli).to receive(:say)
    allow(cli).to receive(:error)
    allow(cli).to receive(:exit)
  end
  
  describe 'mysigner ship appstore' do
    it 'shows help for ship command' do
      expect { cli.help(:ship) }.to output(/appstore/).to_stdout
    end
    
    it 'includes appstore in valid targets' do
      expect { cli.help(:ship) }.to output(/testflight.*appstore/m).to_stdout
    end
    
    it 'shows --submit-for-review option' do
      expect { cli.help(:ship) }.to output(/--submit-for-review/).to_stdout
    end
    
    it 'accepts appstore as valid target' do
      cli.options = {}
      
      # Mock all the steps
      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
        path: '/path/to/project.xcodeproj',
        type: :project,
        directory: '/path/to',
        framework: :native
      })
      
      parser = double('Parser')
      allow(parser).to receive(:main_target).and_return(double(name: 'MyApp'))
      allow(parser).to receive(:bundle_id).and_return('com.example.app')
      allow(parser).to receive(:team_id).and_return('ABCD123456')
      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:code_sign_style).and_return('Automatic')
      allow(parser).to receive(:build_settings).and_return({
        'MARKETING_VERSION' => '1.0.0',
        'CURRENT_PROJECT_VERSION' => '1'
      })
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
      
      validator = double('Validator')
      allow(validator).to receive(:validate!)
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      
      executor = double('Executor')
      allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
      
      exporter = double('Exporter')
      allow(exporter).to receive(:export!).and_return('/path/to/app.ipa')
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)
      
      # Mock API responses
      allow(client).to receive(:get).with("/api/v1/organizations/org-123").and_return({
        data: {
          'app_store_connect_configured' => true,
          'app_store_connect_key_id' => 'KEY123',
          'app_store_connect_issuer_id' => 'ISSUER123',
          'app_store_connect_private_key' => 'PRIVATE_KEY',
          'app_store_connect_team_id' => 'TEAM123'
        }
      })
      
      uploader = double('Uploader')
      allow(uploader).to receive(:upload!)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)
      
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:size).and_return(10_000_000)
      
      # Should not raise error
      expect { cli.ship('appstore') }.not_to raise_error
    end
    
    it 'rejects invalid targets' do
      cli.options = {}
      
      expect(cli).to receive(:error).with(/Invalid target/)
      expect(cli).to receive(:exit).with(1)
      
      cli.ship('invalid')
    end
  end
  
  describe 'submission flow' do
    let(:parser) do
      double('Parser',
        main_target: double(name: 'MyApp'),
        bundle_id: 'com.example.app',
        team_id: 'ABCD123456',
        product_type: :app,
        has_extensions?: false,
        code_sign_style: 'Automatic',
        build_settings: {
          'MARKETING_VERSION' => '1.0.0',
          'CURRENT_PROJECT_VERSION' => '1'
        }
      )
    end
    
    before do
      cli.options = { submit_for_review: true }
      
      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
        path: '/path/to/project.xcodeproj',
        type: :project,
        directory: '/path/to',
        framework: :native
      })
      
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
      
      validator = double('Validator')
      allow(validator).to receive(:validate!)
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      
      executor = double('Executor')
      allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
      
      exporter = double('Exporter')
      allow(exporter).to receive(:export!).and_return('/path/to/app.ipa')
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)
      
      allow(client).to receive(:get).with("/api/v1/organizations/org-123").and_return({
        data: {
          'app_store_connect_configured' => true,
          'app_store_connect_key_id' => 'KEY123',
          'app_store_connect_issuer_id' => 'ISSUER123',
          'app_store_connect_private_key' => 'PRIVATE_KEY',
          'app_store_connect_team_id' => 'TEAM123'
        }
      })
      
      uploader = double('Uploader')
      allow(uploader).to receive(:upload!)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)
      
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:size).and_return(10_000_000)
    end
    
    it 'calls submission when --submit-for-review is passed' do
      submission = double('Submission')
      expect(submission).to receive(:submit_for_review!)
      allow(Mysigner::Upload::AppStoreSubmission).to receive(:new).and_return(submission)
      
      cli.ship('appstore')
    end
    
    it 'passes correct build info to submission' do
      expect(Mysigner::Upload::AppStoreSubmission).to receive(:new).with(
        client,
        'org-123',
        hash_including(
          bundle_id: 'com.example.app',
          version: '1.0.0',
          build_number: '1'
        )
      ).and_return(double('Submission', submit_for_review!: nil))
      
      cli.ship('appstore')
    end
    
    it 'skips submission when --submit-for-review is false' do
      cli.options = { submit_for_review: false }
      
      expect(Mysigner::Upload::AppStoreSubmission).not_to receive(:new)
      
      cli.ship('appstore')
    end
  end
  
  describe 'App Store messages' do
    before do
      cli.options = {}
      
      allow(Mysigner::Build::Detector).to receive(:detect).and_return({
        path: '/path/to/project.xcodeproj',
        type: :project,
        directory: '/path/to',
        framework: :native
      })
      
      parser = double('Parser')
      allow(parser).to receive(:main_target).and_return(double(name: 'MyApp'))
      allow(parser).to receive(:bundle_id).and_return('com.example.app')
      allow(parser).to receive(:team_id).and_return('ABCD123456')
      allow(parser).to receive(:product_type).and_return(:app)
      allow(parser).to receive(:has_extensions?).and_return(false)
      allow(parser).to receive(:code_sign_style).and_return('Automatic')
      allow(parser).to receive(:build_settings).and_return({})
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
      
      validator = double('Validator')
      allow(validator).to receive(:validate!)
      allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
      
      executor = double('Executor')
      allow(executor).to receive(:build!).and_return('/path/to/archive.xcarchive')
      allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
      
      exporter = double('Exporter')
      allow(exporter).to receive(:export!).and_return('/path/to/app.ipa')
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)
      
      allow(client).to receive(:get).and_return({
        data: {
          'app_store_connect_configured' => true,
          'app_store_connect_key_id' => 'KEY123',
          'app_store_connect_issuer_id' => 'ISSUER123',
          'app_store_connect_private_key' => 'PRIVATE_KEY'
        }
      })
      
      uploader = double('Uploader')
      allow(uploader).to receive(:upload!)
      allow(Mysigner::Upload::Uploader).to receive(:new).and_return(uploader)
      
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:size).and_return(10_000_000)
    end
    
    it 'shows App Store-specific messages' do
      expect(cli).to receive(:say).with(/Ship to App Store/, :cyan).at_least(:once)
      
      cli.ship('appstore')
    end
    
    it 'shows different next steps for App Store vs TestFlight' do
      expect(cli).to receive(:say).with(/Select this build for a new version/).at_least(:once)
      
      cli.ship('appstore')
    end
  end
end

