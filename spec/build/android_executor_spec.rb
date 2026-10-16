# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'mysigner/build/android_executor'

RSpec.describe Mysigner::Build::AndroidExecutor do
  let(:parser) do
    double('android_parser', android_directory: '/proj/android', gradle_command: './gradlew')
  end
  let(:executor) { described_class.new({ directory: '/proj' }, parser) }

  # M3 — the Gradle signing secrets must reach the build via an env hash
  # passed to IO.popen, NOT interpolated into an `export VAR=… &&` shell
  # string (which puts them on the process table / `ps` for the build's life).
  describe 'signing-secret transport' do
    before do
      executor.instance_variable_set(:@variant, 'release')
      executor.instance_variable_set(:@keystore_path, '/keys/release.jks')
      executor.instance_variable_set(:@keystore_password, 'super-secret-store')
      executor.instance_variable_set(:@key_alias, 'upload')
      executor.instance_variable_set(:@key_password, 'super-secret-key')
      executor.instance_variable_set(:@signing_init_script_path, '/tmp/init.gradle')
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/keys/release.jks').and_return(true)
    end

    it 'keeps the keystore/key passwords OUT of the gradle command string' do
      cmd = executor.send(:build_gradle_command, 'bundleRelease')

      expect(cmd).to be_an(Array)
      expect(cmd.first).to eq('./gradlew')
      expect(cmd).not_to include('super-secret-store')
      expect(cmd).not_to include('super-secret-key')
      expect(cmd).not_to include('export MYSIGNER_STORE_PASSWORD')
      expect(cmd).not_to include('export MYSIGNER_KEY_PASSWORD')
    end

    it 'collects the signing vars into @signing_env instead' do
      executor.send(:build_gradle_command, 'bundleRelease')

      expect(executor.instance_variable_get(:@signing_env)).to include(
        'MYSIGNER_STORE_FILE' => File.absolute_path('/keys/release.jks'),
        'MYSIGNER_STORE_PASSWORD' => 'super-secret-store',
        'MYSIGNER_KEY_ALIAS' => 'upload',
        'MYSIGNER_KEY_PASSWORD' => 'super-secret-key'
      )
    end

    it 'passes @signing_env to IO.popen so secrets reach only the child env' do
      cmd = executor.send(:build_gradle_command, 'bundleRelease')

      captured_env = nil
      allow(IO).to receive(:popen) do |first, *_rest, &blk|
        captured_env = first if first.is_a?(Hash)
        blk&.call(StringIO.new("BUILD SUCCESSFUL\n"))
        `true` # set $CHILD_STATUS to success
      end

      executor.send(:execute_with_output, cmd)

      expect(captured_env).to include('MYSIGNER_STORE_PASSWORD' => 'super-secret-store')
    end

    it 'rejects a task that could be interpreted as command input' do
      expect { executor.send(:build_gradle_command, 'bundleRelease; touch /tmp/pwned') }
        .to raise_error(described_class::BuildError, 'Invalid Gradle task')
    end
  end
end
