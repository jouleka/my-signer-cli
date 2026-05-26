# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'mysigner/cleanup/private_keys_purger'

RSpec.describe Mysigner::Cleanup::PrivateKeysPurger do
  around do |ex|
    Dir.mktmpdir do |home|
      @home = home
      original_home = Dir.home
      ENV['HOME'] = home
      begin
        ex.run
      ensure
        ENV['HOME'] = original_home
      end
    end
  end

  it 'purges AuthKey_*.p8 from ~/.private_keys AND ~/.appstoreconnect/private_keys' do
    FileUtils.mkdir_p("#{@home}/.private_keys")
    FileUtils.mkdir_p("#{@home}/.appstoreconnect/private_keys")
    File.write("#{@home}/.private_keys/AuthKey_ABC.p8", 'fake')
    File.write("#{@home}/.appstoreconnect/private_keys/AuthKey_XYZ.p8", 'fake')
    File.write("#{@home}/.private_keys/notmatched.txt", 'keep')

    described_class.new.call

    expect(File).not_to exist("#{@home}/.private_keys/AuthKey_ABC.p8")
    expect(File).not_to exist("#{@home}/.appstoreconnect/private_keys/AuthKey_XYZ.p8")
    expect(File).to exist("#{@home}/.private_keys/notmatched.txt")
  end

  it 'writes the purged marker file and skips next time' do
    FileUtils.mkdir_p("#{@home}/.private_keys")
    File.write("#{@home}/.private_keys/AuthKey_NEW.p8", 'fake')

    described_class.new.call
    expect(File).to exist("#{@home}/.mysigner/.private_keys_purged")

    File.write("#{@home}/.private_keys/AuthKey_NEW2.p8", 'fake')
    described_class.new.call
    expect(File).to exist("#{@home}/.private_keys/AuthKey_NEW2.p8")
  end
end
