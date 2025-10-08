require 'spec_helper'
require 'mysigner/build/detector'
require 'fileutils'
require 'json'

RSpec.describe Mysigner::Build::Detector do
  let(:test_dir) { '/tmp/mysigner_test_detector' }

  before do
    FileUtils.mkdir_p(test_dir)
  end

  after do
    FileUtils.rm_rf(test_dir)
  end

  describe 'Expo managed workflow detection' do
    context 'when app.json and package.json exist but no ios/ folder' do
      before do
        # Create Expo managed workflow structure
        File.write(File.join(test_dir, 'app.json'), '{"expo": {"name": "Test"}}')
        File.write(File.join(test_dir, 'package.json'), '{"dependencies": {"expo": "^50.0.0"}}')
      end

      it 'raises NoProjectError with helpful Expo message' do
        expect {
          described_class.detect(test_dir)
        }.to raise_error(Mysigner::Build::Detector::NoProjectError, /Expo managed workflow/)
      end

      it 'suggests using expo prebuild' do
        expect {
          described_class.detect(test_dir)
        }.to raise_error(Mysigner::Build::Detector::NoProjectError, /expo prebuild/)
      end

      it 'suggests using EAS Build' do
        expect {
          described_class.detect(test_dir)
        }.to raise_error(Mysigner::Build::Detector::NoProjectError, /EAS Build/)
      end
    end

    context 'when Expo bare workflow (has ios/ folder)' do
      before do
        File.write(File.join(test_dir, 'app.json'), '{"expo": {"name": "Test"}}')
        File.write(File.join(test_dir, 'package.json'), '{"dependencies": {"expo": "^50.0.0", "react-native": "0.73.0"}}')
        FileUtils.mkdir_p(File.join(test_dir, 'ios'))
        # Create a dummy xcodeproj
        FileUtils.mkdir_p(File.join(test_dir, 'ios', 'TestApp.xcodeproj'))
      end

      it 'detects as React Native project' do
        result = described_class.detect(test_dir)
        expect(result[:framework]).to eq(:react_native)
      end
    end
  end

  describe 'backward compatibility' do
    it 'still detects Capacitor projects' do
      # Create Capacitor structure
      File.write(File.join(test_dir, 'capacitor.config.json'), '{"appId": "com.test.app"}')
      FileUtils.mkdir_p(File.join(test_dir, 'ios', 'App'))
      FileUtils.mkdir_p(File.join(test_dir, 'ios', 'App', 'App.xcworkspace'))

      result = described_class.detect(test_dir)
      expect(result[:framework]).to eq(:capacitor)
    end

    it 'still detects React Native projects' do
      File.write(File.join(test_dir, 'package.json'), '{"dependencies": {"react-native": "0.73.0"}}')
      FileUtils.mkdir_p(File.join(test_dir, 'ios'))
      FileUtils.mkdir_p(File.join(test_dir, 'ios', 'TestApp.xcodeproj'))

      result = described_class.detect(test_dir)
      expect(result[:framework]).to eq(:react_native)
    end

    it 'still detects Flutter projects' do
      File.write(File.join(test_dir, 'pubspec.yaml'), 'name: test_app')
      FileUtils.mkdir_p(File.join(test_dir, 'ios'))
      FileUtils.mkdir_p(File.join(test_dir, 'ios', 'Runner.xcworkspace'))

      result = described_class.detect(test_dir)
      expect(result[:framework]).to eq(:flutter)
    end

    it 'still detects native iOS projects' do
      FileUtils.mkdir_p(File.join(test_dir, 'TestApp.xcodeproj'))

      result = described_class.detect(test_dir)
      expect(result[:framework]).to eq(:native)
    end
  end
end
