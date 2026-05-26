# frozen_string_literal: true

require 'fileutils'

module Mysigner
  module Cleanup
    class PrivateKeysPurger
      LEGACY_DIRS = [
        '~/.private_keys',
        '~/.appstoreconnect/private_keys'
      ].freeze

      def marker_path
        File.expand_path('~/.mysigner/.private_keys_purged')
      end

      def call
        return if File.exist?(marker_path)

        LEGACY_DIRS.each do |dir|
          expanded = File.expand_path(dir)
          Dir.glob(File.join(expanded, 'AuthKey_*.p8')).each do |path|
            File.delete(path)
            warn "mysigner: deleted legacy private key #{path}" if ENV['MYSIGNER_VERBOSE'] == '1'
          rescue Errno::ENOENT
            # Raced with another process — already gone.
          rescue Errno::EACCES, Errno::EPERM => e
            # Owned by another user. Skip this file but keep going so the
            # marker still gets written — otherwise the purger retries on
            # every CLI invocation and keeps failing on the same file.
            warn "mysigner: could not delete #{path} (#{e.class}); skipping" if ENV['MYSIGNER_VERBOSE'] == '1'
          end
        end

        FileUtils.mkdir_p(File.dirname(marker_path))
        FileUtils.touch(marker_path)
      end
    end
  end
end
