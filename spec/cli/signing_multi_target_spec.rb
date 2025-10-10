require 'spec_helper'
require 'mysigner/cli'

RSpec.describe 'CLI Multi-Target Signing', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { double('Config', api_token: 'test_token', organization_id: 'org-123', user_email: 'test@example.com') }
  let(:client) { double('Client') }
  
  let(:project_info) do
    {
      path: '/path/to/project.xcodeproj',
      type: :project,
      directory: '/path/to',
      framework: :native
    }
  end
  
  let(:project_double) { double('Project', save: true, targets: targets) }
  
  let(:main_target) do
    double('Target',
      name: 'MyApp',
      product_type: 'com.apple.product-type.application',
      sdk: 'iphoneos',
      build_configurations: [double('Config', name: 'Release', build_settings: {
        'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.app',
        'DEVELOPMENT_TEAM' => 'ABCD123456',
        'CODE_SIGN_STYLE' => 'Manual',
        'CODE_SIGN_IDENTITY' => 'Apple Distribution',
        'PROVISIONING_PROFILE_SPECIFIER' => 'MyProfile',
        'PRODUCT_NAME' => 'MyApp'
      })]
    )
  end
  
  let(:widget_target) do
    double('Target',
      name: 'MyWidget',
      product_type: 'com.apple.product-type.app-extension',
      sdk: 'iphoneos',
      build_configurations: [double('Config', name: 'Release', build_settings: {
        'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.app.widget',
        'DEVELOPMENT_TEAM' => 'ABCD123456',
        'CODE_SIGN_STYLE' => 'Manual',
        'CODE_SIGN_IDENTITY' => 'Apple Distribution',
        'PROVISIONING_PROFILE_SPECIFIER' => 'WidgetProfile',
        'PRODUCT_NAME' => 'MyWidget'
      })]
    )
  end
  
  let(:parser_double) do
    parser = double('Parser')
    allow(parser).to receive(:project).and_return(project_double)
    allow(parser).to receive(:signable_targets).and_return([])
    allow(parser).to receive(:app_targets).and_return(targets)
    allow(parser).to receive(:main_target).and_return(targets.first)
    parser
  end
  
  before do
    allow(cli).to receive(:config).and_return(config)
    allow(cli).to receive(:load_config).and_return(config)
    allow(cli).to receive(:create_client).and_return(client)
    allow(cli).to receive(:say)
    allow(cli).to receive(:error)
    allow(cli).to receive(:exit).and_call_original
    
    allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
    allow(Mysigner::Build::Parser).to receive(:new).and_return(parser_double)
  end
  
  describe 'mysigner signing configure' do
    before do
      allow(STDIN).to receive(:gets).and_return("1\n", "1\n", "y\n")
    end
    
    context 'with --target option' do
      let(:targets) { [main_target, widget_target] }
      
      it 'shows help for --target option' do
        expect { cli.help(:signing) }.to output(/--target NAME/).to_stdout
      end
      
      it 'validates target option' do
        cli.options = { target: 'NonExistentTarget' }
        
        allow(parser_double).to receive(:find_target).with('NonExistentTarget').and_raise("Target not found")
        
        # The wizard will handle the error gracefully by printing error and returning
        # Just verify it doesn't crash
        expect { cli.signing('setup') }.not_to raise_error
      end
    end
    
    context 'with --all-targets option' do
      let(:targets) { [main_target, widget_target] }
      
      it 'shows help for --all-targets option' do
        expect { cli.help(:signing) }.to output(/--all-targets/).to_stdout
      end
      
      it 'prevents using both --target and --all-targets' do
        cli.options = { target: 'MyApp', all_targets: true }
        
        expect(cli).to receive(:error).with("Cannot use both --target and --all-targets")
        expect(cli).to receive(:exit).with(1)
        
        cli.signing('setup')
      end
    end
  end
end

