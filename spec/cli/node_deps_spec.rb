# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'mysigner/build/detector'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'JavaScript dependency auto-setup' do
  describe 'Detector.detect_package_manager / install_command' do
    it 'picks the right package manager from the lockfile' do
      Dir.mktmpdir do |d|
        File.write(File.join(d, 'yarn.lock'), '')
        expect(Mysigner::Build::Detector.detect_package_manager(d)).to eq(:yarn)
      end
      Dir.mktmpdir do |d|
        File.write(File.join(d, 'pnpm-lock.yaml'), '')
        expect(Mysigner::Build::Detector.detect_package_manager(d)).to eq(:pnpm)
      end
      Dir.mktmpdir do |d|
        File.write(File.join(d, 'package-lock.json'), '{}')
        expect(Mysigner::Build::Detector.detect_package_manager(d)).to eq(:npm)
      end
    end

    it 'maps managers to the exact install command' do
      expect(Mysigner::Build::Detector.install_command(:yarn)).to eq('yarn install')
      expect(Mysigner::Build::Detector.install_command(:pnpm)).to eq('pnpm install')
      expect(Mysigner::Build::Detector.install_command(:bun)).to eq('bun install')
      expect(Mysigner::Build::Detector.install_command(:npm)).to eq('npm install')
    end
  end

  describe '#maybe_install_node_deps!' do
    let(:cli) { Mysigner::CLI.new }

    before do
      # Restore the real method (spec_helper no-ops it by default).
      allow_any_instance_of(Mysigner::CLI).to receive(:maybe_install_node_deps!).and_call_original
    end

    def expo_project(dir, lock: 'package-lock.json')
      File.write(File.join(dir, 'package.json'), '{"dependencies":{"expo":"~54.0.0"}}')
      File.write(File.join(dir, lock), '{}')
    end

    it 'errors with the EXACT install command when deps are missing and non-interactive' do
      Dir.mktmpdir do |d|
        expo_project(d, lock: 'yarn.lock')
        allow($stdin).to receive(:tty?).and_return(false)
        expect do
          expect { cli.maybe_install_node_deps!(d) }.to raise_error(SystemExit)
        end.to output(/yarn install/).to_stdout
      end
    end

    it 'auto-installs without prompting when --setup is set' do
      Dir.mktmpdir do |d|
        expo_project(d)
        allow(cli).to receive(:options).and_return({ setup: true })
        expect(cli).to receive(:system).with('npm', 'install').and_return(true)
        expect { cli.maybe_install_node_deps!(d) }.to output(/Installing JavaScript dependencies/).to_stdout
      end
    end

    it 'auto-installs when MYSIGNER_AUTO_SETUP=1' do
      Dir.mktmpdir do |d|
        expo_project(d, lock: 'pnpm-lock.yaml')
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('MYSIGNER_AUTO_SETUP').and_return('1')
        expect(cli).to receive(:system).with('pnpm', 'install').and_return(true)
        cli.maybe_install_node_deps!(d)
      end
    end

    it 'is a no-op when node_modules already exists' do
      Dir.mktmpdir do |d|
        expo_project(d)
        FileUtils.mkdir_p(File.join(d, 'node_modules'))
        expect(cli).not_to receive(:system)
        expect { cli.maybe_install_node_deps!(d) }.not_to raise_error
      end
    end

    it 'is a no-op for a non-JS project (no package.json)' do
      Dir.mktmpdir do |d|
        expect(cli).not_to receive(:system)
        expect { cli.maybe_install_node_deps!(d) }.not_to raise_error
      end
    end

    it 'is a no-op for a JS project that is not Expo/React-Native' do
      Dir.mktmpdir do |d|
        File.write(File.join(d, 'package.json'), '{"dependencies":{"lodash":"^4"}}')
        expect(cli).not_to receive(:system)
        expect { cli.maybe_install_node_deps!(d) }.not_to raise_error
      end
    end
  end
end
