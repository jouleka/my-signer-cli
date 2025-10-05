require "spec_helper"
require "mysigner/build/parser"

RSpec.describe Mysigner::Build::Parser do
  let(:project_path) { "/fake/path/App.xcodeproj" }
  let(:project_info) { { type: :project, path: project_path } }
  let(:parser) { described_class.new(project_info) }
  let(:mock_project) { instance_double(Xcodeproj::Project) }
  let(:mock_target) { instance_double(Xcodeproj::Project::Object::PBXNativeTarget) }
  let(:mock_config) { instance_double(Xcodeproj::Project::Object::XCBuildConfiguration) }
  
  before do
    allow(Xcodeproj::Project).to receive(:open).with(project_path).and_return(mock_project)
    allow(mock_project).to receive(:targets).and_return([mock_target])
    allow(mock_target).to receive(:name).and_return("MyApp")
    allow(mock_target).to receive(:product_type).and_return('com.apple.product-type.application')
    allow(mock_target).to receive(:build_configurations).and_return([mock_config])
    allow(mock_config).to receive(:name).and_return("Release")
    allow(mock_config).to receive(:build_settings).and_return({
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.app',
      'DEVELOPMENT_TEAM' => 'ABCD123456',
      'CODE_SIGN_STYLE' => 'Automatic',
      'CODE_SIGN_IDENTITY' => 'iPhone Distribution',
      'PROVISIONING_PROFILE_SPECIFIER' => 'My Profile'
    })
  end
  
  describe "#targets" do
    it "returns list of target names" do
      expect(parser.targets).to eq(['MyApp'])
    end
  end
  
  describe "#bundle_id" do
    it "returns bundle identifier for target and configuration" do
      expect(parser.bundle_id('MyApp', 'Release')).to eq('com.example.app')
    end
    
    it "raises error for non-existent target" do
      expect {
        parser.bundle_id('NonExistent', 'Release')
      }.to raise_error(RuntimeError, /Target 'NonExistent' not found/)
    end
    
    it "raises error for non-existent configuration" do
      expect {
        parser.bundle_id('MyApp', 'NonExistent')
      }.to raise_error(RuntimeError, /Configuration 'NonExistent' not found/)
    end
  end
  
  describe "#team_id" do
    it "returns development team ID" do
      expect(parser.team_id('MyApp', 'Release')).to eq('ABCD123456')
    end
    
    it "returns nil when not set" do
      allow(mock_config).to receive(:build_settings).and_return({})
      expect(parser.team_id('MyApp', 'Release')).to be_nil
    end
  end
  
  describe "#code_sign_style" do
    it "returns Automatic when set" do
      expect(parser.code_sign_style('MyApp', 'Release')).to eq('Automatic')
    end
    
    it "returns Manual when set" do
      allow(mock_config).to receive(:build_settings).and_return({
        'CODE_SIGN_STYLE' => 'Manual'
      })
      expect(parser.code_sign_style('MyApp', 'Release')).to eq('Manual')
    end
    
    it "returns nil when not set" do
      allow(mock_config).to receive(:build_settings).and_return({})
      expect(parser.code_sign_style('MyApp', 'Release')).to be_nil
    end
  end
  
  describe "#signing_configured?" do
    context "when manual signing is configured" do
      before do
        allow(mock_config).to receive(:build_settings).and_return({
          'CODE_SIGN_STYLE' => 'Manual',
          'CODE_SIGN_IDENTITY' => 'iPhone Distribution',
          'PROVISIONING_PROFILE_SPECIFIER' => 'My Profile'
        })
      end
      
      it "returns true" do
        expect(parser.signing_configured?('MyApp', 'Release')).to be true
      end
    end
    
    context "when manual signing is not configured" do
      before do
        allow(mock_config).to receive(:build_settings).and_return({
          'CODE_SIGN_STYLE' => 'Manual'
        })
      end
      
      it "returns false" do
        expect(parser.signing_configured?('MyApp', 'Release')).to be false
      end
    end
  end
  
end

