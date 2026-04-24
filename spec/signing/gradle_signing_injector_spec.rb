# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/signing/gradle_signing_injector'

RSpec.describe Mysigner::Signing::GradleSigningInjector do
  subject(:injector) { described_class.new }

  it 'generates a Gradle init script containing the override guard' do
    path = injector.write_init_script!
    content = File.read(path)
    expect(content).to include('MYSIGNER_STORE_PASSWORD')
    expect(content).to include('afterEvaluate')
    expect(content).to include('alreadyConfigured')
    injector.cleanup!
  end

  it 'creates an env_vars hash for Process.spawn' do
    env = injector.env_vars(keystore_path: '/tmp/k.jks', store_password: 's', key_password: 'k', key_alias: 'a')
    expect(env).to eq(
      'MYSIGNER_STORE_FILE' => '/tmp/k.jks',
      'MYSIGNER_STORE_PASSWORD' => 's',
      'MYSIGNER_KEY_PASSWORD' => 'k',
      'MYSIGNER_KEY_ALIAS' => 'a'
    )
  end

  it 'cleanup! removes the tmpdir' do
    path = injector.write_init_script!
    tmpdir = File.dirname(path)
    expect(Dir.exist?(tmpdir)).to be(true)
    injector.cleanup!
    expect(Dir.exist?(tmpdir)).to be(false)
  end
end
