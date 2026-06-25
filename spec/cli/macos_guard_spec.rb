# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'

# iOS building/signing only works on macOS. These guards make iOS-only commands
# fail with a clear, actionable message on Linux/Windows instead of crashing
# later with a raw "xcodebuild: not found" backtrace.
RSpec.describe 'iOS-only commands require macOS' do
  let(:cli) { Mysigner::CLI.new }

  before do
    # Simulate a non-macOS host (the spec_helper default is macOS=true).
    allow(cli).to receive(:macos?).and_return(false)
  end

  # Nested form: the inner expectation swallows the SystemExit while the outer
  # one captures the stdout the guard printed first.
  def expect_macos_required(pattern = /requires macOS with Xcode/, &block)
    expect do
      expect(&block).to raise_error(SystemExit)
    end.to output(pattern).to_stdout
  end

  it 'ship testflight exits with a macOS-required message and never loads config' do
    expect(cli).not_to receive(:load_config)
    expect_macos_required { cli.ship('testflight') }
  end

  it 'build exits with a macOS-required message' do
    expect_macos_required { cli.build }
  end

  it 'export exits with a macOS-required message' do
    expect_macos_required { cli.export('/tmp/whatever.xcarchive') }
  end

  it 'the message points the user at the Android path that works cross-platform' do
    expect_macos_required(/--platform android/) { cli.ship('appstore') }
  end

  it 'does NOT block an Android target (routing happens before the guard)' do
    allow(cli).to receive(:ship_android)
    expect { cli.ship('internal') }.not_to raise_error
  end
end
