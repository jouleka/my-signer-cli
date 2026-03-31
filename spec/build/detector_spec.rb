# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/build/detector'
require 'tmpdir'

RSpec.describe Mysigner::Build::Detector do
  describe '.detect' do
    let(:temp_dir) { Dir.mktmpdir }

    after { FileUtils.rm_rf(temp_dir) }

    context 'when Native iOS project exists' do
      it 'detects .xcworkspace over .xcodeproj' do
        workspace = File.join(temp_dir, 'App.xcworkspace')
        project = File.join(temp_dir, 'App.xcodeproj')
        FileUtils.mkdir_p(workspace)
        FileUtils.mkdir_p(project)

        result = described_class.detect(temp_dir)

        expect(result[:type]).to eq(:workspace)
        expect(result[:framework]).to eq(:native)
        expect(result[:path]).to eq(File.absolute_path(workspace))
      end

      it 'detects .xcodeproj when no workspace' do
        project = File.join(temp_dir, 'App.xcodeproj')
        FileUtils.mkdir_p(project)

        result = described_class.detect(temp_dir)

        expect(result[:type]).to eq(:project)
        expect(result[:framework]).to eq(:native)
        expect(result[:path]).to eq(File.absolute_path(project))
      end
    end

    context 'when React Native project exists' do
      it 'detects ios/*.xcworkspace' do
        ios_dir = File.join(temp_dir, 'ios')
        workspace = File.join(ios_dir, 'App.xcworkspace')
        package_json = File.join(temp_dir, 'package.json')

        FileUtils.mkdir_p(ios_dir)
        FileUtils.mkdir_p(workspace)
        File.write(package_json, '{"dependencies": {"react-native": "0.72.0"}}')

        result = described_class.detect(temp_dir)

        expect(result[:type]).to eq(:workspace)
        expect(result[:framework]).to eq(:react_native)
        expect(result[:path]).to eq(File.absolute_path(workspace))
      end

      it 'detects ios/*.xcodeproj' do
        ios_dir = File.join(temp_dir, 'ios')
        project = File.join(ios_dir, 'App.xcodeproj')
        package_json = File.join(temp_dir, 'package.json')

        FileUtils.mkdir_p(ios_dir)
        FileUtils.mkdir_p(project)
        File.write(package_json, '{"dependencies": {"react-native": "0.72.0"}}')

        result = described_class.detect(temp_dir)

        expect(result[:type]).to eq(:project)
        expect(result[:framework]).to eq(:react_native)
        expect(result[:path]).to eq(File.absolute_path(project))
      end
    end

    context 'when Flutter project exists' do
      it 'detects ios/*.xcworkspace' do
        ios_dir = File.join(temp_dir, 'ios')
        workspace = File.join(ios_dir, 'Runner.xcworkspace')
        pubspec = File.join(temp_dir, 'pubspec.yaml')

        FileUtils.mkdir_p(ios_dir)
        FileUtils.mkdir_p(workspace)
        File.write(pubspec, "name: my_app\ndependencies:\n  flutter:\n    sdk: flutter")

        result = described_class.detect(temp_dir)

        expect(result[:type]).to eq(:workspace)
        expect(result[:framework]).to eq(:flutter)
        expect(result[:path]).to eq(File.absolute_path(workspace))
      end
    end

    context 'when Capacitor project exists' do
      it 'detects ios/App/*.xcworkspace' do
        ios_app_dir = File.join(temp_dir, 'ios', 'App')
        workspace = File.join(ios_app_dir, 'App.xcworkspace')
        capacitor_config = File.join(temp_dir, 'capacitor.config.ts')

        FileUtils.mkdir_p(ios_app_dir)
        FileUtils.mkdir_p(workspace)
        File.write(capacitor_config, "export default { appId: 'com.example' }")

        result = described_class.detect(temp_dir)

        expect(result[:type]).to eq(:workspace)
        expect(result[:framework]).to eq(:capacitor)
        expect(result[:path]).to eq(File.absolute_path(workspace))
      end

      it 'detects Ionic project with capacitor.config.json' do
        ios_app_dir = File.join(temp_dir, 'ios', 'App')
        workspace = File.join(ios_app_dir, 'App.xcworkspace')
        capacitor_config = File.join(temp_dir, 'capacitor.config.json')

        FileUtils.mkdir_p(ios_app_dir)
        FileUtils.mkdir_p(workspace)
        File.write(capacitor_config, '{"appId": "com.example"}')

        result = described_class.detect(temp_dir)

        expect(result[:type]).to eq(:workspace)
        expect(result[:framework]).to eq(:capacitor)
        expect(result[:path]).to eq(File.absolute_path(workspace))
      end
    end

    context 'when no project exists' do
      it 'raises error with helpful message' do
        expect do
          described_class.detect(temp_dir)
        end.to raise_error(Mysigner::Build::Detector::NoProjectError, /No Xcode project found/)
      end
    end
  end
end
