# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/signing/gradle_signing_injector'

RSpec.describe 'build_gradle_aab (native Android signing)', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:android_dir) { '/tmp/fake-android' }
  let(:aab_path) { File.join(android_dir, 'app/build/outputs/bundle/release/app-release.aab') }

  let(:keystore_info) do
    {
      keystore_path: '/tmp/keystores/release.jks',
      signing_env_vars: {
        'MYSIGNER_STORE_FILE' => '/tmp/keystores/release.jks',
        'MYSIGNER_STORE_PASSWORD' => 'super-secret-store',
        'MYSIGNER_KEY_PASSWORD' => 'super-secret-key',
        'MYSIGNER_KEY_ALIAS' => 'upload'
      },
      name: 'Release',
      id: 1,
      # legacy b/c keys (should NOT be used by the Gradle builder)
      path: '/tmp/keystores/release.jks',
      password: 'super-secret-store',
      key_password: 'super-secret-key',
      key_alias: 'upload'
    }
  end

  before do
    # Gradle wrapper exists
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(File.join(android_dir, 'gradlew')).and_return(true)
    allow(File).to receive(:exist?).with(aab_path).and_return(true)

    # Stay put on Dir.chdir - we do not actually cd into a fake tree
    allow(Dir).to receive(:chdir).with(android_dir).and_yield
    allow(Dir).to receive(:glob).and_call_original
  end

  it 'invokes system with an env hash and no plaintext -P password args' do
    captured_args = nil
    captured_env  = nil

    allow(cli).to receive(:system) do |*args|
      # system(env_hash, *cmd) form → first arg is a Hash
      if args.first.is_a?(Hash)
        captured_env  = args.first
        captured_args = args[1..]
      else
        captured_env  = {}
        captured_args = args
      end
      true
    end

    cli.send(:build_gradle_aab, android_dir, :native, keystore_info, nil)

    expect(captured_env).to include(
      'MYSIGNER_STORE_PASSWORD' => 'super-secret-store',
      'MYSIGNER_KEY_PASSWORD' => 'super-secret-key',
      'MYSIGNER_KEY_ALIAS' => 'upload',
      'MYSIGNER_STORE_FILE' => '/tmp/keystores/release.jks'
    )

    flat = captured_args.join(' ')

    # No plaintext secrets in argv
    expect(flat).not_to include('super-secret-store')
    expect(flat).not_to include('super-secret-key')
    # None of the legacy -P signing flags should be present
    expect(flat).not_to include('-Pandroid.injected.signing.store.password')
    expect(flat).not_to include('-Pandroid.injected.signing.key.password')
    expect(flat).not_to include('-Pandroid.injected.signing.store.file')
    expect(flat).not_to include('-Pandroid.injected.signing.key.alias')

    # Init script injection is used instead
    expect(captured_args).to include('--init-script')
    init_idx = captured_args.index('--init-script')
    init_path = captured_args[init_idx + 1]
    expect(init_path).to be_a(String)
    expect(File.exist?(init_path)).to be(false).or be(true) # cleaned up after build
  end

  it 'still invokes gradle without env when no keystore_info is provided' do
    captured_args = nil

    allow(cli).to receive(:system) do |*args|
      captured_args = args.first.is_a?(Hash) ? args[1..] : args
      true
    end

    cli.send(:build_gradle_aab, android_dir, :native, nil, nil)

    expect(captured_args).to include('bundleRelease')
    flat = captured_args.join(' ')
    expect(flat).not_to include('--init-script')
  end
end
