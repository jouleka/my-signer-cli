# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/build/detector'
require 'tmpdir'
require 'fileutils'

# Edge cases the basic detector_spec doesn't cover: monorepos, ambiguous
# project layouts, and Android-detection variants. These match the kinds of
# real-world repos people drop the CLI into; if any of these regress,
# `mysigner ship` will pick the wrong project and silently build the wrong
# binary.
RSpec.describe Mysigner::Build::Detector do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.rm_rf(tmpdir) }

  describe 'monorepo-style layouts' do
    context 'when a parent monorepo has both a top-level workspace AND an ios/ subdir' do
      # Real example: a monorepo where `apps/ios-native/` has a workspace and
      # `apps/rn-app/ios/` has another workspace. Running the CLI from the
      # parent that contains BOTH should not blindly pick one — but at the
      # same time, running from inside ios-native/ should pick that one
      # alone, not fall through to RN detection.
      it 'picks the local workspace when the directory has its own .xcworkspace' do
        FileUtils.mkdir_p(File.join(tmpdir, 'App.xcworkspace'))
        FileUtils.mkdir_p(File.join(tmpdir, 'ios'))
        FileUtils.mkdir_p(File.join(tmpdir, 'ios', 'OtherApp.xcworkspace'))

        result = described_class.detect(tmpdir)

        # Without a package.json+react-native or pubspec, falls through to
        # native — and a native project at root takes precedence over the
        # ios/ subfolder.
        expect(result[:framework]).to eq(:native)
        expect(result[:path]).to end_with('App.xcworkspace')
      end
    end

    context 'when ios/ holds two workspaces' do
      # Apple-recommended setup uses one .xcworkspace; some legacy projects
      # accidentally check in two. Detection should still succeed with one
      # of them rather than raising.
      it 'still produces a result (does not raise) with multiple workspaces in ios/' do
        FileUtils.mkdir_p(File.join(tmpdir, 'ios'))
        FileUtils.mkdir_p(File.join(tmpdir, 'ios', 'A.xcworkspace'))
        FileUtils.mkdir_p(File.join(tmpdir, 'ios', 'B.xcworkspace'))
        File.write(File.join(tmpdir, 'package.json'), '{"dependencies": {"react-native": "0.74"}}')

        result = described_class.detect(tmpdir)

        expect(result[:type]).to eq(:workspace)
        expect(result[:framework]).to eq(:react_native)
        # The result is non-deterministic (Dir.glob sort is platform-defined)
        # but it MUST be one of the two we created — never some unrelated path.
        expect(result[:path]).to match(%r{ios/(A|B)\.xcworkspace\z})
      end
    end
  end

  describe 'precedence: Capacitor wins over plain React Native' do
    # Capacitor projects also have package.json with native deps. The
    # detector checks Capacitor first because its `capacitor.config.{json,ts}`
    # is the more specific signal.
    it 'detects capacitor when both capacitor.config.json AND react-native are present' do
      File.write(File.join(tmpdir, 'capacitor.config.json'), '{}')
      File.write(File.join(tmpdir, 'package.json'),
                 '{"dependencies": {"@capacitor/core": "5.0", "react-native": "0.74"}}')
      FileUtils.mkdir_p(File.join(tmpdir, 'ios', 'App'))
      FileUtils.mkdir_p(File.join(tmpdir, 'ios', 'App', 'App.xcworkspace'))

      result = described_class.detect(tmpdir)

      expect(result[:framework]).to eq(:capacitor)
    end
  end

  describe 'empty / unrecognised directory' do
    it 'raises NoProjectError when no Xcode project is found' do
      expect { described_class.detect(tmpdir) }
        .to raise_error(Mysigner::Build::Detector::NoProjectError, /No Xcode project found/)
    end
  end

  describe 'Android: native single-module gradle project' do
    it 'detects build.gradle.kts in app/' do
      FileUtils.mkdir_p(File.join(tmpdir, 'app'))
      File.write(File.join(tmpdir, 'app', 'build.gradle.kts'), 'plugins { id("com.android.application") }')

      result = described_class.detect(tmpdir, platform: :android)

      expect(result[:platform]).to eq(:android)
      expect(result[:type]).to eq(:gradle)
      expect(result[:framework]).to eq(:native)
      expect(result[:app_build_gradle]).to end_with('app/build.gradle.kts')
    end

    it 'detects single-module project with android {} block in root build.gradle' do
      File.write(File.join(tmpdir, 'build.gradle'), <<~GRADLE)
        android {
          compileSdk 34
        }
      GRADLE

      result = described_class.detect(tmpdir, platform: :android)

      expect(result[:platform]).to eq(:android)
      expect(result[:framework]).to eq(:native)
    end

    it 'does NOT detect a root build.gradle that lacks an android block' do
      # Plain Java/Kotlin library — not an Android app.
      File.write(File.join(tmpdir, 'build.gradle'), 'plugins { id "java" }')

      expect { described_class.detect(tmpdir, platform: :android) }
        .to raise_error(Mysigner::Build::Detector::NoProjectError, /No Android project found/)
    end
  end

  describe 'Android: cross-platform precedence' do
    # When platform: :android is requested explicitly, Capacitor / RN /
    # Flutter detection should still pick the right framework — they all
    # produce different android/ layouts and require different gradle entry
    # points.
    it 'detects React Native android/ when package.json declares react-native' do
      FileUtils.mkdir_p(File.join(tmpdir, 'android', 'app'))
      File.write(File.join(tmpdir, 'android', 'app', 'build.gradle'), '')
      File.write(File.join(tmpdir, 'package.json'), '{"dependencies": {"react-native": "0.74"}}')

      result = described_class.detect(tmpdir, platform: :android)

      expect(result[:framework]).to eq(:react_native)
    end

    it 'detects Flutter android/ when pubspec.yaml is present' do
      FileUtils.mkdir_p(File.join(tmpdir, 'android', 'app'))
      File.write(File.join(tmpdir, 'android', 'app', 'build.gradle'), '')
      File.write(File.join(tmpdir, 'pubspec.yaml'), "name: my_flutter_app\n")

      result = described_class.detect(tmpdir, platform: :android)

      expect(result[:framework]).to eq(:flutter)
    end

    it 'detects Capacitor android/ when capacitor.config.ts is present' do
      FileUtils.mkdir_p(File.join(tmpdir, 'android', 'app'))
      File.write(File.join(tmpdir, 'android', 'app', 'build.gradle'), '')
      File.write(File.join(tmpdir, 'capacitor.config.ts'), 'export default { appId: "x" };')

      result = described_class.detect(tmpdir, platform: :android)

      expect(result[:framework]).to eq(:capacitor)
    end
  end
end
