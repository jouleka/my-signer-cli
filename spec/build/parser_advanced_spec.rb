# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/build/parser'
require 'mysigner/build/detector'
require 'xcodeproj'
require 'tmpdir'
require 'fileutils'

RSpec.describe Mysigner::Build::Parser do
  describe 'advanced project features' do
    let(:tmpdir) { Dir.mktmpdir('parser_advanced_spec') }

    after { FileUtils.rm_rf(tmpdir) }

    # Helper to create a minimal xcodeproj with given targets
    def create_project(name, targets_config)
      path = File.join(tmpdir, "#{name}.xcodeproj")
      project = Xcodeproj::Project.new(path)

      targets_config.each do |tc|
        target = project.new_target(tc[:type], tc[:name], tc[:platform] || :ios)
        target.build_configurations.each do |config|
          config.build_settings['SDKROOT'] = tc[:sdk] if tc[:sdk]
          config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = tc[:bundle_id] || "com.test.#{tc[:name]}"
        end
      end

      project.save
      path
    end

    def parser_for(path)
      described_class.new({ type: :project, path: path })
    end

    describe '#app_targets' do
      it 'returns all application targets' do
        path = create_project('MultiApp', [
                                { type: :application, name: 'App1' },
                                { type: :application, name: 'App2' },
                                { type: :static_library, name: 'Lib1' }
                              ])
        parser = parser_for(path)

        expect(parser.app_targets.map(&:name)).to contain_exactly('App1', 'App2')
      end
    end

    describe '#extension_targets' do
      it 'returns all extension targets' do
        path = create_project('WithExtension', [
                                { type: :application, name: 'MainApp' },
                                { type: :app_extension, name: 'ShareExtension' }
                              ])
        parser = parser_for(path)

        expect(parser.extension_targets.map(&:name)).to contain_exactly('ShareExtension')
      end

      it 'returns empty array when no extensions' do
        path = create_project('SimpleApp', [
                                { type: :application, name: 'SimpleApp' }
                              ])
        parser = parser_for(path)

        expect(parser.extension_targets).to be_empty
      end
    end

    describe '#all_app_targets' do
      it 'returns main app plus extensions' do
        path = create_project('AppPlusExt', [
                                { type: :application, name: 'MainApp' },
                                { type: :app_extension, name: 'WidgetExt' }
                              ])
        parser = parser_for(path)

        expect(parser.all_app_targets.map(&:name)).to contain_exactly('MainApp', 'WidgetExt')
      end
    end

    describe '#has_extensions?' do
      it 'returns true when project has extensions' do
        path = create_project('WithExt', [
                                { type: :application, name: 'App' },
                                { type: :app_extension, name: 'Ext' }
                              ])
        parser = parser_for(path)

        expect(parser.has_extensions?).to be true
      end

      it 'returns false when project has no extensions' do
        path = create_project('NoExt', [
                                { type: :application, name: 'App' }
                              ])
        parser = parser_for(path)

        expect(parser.has_extensions?).to be false
      end
    end

    describe '#has_multiple_apps?' do
      it 'returns true when project has multiple apps' do
        path = create_project('Multi', [
                                { type: :application, name: 'App1' },
                                { type: :application, name: 'App2' }
                              ])
        parser = parser_for(path)

        expect(parser.has_multiple_apps?).to be true
      end

      it 'returns false for single app project' do
        path = create_project('Single', [
                                { type: :application, name: 'App' }
                              ])
        parser = parser_for(path)

        expect(parser.has_multiple_apps?).to be false
      end
    end

    describe '#target_platform' do
      it 'detects iOS platform' do
        path = create_project('IOSApp', [
                                { type: :application, name: 'IOSApp', platform: :ios, sdk: 'iphoneos' }
                              ])
        parser = parser_for(path)

        expect(parser.target_platform('IOSApp')).to eq(:ios)
      end

      it 'detects macOS platform' do
        path = create_project('MacApp', [
                                { type: :application, name: 'MacApp', platform: :osx, sdk: 'macosx' }
                              ])
        parser = parser_for(path)

        expect(parser.target_platform('MacApp')).to eq(:macos)
      end

      it 'detects tvOS platform' do
        path = create_project('TVApp', [
                                { type: :application, name: 'TVApp', platform: :tvos, sdk: 'appletvos' }
                              ])
        parser = parser_for(path)

        expect(parser.target_platform('TVApp')).to eq(:tvos)
      end

      it 'detects watchOS platform' do
        path = create_project('WatchApp', [
                                { type: :application, name: 'WatchApp', platform: :watchos, sdk: 'watchos' }
                              ])
        parser = parser_for(path)

        expect(parser.target_platform('WatchApp')).to eq(:watchos)
      end
    end

    describe '#product_type' do
      it 'detects app product type' do
        path = create_project('App', [
                                { type: :application, name: 'App' }
                              ])
        parser = parser_for(path)

        expect(parser.product_type('App')).to eq(:app)
      end

      it 'detects framework product type' do
        path = create_project('Framework', [
                                { type: :framework, name: 'MyFramework' }
                              ])
        parser = parser_for(path)

        expect(parser.product_type('MyFramework')).to eq(:framework)
      end

      it 'detects library product type' do
        path = create_project('Library', [
                                { type: :static_library, name: 'MyLib' }
                              ])
        parser = parser_for(path)

        expect(parser.product_type('MyLib')).to eq(:library)
      end

      it 'detects extension product type' do
        path = create_project('Extension', [
                                { type: :application, name: 'Host' },
                                { type: :app_extension, name: 'MyExtension' }
                              ])
        parser = parser_for(path)

        expect(parser.product_type('MyExtension')).to eq(:extension)
      end
    end
  end
end
