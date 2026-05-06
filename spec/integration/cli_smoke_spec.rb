# frozen_string_literal: true

require_relative 'integration_helper'
require 'mysigner/cli'
require 'stringio'

# Smokes the CLI end-to-end against a real iOS project on disk. Runs the
# in-process `Mysigner::CLI.start([...])` path so it exercises the same
# code an installed gem would.
#
# Required ENV (in addition to the integration suite's auth vars):
#   MYSIGNER_TEST_IOS_PROJECT_PATH  /absolute/path/to/an/ios/project
RSpec.describe 'CLI smoke against a real iOS project', :integration do
  let(:project_path) { ENV.fetch('MYSIGNER_TEST_IOS_PROJECT_PATH', nil) }

  before do
    skip 'MYSIGNER_TEST_IOS_PROJECT_PATH not set' if project_path.nil? || project_path.empty?
    skip "MYSIGNER_TEST_IOS_PROJECT_PATH=#{project_path} does not exist" unless Dir.exist?(project_path)
  end

  # Captures both stdout and stderr from an in-process Thor command run.
  def capture_cli(argv)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    begin
      Dir.chdir(project_path) { Mysigner::CLI.start(argv) }
    rescue SystemExit
      # Thor exits the process on some commands; we want to keep going.
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    out.string + err.string
  end

  describe 'mysigner version' do
    it 'prints the My Signer CLI banner' do
      output = capture_cli(['version'])
      expect(output).to include('My Signer CLI v')
      expect(output).to match(/Ruby:\s+\d+\.\d+/)
    end
  end

  describe 'mysigner doctor' do
    # Doctor walks the entire local environment + auth + project setup. It
    # makes API calls but doesn't modify any state — perfect smoke test.
    # If this passes, `mysigner ship` is highly likely to work.
    it 'completes a full health check without raising' do
      output = capture_cli(['doctor'])

      # Exact lines vary by env; assert on the section markers the doctor
      # always prints.
      expect(output).to match(/(Doctor|Health Check|Diagnostic)/i)
      # If doctor failed catastrophically it would have exited before
      # printing anything project-related.
      expect(output.length).to be > 100
    end
  end

  describe 'project detection' do
    # Direct use of the detector against the real project. Verifies the
    # framework guess matches what we expect for this kind of repo.
    it 'detects the project type and returns a valid result' do
      require 'mysigner/build/detector'

      result = Mysigner::Build::Detector.detect(project_path)

      expect(result[:platform]).to eq(:ios)
      expect(%i[workspace project]).to include(result[:type])
      expect(result[:path]).to(satisfy { |p| File.exist?(p) })
      expect(%i[react_native flutter capacitor expo native]).to include(result[:framework])
    end
  end
end
