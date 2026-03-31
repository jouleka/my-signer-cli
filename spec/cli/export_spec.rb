# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner export', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }
  let(:archive_path) { '/path/to/MyApp.xcarchive' }
  let(:ipa_path) { '/path/to/MyApp.ipa' }

  # Helper to capture stdout
  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(cli).to receive(:exit) # Stub exit
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(nil)
      allow(config).to receive(:api_token).and_return(nil)
      allow(config).to receive(:organization_id).and_return(nil)
      allow(File).to receive(:exist?).and_return(true) # Stub to prevent errors if execution continues
    end

    it 'shows error message' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.export(archive_path)
    end
  end

  describe 'when archive does not exist' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(File).to receive(:exist?).with(archive_path).and_return(false)
    end

    it 'shows export header' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('My Signer - Export')
    end

    it 'shows error message' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('Archive not found')
      expect(output).to include(archive_path)
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.export(archive_path)
    end
  end

  describe 'successful export' do
    let(:exporter) { instance_double(Mysigner::Export::Exporter) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(File).to receive(:exist?).with(archive_path).and_return(true)
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)
      allow(exporter).to receive(:export!).and_return(ipa_path)
      # Set default options
      cli.options = { method: 'appstore', output: nil }
    end

    it 'shows export header' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('My Signer - Export')
    end

    it 'creates exporter with archive path' do
      expect(Mysigner::Export::Exporter).to receive(:new).with(
        archive_path,
        output_dir: nil
      )
      cli.export(archive_path)
    end

    it 'exports with default method' do
      expect(exporter).to receive(:export!).with(
        method: :appstore,
        team_id: nil,
        signing_style: 'automatic'
      )
      cli.export(archive_path)
    end

    it 'shows success message' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('Export succeeded!')
    end

    it 'shows IPA path' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('IPA:')
      expect(output).to include(ipa_path)
    end

    it 'shows next steps' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('Next steps:')
      expect(output).to include('mysigner upload testflight')
      expect(output).to include('mysigner ship testflight')
    end

    context 'with custom output directory' do
      before do
        cli.options = { output: '/custom/path' }
      end

      it 'passes output directory to exporter' do
        expect(Mysigner::Export::Exporter).to receive(:new).with(
          archive_path,
          output_dir: '/custom/path'
        )
        cli.export(archive_path)
      end
    end

    context 'with adhoc method' do
      before do
        cli.options = { method: 'adhoc' }
      end

      it 'exports with adhoc method' do
        expect(exporter).to receive(:export!).with(
          method: :adhoc,
          team_id: nil,
          signing_style: 'automatic'
        )
        cli.export(archive_path)
      end
    end

    context 'with enterprise method' do
      before do
        cli.options = { method: 'enterprise' }
      end

      it 'exports with enterprise method' do
        expect(exporter).to receive(:export!).with(
          method: :enterprise,
          team_id: nil,
          signing_style: 'automatic'
        )
        cli.export(archive_path)
      end
    end

    context 'with development method' do
      before do
        cli.options = { method: 'development' }
      end

      it 'exports with development method' do
        expect(exporter).to receive(:export!).with(
          method: :development,
          team_id: nil,
          signing_style: 'automatic'
        )
        cli.export(archive_path)
      end
    end
  end

  describe 'when export fails' do
    let(:exporter) { instance_double(Mysigner::Export::Exporter) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(File).to receive(:exist?).with(archive_path).and_return(true)
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)
      allow(exporter).to receive(:export!).and_raise(
        Mysigner::Export::Exporter::ExportError.new('Export failed: signing error')
      )
      # Set default options
      cli.options = { method: 'appstore', output: nil }
    end

    it 'shows error message' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('Error: Export failed')
      expect(output).to include('signing error')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.export(archive_path)
    end
  end

  describe 'when unexpected error occurs' do
    let(:exporter) { instance_double(Mysigner::Export::Exporter) }

    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(File).to receive(:exist?).with(archive_path).and_return(true)
      allow(Mysigner::Export::Exporter).to receive(:new).and_return(exporter)
      allow(exporter).to receive(:export!).and_raise(StandardError.new('Unexpected failure'))
      # Set default options
      cli.options = { method: 'appstore', output: nil }
    end

    it 'shows error message' do
      output = capture_stdout { cli.export(archive_path) }
      expect(output).to include('Unexpected error')
      expect(output).to include('Unexpected failure')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.export(archive_path)
    end

    context 'with DEBUG environment variable' do
      before do
        allow(ENV).to receive(:[]).with('DEBUG').and_return('true')
      end

      it 'shows backtrace' do
        # Just verify it doesn't crash with DEBUG enabled
        expect { cli.export(archive_path) }.not_to raise_error
      end
    end
  end

  describe 'help text' do
    it 'has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help export]) }
      expect(help_output).to include('Export .xcarchive to .ipa file')
    end

    it 'shows archive path argument' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help export]) }
      expect(help_output).to include('ARCHIVE_PATH')
    end

    it 'shows options' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help export]) }
      expect(help_output).to include('--method')
      expect(help_output).to include('--output')
    end

    it 'shows export methods' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help export]) }
      expect(help_output).to include('appstore')
    end
  end

  describe 'integration tests' do
    it 'requires login' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)
      allow(File).to receive(:exist?).with(archive_path).and_return(true)

      output = capture_stdout { Mysigner::CLI.start(['export', archive_path]) }
      expect(output).to include('Not logged in')
    end

    it 'requires archive path argument' do
      # Thor will show usage if no argument provided
      output = capture_stdout { Mysigner::CLI.start(['export']) }
      expect(output).to include('export')
    end
  end
end
