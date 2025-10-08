require "spec_helper"
require "mysigner/build/executor"

RSpec.describe Mysigner::Build::Executor do
  let(:project_info) {
    {
      type: :workspace,
      path: "/path/to/ios/App/App.xcworkspace",
      directory: "/path/to",
      framework: :capacitor
    }
  }
  let(:parser) { instance_double(Mysigner::Build::Parser) }
  let(:executor) { described_class.new(project_info, parser) }
  
  let(:target_name) { "App" }
  let(:configuration) { "Release" }
  let(:scheme) { "App" }
  
  before do
    allow(parser).to receive(:bundle_id).and_return("com.example.app")
    allow(parser).to receive(:target_platform).and_return(:ios)
  end
  
  describe "#build!" do
    before do
      allow(Time).to receive(:now).and_return(Time.new(2025, 10, 3, 18, 23, 20))
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:exist?).and_return(true)
      
      # Stub execute_with_output to return success
      allow(executor).to receive(:execute_with_output).and_return(true)
    end
    
    context "with workspace" do
      it "builds archive using -workspace flag" do
        expect(executor).to receive(:execute_with_output).with(
          /xcodebuild archive -workspace.*App\.xcworkspace -scheme #{scheme} -configuration #{configuration}/
        )
        
        executor.build!(target_name, configuration, scheme: scheme)
      end
    end
    
    context "with xcodeproj" do
      let(:project_info) {
        {
          type: :project,
          path: "/path/to/App.xcodeproj",
          directory: "/path/to",
          framework: :native
        }
      }
      let(:executor) { described_class.new(project_info, parser) }
      
      it "builds archive using -project flag" do
        allow(executor).to receive(:execute_with_output).and_return(true)
        allow(File).to receive(:exist?).and_return(true)
        
        expect(executor).to receive(:execute_with_output).with(
          /xcodebuild archive -project.*App\.xcodeproj -scheme #{scheme} -configuration #{configuration}/
        )
        
        executor.build!(target_name, configuration, scheme: scheme)
      end
    end
    
    context "with automatic signing" do
      it "includes -allowProvisioningUpdates flag" do
        expect(executor).to receive(:execute_with_output).with(
          /-allowProvisioningUpdates/
        )
        
        executor.build!(target_name, configuration, scheme: scheme, signing_style: 'Automatic')
      end
    end
    
    context "with manual signing" do
      it "does not include -allowProvisioningUpdates flag" do
        expect(executor).to receive(:execute_with_output).with(
          /xcodebuild archive.*-scheme #{scheme}/
        ) do |cmd|
          expect(cmd).not_to include('-allowProvisioningUpdates')
          true
        end
        
        executor.build!(target_name, configuration, scheme: scheme, signing_style: 'Manual')
      end
    end
    
    context "when build succeeds" do
      it "returns archive path" do
        result = executor.build!(target_name, configuration, scheme: scheme)
        
        expect(result).to match(/build\/App-\d{8}-\d{6}\.xcarchive/)
      end
    end
    
    context "when build fails" do
      before do
        allow(executor).to receive(:execute_with_output).and_return(false)
      end
      
      it "raises error" do
        expect {
          executor.build!(target_name, configuration, scheme: scheme)
        }.to raise_error(Mysigner::Build::Executor::BuildError, /Build failed/)
      end
    end
    
    context "when scheme is not provided" do
      it "uses target name as scheme" do
        expect(executor).to receive(:execute_with_output).with(
          /-scheme #{target_name}/
        )
        
        executor.build!(target_name, configuration)
      end
    end
  end
end

