# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'mysigner/signing/wizard'
require 'stringio'

RSpec.describe 'mysigner signing configure', type: :integration do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:project_info) { { path: '/path/to/Test.xcodeproj', type: :project, framework: :native, directory: '/path/to' } }
  let(:wizard) { instance_double(Mysigner::Signing::Wizard) }

  before do
    allow(cli).to receive(:load_config).and_return(config)
    allow(cli).to receive(:create_client).and_return(client)
    allow(config).to receive(:api_token).and_return('test-token')
    allow(config).to receive(:organization_id).and_return('org-123')

    # Stub Build::Detector
    allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)

    # Stub Build::Parser
    allow(Mysigner::Build::Parser).to receive(:new).and_return(double('parser'))

    # Stub Signing::Wizard
    allow(Mysigner::Signing::Wizard).to receive(:new).and_return(wizard)
    allow(wizard).to receive(:run!)
  end

  def capture_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  describe 'mysigner signing configure' do
    it 'runs the wizard' do
      expect(wizard).to receive(:run!)

      capture_output { cli.signing('configure') }
    end

    it 'detects the project' do
      expect(Mysigner::Build::Detector).to receive(:detect)

      capture_output { cli.signing('configure') }
    end

    it 'creates parser with project info' do
      expect(Mysigner::Build::Parser).to receive(:new).with(project_info)

      capture_output { cli.signing('configure') }
    end

    it 'creates wizard with correct parameters' do
      parser = double('parser')
      allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)

      expect(Mysigner::Signing::Wizard).to receive(:new).with(parser, client, 'org-123')

      capture_output { cli.signing('configure') }
    end

    context 'when not logged in' do
      before do
        allow(config).to receive(:api_token).and_return(nil)
        allow(cli).to receive(:exit)
      end

      it 'shows error' do
        expect(cli).to receive(:exit).with(1)

        capture_output do
          cli.signing('setup')
        rescue StandardError
          nil
        end
      end
    end

    context 'when no project found' do
      before do
        allow(Mysigner::Build::Detector).to receive(:detect)
          .and_raise(Mysigner::Build::Detector::NoProjectError.new('No project found'))
        allow(cli).to receive(:exit)
      end

      it 'shows error and exits' do
        expect(cli).to receive(:exit).with(1)

        output = capture_output { cli.signing('setup') }

        expect(output).to include('No project found')
      end
    end

    context 'when wizard fails' do
      before do
        allow(wizard).to receive(:run!)
          .and_raise(Mysigner::Signing::Wizard::WizardError.new('Configuration failed'))
        allow(cli).to receive(:exit)
      end

      it 'shows error and exits' do
        expect(cli).to receive(:exit).with(1)

        output = capture_output { cli.signing('setup') }

        expect(output).to include('Wizard failed')
        expect(output).to include('Configuration failed')
      end
    end

    context 'with invalid action' do
      before do
        allow(cli).to receive(:exit)
      end

      it 'shows error for unknown action' do
        expect(cli).to receive(:exit).with(1)

        output = capture_output { cli.signing('invalid') }

        expect(output).to include('Unknown action: invalid')
        expect(output).to include('Usage: mysigner signing configure')
      end
    end
  end

  describe 'help documentation' do
    it 'documents signing configure command' do
      help_output = capture_output { cli.help('signing') }

      expect(help_output).to include('signing configure')
      expect(help_output).to include('Guides you through')
      expect(help_output).to include('manual code signing')
    end

    it 'shows long description' do
      help_output = capture_output { cli.help('signing') }

      expect(help_output).to include('Guides you through')
      expect(help_output).to include('Detects your project')
      expect(help_output).to include('configuration')
      expect(help_output).to include('Validates the setup')
    end
  end

  describe 'integration with other commands' do
    it 'can be run after build command' do
      # Simulate workflow: build fails -> run signing setup
      expect(wizard).to receive(:run!)

      capture_output { cli.signing('configure') }
    end
  end
end
