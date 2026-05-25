# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'openssl'
require 'rbconfig'

module Mysigner
  # Local-only credential store for the CLI's local-only mode
  # (Epic mysigner-22). Credentials never leave the user's machine.
  #
  # On macOS, secrets live in the system Keychain under a dedicated service
  # (separate from Config's encryption-key service). On other platforms, the
  # secret is AES-256-GCM-encrypted under the same per-machine key Config
  # already manages, and stored as a 0600 file in ~/.mysigner/credentials/.
  #
  # `list(kind:)` reads a small index file. The index is a convenience for
  # enumeration only; the Keychain entries (or the per-credential encrypted
  # files) are the authoritative source. If the index drifts, callers should
  # treat fetch as the source of truth.
  module LocalCredentials
    KINDS = %i[asc google_play apple_ads android_keystore].freeze

    KEYCHAIN_SERVICE = 'com.mysigner.cli.credentials'
    CREDENTIALS_DIR = File.expand_path('~/.mysigner/credentials').freeze
    INDEX_DIR = File.join(CREDENTIALS_DIR, '.index').freeze

    class LocalCredentialsError < StandardError; end

    class << self
      def store(kind:, id:, secret:)
        validate!(kind: kind, id: id, secret: secret)

        if macos?
          store_in_keychain(kind, id, secret)
        else
          store_in_file(kind, id, secret)
        end

        update_index(kind, id, :add)
        true
      end

      def fetch(kind:, id:)
        validate_kind_and_id!(kind: kind, id: id)

        if macos?
          fetch_from_keychain(kind, id)
        else
          fetch_from_file(kind, id)
        end
      end

      def delete(kind:, id:)
        validate_kind_and_id!(kind: kind, id: id)

        if macos?
          delete_from_keychain(kind, id)
        else
          delete_from_file(kind, id)
        end

        update_index(kind, id, :remove)
        true
      end

      def list(kind:)
        validate_kind!(kind)

        index_path = index_file_for(kind)
        return [] unless File.exist?(index_path)

        data = JSON.parse(File.read(index_path))
        return [] unless data.is_a?(Array)

        data.map(&:to_s)
      rescue JSON::ParserError
        # A corrupt index is non-fatal — the per-credential entries are
        # authoritative. Return empty so the caller can re-store and rebuild.
        []
      end

      def exists?(kind:, id:)
        !fetch(kind: kind, id: id).nil?
      end

      private

      # ---- validation -----------------------------------------------------

      def validate!(kind:, id:, secret:)
        validate_kind_and_id!(kind: kind, id: id)
        raise ArgumentError, 'secret must be a non-empty String' if secret.nil? || !secret.is_a?(String) || secret.empty?
      end

      def validate_kind_and_id!(kind:, id:)
        validate_kind!(kind)
        raise ArgumentError, 'id must be a non-empty String' if id.nil? || !id.is_a?(String) || id.strip.empty?
        # The macOS `security` CLI uses getopt-style flag parsing on the
        # `-a <account>` value, so an id like `-D` would be parsed as a
        # different flag (there's no `--` end-of-options delimiter we can
        # use). NUL bytes raise an opaque low-level error from Open3.
        # Reject both up front with a clear message — real-world ids
        # (key_id, client_email, etc.) never start with `-` or contain NUL.
        raise ArgumentError, 'id must not contain NUL bytes' if id.include?("\0")
        raise ArgumentError, 'id must not start with "-" — would be parsed as a security CLI flag' if id.start_with?('-')
      end

      def validate_kind!(kind)
        return if KINDS.include?(kind)

        raise ArgumentError, "unknown kind: #{kind.inspect} (allowed: #{KINDS.inspect})"
      end

      # ---- platform -------------------------------------------------------

      def macos?
        RbConfig::CONFIG['host_os'] =~ /darwin/i
      end

      # ---- macOS Keychain backend ----------------------------------------

      # We shell out via Open3 with an array argv so the shell never expands
      # the user-supplied id (which is part of `account`). This is stricter
      # than Config's backtick idiom — flagged in the implementation report
      # as a deliberate Rule 7 divergence for security.
      def store_in_keychain(kind, id, secret)
        encoded = Base64.strict_encode64(secret)
        account = account_for(kind, id)

        # Delete existing entry first to keep store idempotent — matches the
        # same idiom in Config#store_key_in_keychain.
        Open3.capture3('security', 'delete-generic-password',
                       '-s', KEYCHAIN_SERVICE, '-a', account)

        _, stderr, status = Open3.capture3('security', 'add-generic-password',
                                           '-s', KEYCHAIN_SERVICE, '-a', account,
                                           '-w', encoded)

        return if status.success?

        raise LocalCredentialsError, "failed to store credential in keychain: #{stderr.strip}"
      end

      def fetch_from_keychain(kind, id)
        account = account_for(kind, id)
        stdout, _, status = Open3.capture3('security', 'find-generic-password',
                                           '-s', KEYCHAIN_SERVICE, '-a', account, '-w')

        return nil unless status.success?

        encoded = stdout.strip
        return nil if encoded.empty?

        Base64.strict_decode64(encoded)
      rescue ArgumentError
        # Base64 decode failed — treat as missing rather than crashing the caller.
        nil
      end

      def delete_from_keychain(kind, id)
        account = account_for(kind, id)
        # Always returns truthy: `security` returns non-zero when the entry
        # doesn't exist, which is fine for an idempotent delete.
        Open3.capture3('security', 'delete-generic-password',
                       '-s', KEYCHAIN_SERVICE, '-a', account)
        true
      end

      def account_for(kind, id)
        "#{kind}:#{id}"
      end

      # ---- file fallback backend -----------------------------------------

      def store_in_file(kind, id, secret)
        ensure_dir(kind_dir(kind))
        File.write(file_for(kind, id), encrypt(secret))
        File.chmod(0o600, file_for(kind, id))
      rescue StandardError => e
        raise LocalCredentialsError, "failed to write credential file: #{e.message}"
      end

      def fetch_from_file(kind, id)
        path = file_for(kind, id)
        return nil unless File.exist?(path)

        decrypt(File.read(path))
      rescue StandardError => e
        raise LocalCredentialsError, "failed to read credential file: #{e.message}"
      end

      def delete_from_file(kind, id)
        FileUtils.rm_f(file_for(kind, id))
        true
      end

      def kind_dir(kind)
        File.join(CREDENTIALS_DIR, kind.to_s)
      end

      def file_for(kind, id)
        # Base64-urlsafe so any id (including ones with '/') maps to one filename.
        encoded = Base64.urlsafe_encode64(id, padding: false)
        File.join(kind_dir(kind), encoded)
      end

      def ensure_dir(path)
        FileUtils.mkdir_p(path)
        File.chmod(0o700, path)
      end

      # ---- index for list() ----------------------------------------------

      def index_file_for(kind)
        File.join(INDEX_DIR, "#{kind}.json")
      end

      def update_index(kind, id, operation)
        ensure_dir(INDEX_DIR)
        path = index_file_for(kind)

        current = read_index(path)

        case operation
        when :add then current = (current + [id]).uniq
        when :remove then current -= [id]
        end

        File.write(path, JSON.generate(current))
        File.chmod(0o600, path)
      end

      def read_index(path)
        return [] unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Array) ? parsed : []
      rescue JSON::ParserError
        []
      end

      # ---- AES-256-GCM wrap of the per-machine key from Config -----------

      def encrypt(plaintext)
        cipher = OpenSSL::Cipher.new('aes-256-gcm')
        cipher.encrypt
        cipher.key = machine_key
        iv = cipher.random_iv

        encrypted = cipher.update(plaintext) + cipher.final
        auth_tag = cipher.auth_tag

        [Base64.strict_encode64(iv),
         Base64.strict_encode64(auth_tag),
         Base64.strict_encode64(encrypted)].join(':')
      end

      def decrypt(blob)
        iv_b64, tag_b64, data_b64 = blob.split(':', 3)
        iv = Base64.strict_decode64(iv_b64)
        auth_tag = Base64.strict_decode64(tag_b64)
        encrypted = Base64.strict_decode64(data_b64)

        decipher = OpenSSL::Cipher.new('aes-256-gcm')
        decipher.decrypt
        decipher.key = machine_key
        decipher.iv = iv
        decipher.auth_tag = auth_tag

        decipher.update(encrypted) + decipher.final
      end

      def machine_key
        Mysigner::Config.new.fetch_encryption_key
      end
    end
  end
end
