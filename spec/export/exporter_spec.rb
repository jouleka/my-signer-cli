# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/export/exporter'
require 'tmpdir'

RSpec.describe Mysigner::Export::Exporter do
  let(:temp_dir) { Dir.mktmpdir }
  let(:archive_path) { File.join(temp_dir, 'App.xcarchive') }
  let(:output_dir) { File.join(temp_dir, 'output') }

  before do
    # Create fake archive directory
    FileUtils.mkdir_p(archive_path)
  end

  after do
    FileUtils.rm_rf(temp_dir)
  end

  describe '#initialize' do
    it 'accepts archive path and output directory' do
      exporter = described_class.new(archive_path, output_dir: output_dir)
      expect(exporter).to be_a(described_class)
    end

    it "raises error if archive doesn't exist" do
      expect do
        described_class.new('/fake/path/App.xcarchive')
      end.to raise_error(Mysigner::Export::Exporter::ExportError, /Archive not found/)
    end

    it 'raises error if archive is not a directory' do
      file_path = File.join(temp_dir, 'notarchive.txt')
      File.write(file_path, 'test')

      expect do
        described_class.new(file_path)
      end.to raise_error(Mysigner::Export::Exporter::ExportError, /Invalid archive/)
    end

    it "raises error if archive doesn't have .xcarchive extension" do
      bad_archive = File.join(temp_dir, 'App.txt')
      FileUtils.mkdir_p(bad_archive)

      expect do
        described_class.new(bad_archive)
      end.to raise_error(Mysigner::Export::Exporter::ExportError, /Invalid archive/)
    end
  end

  describe '#export!' do
    let(:exporter) { described_class.new(archive_path, output_dir: output_dir) }

    before do
      # Create output directory first (before stubbing)
      FileUtils.mkdir_p(output_dir)
      File.write(File.join(output_dir, 'App.ipa'), 'fake ipa content')

      # Stub IO.popen to avoid actually running xcodebuild
      allow(IO).to receive(:popen).and_yield(StringIO.new("Exporting...\n"))
      allow(Process).to receive(:last_status).and_return(double(success?: true))
    end

    it 'exports with app-store method by default' do
      ipa_path = exporter.export!(method: :appstore, team_id: 'ABC123')

      expect(ipa_path).to end_with('App.ipa')
      expect(File.exist?(ipa_path)).to be true
    end

    it 'exports with ad-hoc method' do
      ipa_path = exporter.export!(method: :adhoc, team_id: 'ABC123')

      expect(ipa_path).to end_with('.ipa')
    end

    it 'exports with development method' do
      ipa_path = exporter.export!(method: :development, team_id: 'ABC123')

      expect(ipa_path).to end_with('.ipa')
    end

    it 'exports with enterprise method' do
      ipa_path = exporter.export!(method: :enterprise, team_id: 'ABC123')

      expect(ipa_path).to end_with('.ipa')
    end

    it 'supports automatic signing style' do
      expect(IO).to receive(:popen) do |cmd, _opts, &block|
        expect(cmd).to include('xcodebuild')
        expect(cmd).to include('-exportArchive')
        expect(cmd).to include('-allowProvisioningUpdates')
        block.call(StringIO.new("Exporting...\n"))
      end

      exporter.export!(method: :appstore, team_id: 'ABC123', signing_style: 'automatic')
    end

    it 'supports manual signing style' do
      expect(IO).to receive(:popen) do |cmd, _opts, &block|
        expect(cmd).to include('xcodebuild')
        expect(cmd).to include('-exportArchive')
        block.call(StringIO.new("Exporting...\n"))
      end

      exporter.export!(method: :appstore, team_id: 'ABC123', signing_style: 'manual')
    end

    it 'creates export options plist' do
      # Capture the plist path that gets created
      plist_paths = []

      allow(IO).to receive(:popen) do |cmd, _opts, &block|
        # Extract plist path from command
        plist_paths << Regexp.last_match(1) if cmd =~ /-exportOptionsPlist\s+(\S+)/
        block.call(StringIO.new("Exporting...\n"))
      end

      exporter.export!(method: :appstore, team_id: 'ABC123')

      expect(plist_paths).not_to be_empty
    end

    it 'raises error if xcodebuild fails' do
      # Override the stub to simulate failure
      allow(exporter).to receive(:execute_export).and_return(false)

      expect do
        exporter.export!(method: :appstore, team_id: 'ABC123')
      end.to raise_error(Mysigner::Export::Exporter::ExportError, /Export failed/)
    end

    it 'raises error if .ipa file not found after export' do
      # Don't create the .ipa file
      FileUtils.rm(File.join(output_dir, 'App.ipa'))

      expect do
        exporter.export!(method: :appstore, team_id: 'ABC123')
      end.to raise_error(Mysigner::Export::Exporter::ExportError, /.ipa file not found/)
    end

    it 'returns the most recent .ipa if multiple exist' do
      # Create multiple .ipa files with different timestamps
      old_ipa = File.join(output_dir, 'Old.ipa')
      new_ipa = File.join(output_dir, 'New.ipa')

      File.write(old_ipa, 'old')
      sleep 0.1
      File.write(new_ipa, 'new')

      ipa_path = exporter.export!(method: :appstore, team_id: 'ABC123')

      expect(ipa_path).to eq(new_ipa)
    end

    it 'cleans up temporary plist file' do
      plist_path = nil

      allow(IO).to receive(:popen) do |cmd, _opts, &block|
        plist_path = Regexp.last_match(1) if cmd =~ /-exportOptionsPlist\s+(\S+)/
        block.call(StringIO.new("Exporting...\n"))
      end

      exporter.export!(method: :appstore, team_id: 'ABC123')

      # Plist should be deleted after export
      expect(File.exist?(plist_path)).to be false if plist_path
    end
  end
end
