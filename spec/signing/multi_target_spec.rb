require 'spec_helper'
require 'mysigner/build/parser'
require 'mysigner/signing/wizard'

RSpec.describe 'Multi-Target Signing', type: :unit do
  let(:project_double) do
    double('Project', save: true, targets: targets)
  end
  
  let(:project_info) do
    { path: '/path/to/project.xcodeproj', type: :project, directory: '/path/to', framework: :native }
  end
  
  let(:parser) do
    parser = Mysigner::Build::Parser.allocate
    parser.instance_variable_set(:@project_info, project_info)
    parser.instance_variable_set(:@project, project_double)
    parser
  end
  
  let(:client) { double('Client') }
  let(:organization_id) { 'org-123' }
  
  # Mock targets
  let(:main_app_target) do
    double('Target',
      name: 'MyApp',
      product_type: 'com.apple.product-type.application',
      sdk: 'iphoneos',
      build_configurations: [main_app_config]
    )
  end
  
  let(:widget_target) do
    double('Target',
      name: 'MyWidget',
      product_type: 'com.apple.product-type.app-extension',
      sdk: 'iphoneos',
      build_configurations: [widget_config]
    )
  end
  
  let(:share_extension_target) do
    double('Target',
      name: 'ShareExtension',
      product_type: 'com.apple.product-type.app-extension',
      sdk: 'iphoneos',
      build_configurations: [share_extension_config]
    )
  end
  
  let(:main_app_config) do
    build_settings = {
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.app',
      'DEVELOPMENT_TEAM' => 'ABCD123456',
      'CODE_SIGN_STYLE' => 'Automatic',
      'PRODUCT_NAME' => 'MyApp'
    }
    double('BuildConfiguration', name: 'Release', build_settings: build_settings)
  end
  
  let(:widget_config) do
    build_settings = {
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.app.widget',
      'DEVELOPMENT_TEAM' => 'ABCD123456',
      'CODE_SIGN_STYLE' => 'Automatic',
      'PRODUCT_NAME' => 'MyWidget'
    }
    double('BuildConfiguration', name: 'Release', build_settings: build_settings)
  end
  
  let(:share_extension_config) do
    build_settings = {
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.app.share',
      'DEVELOPMENT_TEAM' => 'ABCD123456',
      'CODE_SIGN_STYLE' => 'Automatic',
      'PRODUCT_NAME' => 'ShareExtension'
    }
    double('BuildConfiguration', name: 'Release', build_settings: build_settings)
  end
  
  describe Mysigner::Build::Parser do
    context 'with single app target' do
      let(:targets) { [main_app_target] }
      
      it 'returns single app target' do
        expect(parser.app_targets).to eq([main_app_target])
      end
      
      it 'identifies main target' do
        expect(parser.main_target).to eq(main_app_target)
      end
      
      it 'has no extensions' do
        expect(parser.has_extensions?).to be false
      end
      
      it 'has no multiple apps' do
        expect(parser.has_multiple_apps?).to be false
      end
      
      it 'returns signable targets with info' do
        targets_info = parser.signable_targets
        expect(targets_info.count).to eq(1)
        expect(targets_info.first[:name]).to eq('MyApp')
        expect(targets_info.first[:type]).to eq(:app)
        expect(targets_info.first[:bundle_id]).to eq('com.example.app')
      end
    end
    
    context 'with app + extensions' do
      let(:targets) { [main_app_target, widget_target, share_extension_target] }
      
      it 'returns app targets only' do
        expect(parser.app_targets).to eq([main_app_target])
      end
      
      it 'returns extension targets' do
        expect(parser.extension_targets).to contain_exactly(widget_target, share_extension_target)
      end
      
      it 'returns all signable targets' do
        expect(parser.all_app_targets.count).to eq(3)
      end
      
      it 'has extensions' do
        expect(parser.has_extensions?).to be true
      end
      
      it 'returns signable targets with info' do
        targets_info = parser.signable_targets
        expect(targets_info.count).to eq(3)
        
        app_info = targets_info.find { |t| t[:name] == 'MyApp' }
        expect(app_info[:type]).to eq(:app)
        expect(app_info[:bundle_id]).to eq('com.example.app')
        
        widget_info = targets_info.find { |t| t[:name] == 'MyWidget' }
        expect(widget_info[:type]).to eq(:extension)
        expect(widget_info[:bundle_id]).to eq('com.example.app.widget')
      end
    end
    
    context 'with multiple apps' do
      let(:second_app_target) do
        double('Target',
          name: 'SecondApp',
          product_type: 'com.apple.product-type.application',
          sdk: 'iphoneos',
          build_configurations: [second_app_config]
        )
      end
      
      let(:second_app_config) do
        build_settings = {
          'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.secondapp',
          'DEVELOPMENT_TEAM' => 'ABCD123456',
          'CODE_SIGN_STYLE' => 'Automatic',
          'PRODUCT_NAME' => 'SecondApp'
        }
        double('BuildConfiguration', name: 'Release', build_settings: build_settings)
      end
      
      let(:targets) { [main_app_target, second_app_target] }
      
      it 'returns multiple app targets' do
        expect(parser.app_targets.count).to eq(2)
      end
      
      it 'has multiple apps' do
        expect(parser.has_multiple_apps?).to be true
      end
    end
    
    describe '#target_info' do
      let(:targets) { [main_app_target, widget_target] }
      
      it 'returns detailed info for app target' do
        info = parser.target_info('MyApp')
        expect(info[:name]).to eq('MyApp')
        expect(info[:type]).to eq(:app)
        expect(info[:platform]).to eq(:ios)
        expect(info[:bundle_id]).to eq('com.example.app')
        expect(info[:team_id]).to eq('ABCD123456')
        expect(info[:signing_style]).to eq('Automatic')
      end
      
      it 'returns detailed info for extension target' do
        info = parser.target_info('MyWidget')
        expect(info[:name]).to eq('MyWidget')
        expect(info[:type]).to eq(:extension)
        expect(info[:bundle_id]).to eq('com.example.app.widget')
      end
    end
  end
  
  describe Mysigner::Signing::Wizard do
    let(:targets) { [main_app_target] }
    
    describe 'single target configuration' do
      it 'accepts target option' do
        wizard = Mysigner::Signing::Wizard.new(parser, client, organization_id, target: 'MyApp')
        expect(wizard).to be_a(Mysigner::Signing::Wizard)
      end
      
      it 'accepts all_targets option' do
        wizard = Mysigner::Signing::Wizard.new(parser, client, organization_id, all_targets: true)
        expect(wizard).to be_a(Mysigner::Signing::Wizard)
      end
    end
  end
end

