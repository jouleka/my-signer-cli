# frozen_string_literal: true

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
        expect do
          described_class.detect(test_dir)
        end.to raise_error(Mysigner::Build::Detector::NoProjectError,
                           /Failed to generate iOS project with expo prebuild/)
      end

      it 'suggests using expo prebuild' do
        expect do
          described_class.detect(test_dir)
        end.to raise_error(Mysigner::Build::Detector::NoProjectError, /expo prebuild/)
      end

      it 'suggests using EAS Build' do
        expect do
          described_class.detect(test_dir)
        end.to raise_error(Mysigner::Build::Detector::NoProjectError, /EAS Build/)
      end
    end

    context 'when Expo bare workflow (has ios/ folder)' do
      before do
        File.write(File.join(test_dir, 'app.json'), '{"expo": {"name": "Test"}}')
        File.write(File.join(test_dir, 'package.json'),
                   '{"dependencies": {"expo": "^50.0.0", "react-native": "0.73.0"}}')
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

  describe 'read-only detection (allow_prebuild: false)' do
    before do
      File.write(File.join(test_dir, 'app.json'), '{"expo": {"name": "Test"}}')
      File.write(File.join(test_dir, 'package.json'), '{"dependencies": {"expo": "^50.0.0"}}')
    end

    it 'classifies an Expo managed project without running prebuild or raising' do
      expect(described_class).not_to receive(:system)
      result = described_class.detect(test_dir, allow_prebuild: false)
      expect(result[:framework]).to eq(:expo)
      expect(result[:needs_prebuild]).to be(true)
      expect(result[:platform]).to eq(:ios)
    end

    it 'classifies for android too' do
      result = described_class.detect(test_dir, platform: :android, allow_prebuild: false)
      expect(result[:platform]).to eq(:android)
      expect(result[:needs_prebuild]).to be(true)
    end
  end

  describe 'expo detection is dependency-based, not a substring scan' do
    it 'does not treat an expo-prefixed devDependency as an Expo project' do
      File.write(File.join(test_dir, 'app.json'), '{"name":"x"}')
      File.write(File.join(test_dir, 'package.json'),
                 '{"devDependencies": {"eslint-config-expo": "^1.0.0"}}')
      expect { described_class.detect(test_dir, allow_prebuild: false) }
        .to raise_error(Mysigner::Build::Detector::NoProjectError, /No Xcode project found/)
    end
  end
end
