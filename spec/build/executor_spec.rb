# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/build/executor'

RSpec.describe Mysigner::Build::Executor do
  let(:project_info) do
    {
      type: :workspace,
      path: '/path/to/ios/App/App.xcworkspace',
      directory: '/path/to',
      framework: :capacitor
    }
  end
  let(:parser) { instance_double(Mysigner::Build::Parser) }
  let(:executor) { described_class.new(project_info, parser) }

  let(:target_name) { 'App' }
  let(:configuration) { 'Release' }
  let(:scheme) { 'App' }

  before do
    allow(parser).to receive(:bundle_id).and_return('com.example.app')
    allow(parser).to receive(:target_platform).and_return(:ios)
  end

  describe '#build!' do
    before do
      allow(Time).to receive(:now).and_return(Time.new(2025, 10, 3, 18, 23, 20))
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:exist?).and_return(true)

      # Stub execute_with_output to return success
      allow(executor).to receive(:execute_with_output).and_return(true)
    end

    context 'with workspace' do
      it 'builds archive using -workspace flag' do
        expect(executor).to receive(:execute_with_output) do |cmd|
          expect(cmd).to be_an(Array)
          expect(cmd.first(2)).to eq(%w[xcodebuild archive])
          expect(cmd).to include('-workspace', project_info[:path], '-scheme', scheme,
                                 '-configuration', configuration)
          true
        end

        executor.build!(target_name, configuration, scheme: scheme)
      end
    end

    context 'with xcodeproj' do
      let(:project_info) do
        {
          type: :project,
          path: '/path/to/App.xcodeproj',
          directory: '/path/to',
          framework: :native
        }
      end
      let(:executor) { described_class.new(project_info, parser) }

      it 'builds archive using -project flag' do
        allow(executor).to receive(:execute_with_output).and_return(true)
        allow(File).to receive(:exist?).and_return(true)

        expect(executor).to receive(:execute_with_output) do |cmd|
          expect(cmd).to be_an(Array)
          expect(cmd).to include('-project', project_info[:path], '-scheme', scheme,
                                 '-configuration', configuration)
          true
        end

        executor.build!(target_name, configuration, scheme: scheme)
      end
    end

    context 'with automatic signing' do
      it 'includes -allowProvisioningUpdates flag' do
        expect(executor).to receive(:execute_with_output) do |cmd|
          expect(cmd).to include('-allowProvisioningUpdates')
          true
        end

        executor.build!(target_name, configuration, scheme: scheme, signing_style: 'Automatic')
      end
    end

    context 'with manual signing' do
      it 'does not include -allowProvisioningUpdates flag' do
        expect(executor).to receive(:execute_with_output) do |cmd|
          expect(cmd).to be_an(Array)
          expect(cmd).to include('-scheme', scheme)
          expect(cmd).not_to include('-allowProvisioningUpdates')
          true
        end

        executor.build!(target_name, configuration, scheme: scheme, signing_style: 'Manual')
      end
    end

    context 'when build succeeds' do
      it 'returns archive path' do
        result = executor.build!(target_name, configuration, scheme: scheme)

        expect(result).to match(%r{build/App-\d{8}-\d{6}\.xcarchive})
      end
    end

    context 'when build fails' do
      before do
        allow(executor).to receive(:execute_with_output).and_return(false)
      end

      it 'raises error' do
        expect do
          executor.build!(target_name, configuration, scheme: scheme)
        end.to raise_error(Mysigner::Build::Executor::BuildError, /Build failed/)
      end

      it 'mentions the log path in the error when execute_with_output set one' do
        log_path = '/path/to/build/last-build.log'
        allow(executor).to receive(:execute_with_output) do
          executor.instance_variable_set(:@last_build_log, log_path)
          false
        end

        expect do
          executor.build!(target_name, configuration, scheme: scheme)
        end.to raise_error(Mysigner::Build::Executor::BuildError, /Full log: #{Regexp.escape(log_path)}/)
      end
    end

    context 'when scheme is not provided' do
      it 'uses target name as scheme' do
        expect(executor).to receive(:execute_with_output) do |cmd|
          expect(cmd).to include('-scheme', target_name)
          true
        end

        executor.build!(target_name, configuration)
      end
    end
  end

  # Shell-safety: build_command must return an argv ARRAY, not a single
  # shell string. When it returned `cmd.join(' ')`, execute_with_output ran
  # it via IO.popen(String) → /bin/sh -c, so a scheme/bundle_id/path with a
  # space or shell metacharacter ($(), ;, backticks) was split or executed.
  describe '#build_command (private) — argv safety' do
    it 'returns an array with the scheme as a single intact element' do
      allow(parser).to receive(:target_platform).and_return(:ios)

      cmd = executor.send(:build_command, 'My Scheme; touch pwned', 'Release',
                          '/tmp/My App.xcarchive')

      expect(cmd).to be_an(Array)
      # The metachar-laden scheme and the space-containing archive path each
      # survive as ONE element — never concatenated into a shell string.
      expect(cmd).to include('My Scheme; touch pwned')
      expect(cmd).to include('/tmp/My App.xcarchive')
    end
  end

  # Direct tests for execute_with_output: this is the layer that captures
  # xcodebuild output to a log file and dumps the tail on failure. The
  # -quiet flag plus the keyword filter previously hid framework-loader
  # errors entirely; this spec keeps that from regressing.
  describe '#execute_with_output (private)' do
    let(:tmpdir) { Dir.mktmpdir }
    let(:log_path) { File.join(tmpdir, 'build', 'last-build.log') }
    let(:project_info) do
      {
        type: :workspace,
        path: File.join(tmpdir, 'App.xcworkspace'),
        directory: tmpdir,
        framework: :native
      }
    end
    let(:executor) { described_class.new(project_info, parser) }

    after { FileUtils.rm_rf(tmpdir) }

    # Stub IO.popen so it yields the lines we want, then run a real shell
    # command (`true` or `false`) so $CHILD_STATUS reflects the desired
    # exit code without involving xcodebuild.
    def fake_run(lines, success:)
      allow(IO).to receive(:popen) do |_cmd, _opts, &block|
        block.call(StringIO.new(lines.join))
        success ? `true` : `false`
      end
    end

    it 'writes every captured line to <project>/build/last-build.log' do
      fake_run(["warning: deprecated API\n", "noise\n", "** ARCHIVE SUCCEEDED **\n"], success: true)

      executor.send(:execute_with_output, 'xcodebuild archive')

      expect(File.exist?(log_path)).to be true
      contents = File.read(log_path)
      expect(contents).to include('warning: deprecated API')
      expect(contents).to include('noise')
      expect(contents).to include('ARCHIVE SUCCEEDED')
    end

    it 'returns true on a successful exit' do
      fake_run(["ok\n"], success: true)
      expect(executor.send(:execute_with_output, 'xcodebuild archive')).to be true
    end

    it 'returns false on a failed exit' do
      fake_run(["error: bad\n"], success: false)
      expect { executor.send(:execute_with_output, 'xcodebuild archive') }
        .to output.to_stdout # swallow the tail dump
      # second invocation to grab the return value
      fake_run(["error: bad\n"], success: false)
      expect(executor.send(:execute_with_output, 'xcodebuild archive')).to be false
    end

    it 'prints the log tail with the log path when the build fails' do
      lines = (1..120).map { |i| "line #{i}\n" }
      fake_run(lines, success: false)

      expect { executor.send(:execute_with_output, 'xcodebuild archive') }
        .to output(/Build output \(last \d+ lines\):.*line 120.*Full log: .*last-build\.log/m).to_stdout
    end

    it 'does NOT print the tail dump on success' do
      fake_run(["clean build\n"], success: true)

      expect { executor.send(:execute_with_output, 'xcodebuild archive') }
        .not_to output(/Build output \(last/).to_stdout
    end

    it 'records @last_build_log so build! can include it in the error message' do
      fake_run(["ok\n"], success: true)

      executor.send(:execute_with_output, 'xcodebuild archive')

      expect(executor.instance_variable_get(:@last_build_log)).to eq(log_path)
    end

    # The historical filter dropped any line that didn't contain "error:".
    # Framework loader failures (NSCocoaErrorDomain, dlopen, etc.) slipped
    # through. Even though they aren't surfaced live during the build, they
    # MUST end up in the log file so the tail dump can show them.
    it 'captures non-keyword lines (e.g. dlopen errors) to the log' do
      fake_run([
                 "DVTPlugInLoading: Failed to load com.apple.dt.IDESimulatorFoundation\n",
                 "Symbol not found: _$s12DVTDownloads21DownloadableAssetTypeO\n"
               ], success: false)

      expect { executor.send(:execute_with_output, 'xcodebuild archive') }
        .to output.to_stdout

      contents = File.read(log_path)
      expect(contents).to include('DVTPlugInLoading')
      expect(contents).to include('Symbol not found')
    end
  end
end
