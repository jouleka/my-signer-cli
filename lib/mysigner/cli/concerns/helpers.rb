# frozen_string_literal: true

module Mysigner
  class CLI < Thor
    module Concerns
      module Helpers
        # Helper for timing operations
        def with_timing(_label)
          start = Time.now
          result = yield
          duration = Time.now - start
          [result, duration]
        end

        def format_duration(seconds)
          if seconds < 60
            "#{seconds.round}s"
          elsif seconds < 3600
            minutes = (seconds / 60).floor
            secs = (seconds % 60).round
            "#{minutes}m #{secs}s"
          else
            hours = (seconds / 3600).floor
            minutes = ((seconds % 3600) / 60).floor
            "#{hours}h #{minutes}m"
          end
        end

        def format_bytes(bytes)
          if bytes < 1024
            "#{bytes} B"
          elsif bytes < 1024 * 1024
            "#{(bytes / 1024.0).round(1)} KB"
          else
            "#{(bytes / (1024.0 * 1024)).round(1)} MB"
          end
        end

        # Client-side UDID validity check for iOS devices. Matches the two
        # formats Apple uses: 25-character alphanumeric (older devices pre-
        # iPhone X) and 40-character hex, optionally with a single dash after
        # the first 8 chars (newer). Also rejects obviously synthetic values
        # (all zeros, single-character repeats) that Apple's dev-portal
        # sandbox has been known to accept even though they can never match
        # a real device.
        def valid_ios_udid?(udid)
          return false if udid.nil? || udid.strip.empty?

          normalized = udid.strip.upcase

          # 25-char legacy UDID: alphanumeric
          legacy = normalized.match?(/\A[0-9A-F]{25}\z/)

          # 40-char modern UDID: hex, optional dash after first 8 chars
          modern_plain = normalized.match?(/\A[0-9A-F]{40}\z/)
          modern_dashed = normalized.match?(/\A[0-9A-F]{8}-[0-9A-F]{16}\z/) # 8-16 form some tools emit (older spec)
          modern_full_dashed = normalized.match?(/\A[0-9A-F]{8}-[0-9A-F]{32}\z/) # 8-32 (what xcrun outputs)

          return false unless legacy || modern_plain || modern_dashed || modern_full_dashed

          hex_only = normalized.delete('-')
          # Reject trivially synthetic UDIDs. A real UDID has at least 4
          # distinct hex characters among its 25/40 positions; "000…" or
          # "AAAA…" or "012345…" style sequences flunk that.
          distinct = hex_only.chars.uniq.size
          return false if distinct < 4

          true
        end

        def load_config
          # mysigner-22 — local-only mode is allowed to run with ZERO MySigner
          # auth: no ~/.mysigner/config.yml, no API token, no login. Return a
          # blank Config sentinel and skip both the load and the
          # "Not logged in" exit. Callers must treat the returned config as
          # opaque (no api_url, no api_token, no organization_id) and must
          # also treat create_client(config) as returning nil.
          return blank_local_only_config if local_only?

          # CI/CD mode: prefer environment variables when set
          return Config.from_env if Config.env_configured?

          config = Config.new

          unless config.exists?
            error "Not logged in. Run 'mysigner login' first."
            say ''
            say 'Tip: For CI/CD, set these environment variables instead:', :yellow
            say '  export MYSIGNER_API_TOKEN=your_token', :yellow
            say '  export MYSIGNER_ORG_ID=your_org_id', :yellow
            say '  export MYSIGNER_API_URL=https://mysigner.dev  # optional', :yellow
            say '  export MYSIGNER_EMAIL=you@example.com          # optional', :yellow
            say ''
            # Discoverability: a first-time user who doesn't want a MySigner
            # account at all (BYO-credentials, no server orchestration) needs
            # to know `--local-only` exists. Without this tip the only error
            # they see is "Not logged in", which strongly implies signup is
            # the only path forward.
            say 'Tip: To skip MySigner entirely and ship locally with your own', :yellow
            say 'Apple/Google credentials, use --local-only:', :yellow
            say '  mysigner --local-only ship appstore', :yellow
            say '  (auto-discovers ASC .p8 from ~/.appstoreconnect/private_keys/,', :yellow
            say '   Google Play SA-JSON from GOOGLE_APPLICATION_CREDENTIALS / eas.json,', :yellow
            say '   keystore from key.properties / eas.json — or set them via flags / env.)', :yellow
            say '  Note: build / ship / sign work fully local; account commands', :yellow
            say '  (orgs / switch / sync) still need a My Signer login.', :yellow
            say '  See "Local-only mode" section in README.', :yellow
            exit 1
          end

          config.load

          # Surface an unreadable stored token as a clean re-login prompt here,
          # at the auth gate, instead of letting the decrypt error explode later
          # inside create_client / Config#display. (api_token decrypts lazily.)
          begin
            config.api_token
          rescue Mysigner::ConfigError
            error 'Your saved login is unreadable (encryption key changed or ' \
                  'config copied between machines).'
            say "Run 'mysigner logout' then 'mysigner login' to re-authenticate.", :yellow
            say 'Or run with --local-only to skip MySigner entirely.', :yellow
            exit 1
          end

          config
        end

        def create_client(config)
          # mysigner-22 — in local-only mode every MySigner API touchpoint is
          # supposed to be bypassed at the call site. Returning nil here makes
          # an accidental `client.get(...)` fail loud (NoMethodError on nil)
          # rather than silently re-introducing a server hit.
          return nil if local_only?

          Client.new(
            api_url: config.api_url,
            api_token: config.api_token,
            user_email: config.user_email
          )
        end

        # mysigner-22 — a Config built without touching disk, ENV, or the
        # encryption key. We deliberately bypass Config#initialize (which
        # auto-loads ~/.mysigner/config.yml when it exists) because the whole
        # point of local-only is to work on a machine where that file might
        # not exist or might be unreadable (e.g. broken Keychain key).
        # Callers only read `current_organization_id` / `api_url` / etc., all
        # of which legitimately return nil here.
        def blank_local_only_config
          config = Config.allocate
          config.instance_variable_set(:@api_url, nil)
          config.instance_variable_set(:@user_email, nil)
          config.instance_variable_set(:@current_organization_id, nil)
          config.instance_variable_set(:@organizations, {})
          config.instance_variable_set(:@encryption_enabled, false)
          config.instance_variable_set(:@from_env, false)
          # The whole point of this sentinel is to BE a local-only config —
          # set @local_only = true so `config.local_only?` (and any caller
          # reading `config.local_only`) agrees.
          config.instance_variable_set(:@local_only, true)
          config
        end

        def error(message)
          say "✗ Error: #{message}", :red
        end

        # True on macOS. iOS building/signing (Xcode, xcodebuild, the keychain)
        # only works there; iOS-only commands call require_macos! to fail with a
        # clear message instead of a raw "xcodebuild: not found" backtrace.
        def macos?
          !(RbConfig::CONFIG['host_os'] =~ /darwin/i).nil?
        end

        # Guard for iOS-only commands. On non-macOS, explain plainly and point
        # the user at the Android path that DOES work cross-platform, then exit.
        def require_macos!(command_label = 'This command')
          return if macos?

          error "#{command_label} requires macOS with Xcode."
          say ''
          say 'iOS building, signing, and uploading only work on a Mac (they use Xcode).', :yellow
          say 'On Linux or Windows you can still build and ship Android:', :yellow
          say '  mysigner ship internal --platform android', :cyan
          say '  mysigner android build', :cyan
          exit 1
        end

        # Local-only mode is active when any of, in precedence order:
        #   1. --local-only / --no-local-only flag on this invocation
        #   2. MYSIGNER_LOCAL_ONLY env var
        #   3. `local_only: true` in ~/.mysigner/config.yml
        # `Config.local_only?` (class method) walks #2 then #3.
        def local_only?
          return options[:local_only] unless options[:local_only].nil?

          Mysigner::Config.local_only?
        end

        # mysigner-22 Phase 5 — resolve ASC creds via the cascade (flag →
        # env → keychain → ~/.appstoreconnect → prompt), surface a clear
        # error and exit 1 on miss. Logs the winning source on stderr so
        # CI runs leave an audit trail of where the credential came from.
        # Returns a Mysigner::CredentialResolver::AscCreds struct.
        def resolve_local_asc_creds_or_exit
          require 'mysigner/credential_resolver'
          creds = Mysigner::CredentialResolver.resolve_asc(options: options.to_h)
          warn "[mysigner] ASC credentials source: #{creds.source}" if $stderr.respond_to?(:tty?) && $stderr.tty?
          creds
        rescue Mysigner::CredentialResolver::CredentialNotFoundError,
               Mysigner::CredentialResolver::AmbiguousCredentialsError => e
          # Preserve the historical wording the CLI specs were written
          # against ("No local ASC credentials found") so users and tests
          # have a stable identifier, while including the resolver's
          # multi-line cascade trace + override knob list right after it.
          say "✗ No local ASC credentials found via `mysigner onboard --local-only` or other sources:\n#{e.message}",
              :red
          exit 1
        end

        # mysigner-22 Phase 5 — Google Play counterpart of
        # resolve_local_asc_creds_or_exit. Same semantics: pre-resolve so the
        # CLI can fail fast before the build kicks off.
        def resolve_local_play_creds_or_exit
          require 'mysigner/credential_resolver'
          creds = Mysigner::CredentialResolver.resolve_play(options: options.to_h)
          warn "[mysigner] Google Play credentials source: #{creds.source}" if $stderr.respond_to?(:tty?) && $stderr.tty?
          creds
        rescue Mysigner::CredentialResolver::CredentialNotFoundError,
               Mysigner::CredentialResolver::AmbiguousCredentialsError => e
          say "✗ No local Google Play credentials found via `mysigner onboard --local-only` or other sources:\n#{e.message}",
              :red
          exit 1
        end

        # mysigner-22 Phase 7 — Android keystore counterpart of the ASC/Play
        # resolvers. Pre-resolves the keystore (path + passwords + alias) via
        # the cascade so `ship android --local-only` can skip the MySigner
        # server entirely.
        def resolve_local_android_keystore_or_exit
          require 'mysigner/credential_resolver'
          creds = Mysigner::CredentialResolver.resolve_android_keystore(options: options.to_h)
          warn "[mysigner] Android keystore source: #{creds.source}" if $stderr.respond_to?(:tty?) && $stderr.tty?
          creds
        rescue Mysigner::CredentialResolver::CredentialNotFoundError,
               Mysigner::CredentialResolver::AmbiguousCredentialsError => e
          say "✗ No local Android keystore found:\n#{e.message}", :red
          exit 1
        end

        # One-time banner on stderr (TTY only) so users know they've opted
        # into local-only mode. Module-level guard ensures it fires at most
        # once per CLI invocation, even if multiple commands call it.
        # (Module instance var, not @@, to avoid the class-var smell — every
        # instance method sees the same Helpers module object.)
        def emit_local_only_banner
          return if Helpers.banner_emitted?
          return unless $stderr.respond_to?(:tty?) && $stderr.tty?

          Helpers.mark_banner_emitted!
          # Honest scope: credential transport is what local-only currently
          # guards. Non-credential MySigner endpoints (app/build registry,
          # keystore download, etc.) are still used. Documented in the
          # local-only docs (mysigner-45).
          warn '[mysigner] local-only mode active — signing credentials stay on this machine ' \
               '(other MySigner APIs may still be used; see docs).'
        end

        # Server-only command guard. SERVER commands (apps, orgs, sync,
        # certificates, etc.) hit MySigner-side resources and have no
        # local equivalent. Print a clean explanation and exit 2 when
        # local-only mode is active, instead of letting load_config bail
        # with the generic "Not logged in" path.
        def exit_unless_local_supported!(command_name)
          return unless local_only?

          say "✗ `#{command_name}` manages MySigner-side resources and " \
              "isn't available in local-only mode.", :red
          say ''
          say 'Disable persistently:  mysigner config set local-only false', :yellow
          say "Override for one call: mysigner --no-local-only #{command_name}", :yellow
          exit 2
        end

        class << self
          def banner_emitted?
            @local_only_banner_emitted == true
          end

          def mark_banner_emitted!
            @local_only_banner_emitted = true
          end

          def reset_banner!
            @local_only_banner_emitted = false
          end
        end
      end
    end
  end
end
