# frozen_string_literal: true

require 'base64'
require 'json'
require 'tempfile'

module Mysigner
  # mysigner-22 Phase 5 — credential auto-discovery cascade for `--local-only`
  # mode. Replaces the original Keychain-only lookup with a fastlane-style
  # cascade: explicit per-command flags → env vars users already set (Apple's
  # APP_STORE_CONNECT_API_KEY_* and Google's GOOGLE_APPLICATION_CREDENTIALS) →
  # Keychain (`onboard --local-only` store) → standard on-disk locations →
  # interactive prompt (TTY only — never in CI).
  #
  # The resolver is the ONLY place that knows about the cascade. Uploaders
  # receive the resolved Struct and don't touch ENV / disk / prompts directly,
  # which keeps the wiring testable (Rule 9: tests verify the cascade, not the
  # uploader plumbing).
  #
  # Backward-compat contract: vault mode (no `--local-only`) never calls this
  # module. The `LocalCredentials` API is unchanged — it just becomes one
  # source in the cascade rather than the only one.
  module CredentialResolver
    # Both Structs include `source` so the caller can log which leg of the
    # cascade won. The CLI prints it before each ship so non-interactive runs
    # (CI) have an audit trail of where the credential came from.
    AscCreds  = Struct.new(:key_id, :issuer_id, :p8_pem, :source)
    PlayCreds = Struct.new(:sa_json, :client_email, :source)
    # mysigner-22 Phase 7 — Android signing keystore credentials.
    # `keystore_path` is always an on-disk path (the Gradle signing pipeline
    # expects a file, not bytes). `tmpfile` is held so the Tempfile object
    # isn't GC'd before the process exits — when the resolver materializes a
    # Keychain-stored .jks blob to disk, we keep the Tempfile reference here
    # so the file survives until the CLI process ends.
    AndroidKeystoreCreds = Struct.new(
      :keystore_path, :keystore_password, :key_alias, :key_password, :source, :tmpfile
    )

    # Raised when every cascade step fails AND we cannot prompt (non-TTY).
    # The message lists every source tried plus the exact knob (flag / env /
    # onboard command / disk location) the user can set to fix it.
    class CredentialNotFoundError < StandardError; end

    # Raised when the cascade finds multiple candidates at a tier that can't
    # auto-disambiguate (e.g. several Keychain entries, several .p8 files on
    # disk). Distinct from "not found" because the fix is different — pick one
    # via a flag/env, don't go re-onboard.
    class AmbiguousCredentialsError < StandardError; end

    # Apple's officially-blessed on-disk location for ASC private keys,
    # documented in WWDC sessions and used by altool / xcrun / fastlane.
    APPLE_PRIVATE_KEYS_DIR = File.expand_path('~/.appstoreconnect/private_keys').freeze

    # Common file names users put service-account JSON under at a project root.
    PLAY_PROJECT_FILE_NAMES = %w[
      play-credentials.json
      service-account.json
      play-service-account.json
    ].freeze

    # Walk up at most this many parent directories looking for project-sniff
    # files. Three levels covers the common monorepo-with-app-subdir layout
    # without surprising the user by reaching into unrelated trees.
    PROJECT_SNIFF_MAX_DEPTH = 3

    # Project-sniff filenames for Android signing config. `android/key.properties`
    # is the Flutter convention (the `flutter create` template writes it);
    # `android/keystore.properties` and a root-level `key.properties` are seen
    # in a few Gradle-only setups (the docs use both names interchangeably).
    # First match wins.
    ANDROID_KEY_PROPERTIES_FILES = [
      'android/key.properties',
      'android/keystore.properties',
      'key.properties'
    ].freeze

    # Human-readable labels for the four cascade pieces. Used by the
    # not-found error message so each `missing` symbol prints something
    # the user can map back to a flag/env/sniff-key.
    ANDROID_MISSING_LABELS = {
      path: 'keystore path',
      keystore_password: 'keystore password',
      key_alias: 'key alias',
      key_password: 'key password'
    }.freeze

    class << self
      # @param options [Hash] Thor options hash with --asc-key-path/id/issuer-id
      # @param env     [Hash] ENV substitute for testability
      # @param stdin   [IO]   $stdin substitute (we check #tty? for prompt gating)
      # @param stderr  [IO]   $stderr substitute (for the prompt itself)
      # @return [AscCreds]
      # @raise  [CredentialNotFoundError] when nothing usable was found and we can't prompt
      def resolve_asc(options: {}, env: ENV, stdin: $stdin, stderr: $stderr)
        tried = []

        # Tier 1: per-command CLI flags (highest precedence). If all three are
        # present we short-circuit; partial flags layer in below.
        flag_path   = string_option(options, :asc_key_path)
        flag_key_id = string_option(options, :asc_key_id)
        flag_issuer = string_option(options, :asc_issuer_id)
        if flag_path && flag_key_id && flag_issuer
          pem = read_pem!(flag_path, label: '--asc-key-path')
          tried << "flag: --asc-key-path=#{flag_path}"
          return AscCreds.new(key_id: flag_key_id, issuer_id: flag_issuer, p8_pem: pem, source: :flag)
        end

        # Tier 2: env vars (fastlane convention).
        env_path   = string_env(env, 'APP_STORE_CONNECT_API_KEY_PATH')
        env_key_id = string_env(env, 'APP_STORE_CONNECT_API_KEY_ID')
        env_issuer = string_env(env, 'APP_STORE_CONNECT_API_KEY_ISSUER_ID')

        # Tier 3: Keychain — list yields zero / one / many; "many without
        # disambiguator" is an explicit ambiguous-error rather than silently
        # picking the first. WHY: the old uploader took .first quietly, which
        # was fine when only `onboard --local-only` could write entries but is
        # dangerous now that users may layer flags/env on top.
        keychain_ids = safe_list_keychain(:asc)
        keychain_id  = pick_keychain_id(keychain_ids, hint: flag_key_id || env_key_id, label: 'ASC')
        tried << "keychain: #{keychain_ids.length} entr#{keychain_ids.length == 1 ? 'y' : 'ies'}"

        # Tier 4: disk scan. Skip entirely when a higher tier (flag or env)
        # already supplies a .p8 path — disk can't add anything we'd prefer.
        # WHY: scan_apple_private_keys_dir raises AmbiguousCredentialsError on
        # multiple .p8 files, and that error is misleading when the user has
        # already pointed at one via --asc-key-path / APP_STORE_CONNECT_API_KEY_PATH.
        # "Higher tier wins" means the lower tier shouldn't even probe.
        disk_path, disk_key_id =
          if flag_path || env_path
            [nil, nil]
          else
            scan_apple_private_keys_dir(tried)
          end

        # Stitch together the highest-priority *partial* tier first, then fill
        # the missing fields from lower tiers. This lets "disk found the .p8
        # but no issuer_id env" continue down to env then to prompt without
        # restarting the cascade. Pieces are passed as one hash to keep the
        # helper under the parameter-list cop limit.
        path, key_id, issuer_id, source = assemble_asc_pieces(
          flag_path: flag_path, flag_key_id: flag_key_id, flag_issuer: flag_issuer,
          env_path: env_path, env_key_id: env_key_id, env_issuer: env_issuer,
          keychain_id: keychain_id, disk_path: disk_path, disk_key_id: disk_key_id
        )

        # Keychain shortcut: when keychain holds the (key_id, issuer_id, pem)
        # triple we don't need disk/env for anything.
        if source == :keychain
          envelope = fetch_keychain_envelope(:asc, key_id, label: 'ASC')
          return AscCreds.new(
            key_id: key_id,
            issuer_id: envelope.fetch('issuer_id'),
            p8_pem: envelope.fetch('p8_pem'),
            source: :keychain
          )
        end

        # All other tiers need a PEM read from disk.
        pem = path ? read_pem!(path, label: source_label(source)) : nil

        # Final fallback: prompt only when STDIN is a TTY. CI must fail loud.
        if path.nil? || key_id.nil? || issuer_id.nil?
          unless stdin.respond_to?(:tty?) && stdin.tty?
            raise CredentialNotFoundError, asc_not_found_message(
              tried: tried,
              missing: { path: path.nil?, key_id: key_id.nil?, issuer_id: issuer_id.nil? }
            )
          end

          if path.nil?
            path = prompt(stderr, stdin, 'Path to your App Store Connect .p8 private key:')
            pem = read_pem!(File.expand_path(path), label: 'prompt')
          end
          key_id    ||= derive_key_id_from_filename(path) || prompt(stderr, stdin, 'App Store Connect Key ID:')
          issuer_id ||= prompt(stderr, stdin, 'App Store Connect Issuer ID (UUID):')
          # Only overwrite source to :prompt when the .p8 path itself was
          # prompted (source.nil? means no higher tier supplied it). When the
          # path came from env/flag/keychain/disk and only issuer_id was
          # prompted in, preserve the originating source — the audit log
          # should attribute the credential to where the primary material
          # (the .p8) came from; issuer_id is metadata.
          source ||= :prompt
        end

        AscCreds.new(key_id: key_id, issuer_id: issuer_id, p8_pem: pem, source: source)
      end

      # @param options [Hash] Thor options with --play-credentials
      # @param env     [Hash]
      # @param stdin   [IO]
      # @param stderr  [IO]
      # @param cwd     [String] starting dir for project-sniff (Dir.pwd in prod)
      # @return [PlayCreds]
      # @raise  [CredentialNotFoundError]
      def resolve_play(options: {}, env: ENV, stdin: $stdin, stderr: $stderr, cwd: Dir.pwd)
        tried = []

        # Tier 1: flag.
        if (flag_path = string_option(options, :play_credentials))
          tried << "flag: --play-credentials=#{flag_path}"
          raw, email = read_sa_json!(flag_path, label: '--play-credentials')
          return PlayCreds.new(sa_json: raw, client_email: email, source: :flag)
        end

        # Tier 2: env (Google's documented convention).
        if (env_path = string_env(env, 'GOOGLE_APPLICATION_CREDENTIALS'))
          tried << "env: GOOGLE_APPLICATION_CREDENTIALS=#{env_path}"
          raw, email = read_sa_json!(env_path, label: 'GOOGLE_APPLICATION_CREDENTIALS')
          return PlayCreds.new(sa_json: raw, client_email: email, source: :env)
        end

        # Tier 3: Keychain.
        keychain_ids = safe_list_keychain(:google_play)
        tried << "keychain: #{keychain_ids.length} entr#{keychain_ids.length == 1 ? 'y' : 'ies'}"
        if keychain_ids.length == 1
          raw = fetch_keychain_raw(:google_play, keychain_ids.first, label: 'Google Play')
          return PlayCreds.new(sa_json: raw, client_email: keychain_ids.first, source: :keychain)
        elsif keychain_ids.length > 1
          raise AmbiguousCredentialsError,
                "Multiple Google Play credentials in Keychain (#{keychain_ids.join(', ')}). " \
                'Pass --play-credentials PATH to disambiguate, or remove the unused ones with ' \
                '`mysigner local-credential delete google_play <client_email>`.'
        end

        # Tier 4: project-sniff (walk up to PROJECT_SNIFF_MAX_DEPTH dirs).
        if (sniffed = sniff_project_for_play(cwd, tried))
          raw, email = read_sa_json!(sniffed, label: 'project-sniff')
          return PlayCreds.new(sa_json: raw, client_email: email, source: :disk)
        end

        # Tier 5: prompt or fail.
        raise CredentialNotFoundError, play_not_found_message(tried: tried) unless stdin.respond_to?(:tty?) && stdin.tty?

        path = prompt(stderr, stdin, 'Path to your Google Play service-account JSON:')
        raw, email = read_sa_json!(File.expand_path(path), label: 'prompt')
        PlayCreds.new(sa_json: raw, client_email: email, source: :prompt)
      end

      # mysigner-22 Phase 7 — Android keystore cascade.
      #
      # Each tier may contribute any subset of the four required pieces
      # (path, keystore_password, key_alias, key_password); the resolver
      # stitches them together highest-priority-first and prompts (TTY) or
      # fails (non-TTY) for whatever is still missing.
      #
      # Priority: flag > env > keychain > project-sniff > prompt.
      #
      # @return [AndroidKeystoreCreds]
      # @raise  [CredentialNotFoundError]
      # @raise  [AmbiguousCredentialsError]
      def resolve_android_keystore(options: {}, env: ENV, stdin: $stdin, stderr: $stderr, cwd: Dir.pwd)
        tried = []
        # Layered hash {path:, keystore_password:, key_alias:, key_password:, source:, tmpfile:}.
        # `path_source` mirrors the ASC cascade contract: source attribution
        # follows the tier that supplied the .jks (the primary material), not
        # the tier that filled in a stray password field.
        pieces = {}

        layer_android_flag_pieces!(pieces, options)
        layer_android_env_pieces!(pieces, env)
        layer_android_keychain_pieces!(pieces, hint: pieces[:key_alias], tried: tried)
        layer_android_sniff_pieces!(pieces, cwd: cwd, tried: tried)

        # All tiers exhausted — prompt for what's still missing (TTY only).
        missing = android_missing_pieces(pieces)
        if missing.any?
          unless stdin.respond_to?(:tty?) && stdin.tty?
            raise CredentialNotFoundError, android_keystore_not_found_message(tried: tried, missing: missing)
          end

          fill_android_pieces_from_prompt!(pieces, missing, stdin: stdin, stderr: stderr)
        end

        AndroidKeystoreCreds.new(
          keystore_path: pieces[:path],
          keystore_password: pieces[:keystore_password],
          key_alias: pieces[:key_alias],
          key_password: pieces[:key_password] || pieces[:keystore_password],
          source: pieces[:source] || :prompt,
          tmpfile: pieces[:tmpfile]
        )
      end

      # ---- shared helpers ------------------------------------------------

      private

      def string_option(options, key)
        return nil if options.nil?

        # Thor symbolizes; tolerate string keys for direct callers.
        val = options[key] || options[key.to_s]
        return nil if val.nil?

        s = val.to_s.strip
        s.empty? ? nil : s
      end

      def string_env(env, key)
        val = env[key]
        return nil if val.nil?

        s = val.to_s.strip
        s.empty? ? nil : s
      end

      def safe_list_keychain(kind)
        # Lazy-require so production scripts that never trigger local-only
        # don't pay the LocalCredentials load cost.
        require 'mysigner/local_credentials'
        Mysigner::LocalCredentials.list(kind: kind)
      rescue StandardError
        # A misconfigured Keychain shouldn't crash the cascade — treat as
        # "no entries here, try the next tier."
        []
      end

      # WHY this isn't `ids.first`: when the user has multiple ASC keys in
      # Keychain (very common once they switch teams) we used to silently pick
      # one. Now: if a hint (flag --asc-key-id or APP_STORE_CONNECT_API_KEY_ID)
      # narrows the choice, we use it; if the hint doesn't match any keychain
      # entry, we treat keychain as "not useful here" and let lower tiers
      # provide the path; if no hint and one entry, that one wins; otherwise
      # we raise AmbiguousCredentialsError.
      def pick_keychain_id(ids, hint:, label:)
        return nil if ids.empty?

        if hint
          return hint if ids.include?(hint)

          # Hint set but no keychain match — caller will use disk/env path
          # for this key_id. Don't raise here.
          return nil
        end

        return ids.first if ids.length == 1

        raise AmbiguousCredentialsError,
              "Multiple #{label} credentials in Keychain (#{ids.join(', ')}). " \
              'Pass --asc-key-id KEY_ID (or set APP_STORE_CONNECT_API_KEY_ID) to disambiguate.'
      end

      # Android-specific keychain picker — same shape as pick_keychain_id but
      # the disambiguation knob is `--key-alias` (the alias *is* the keychain
      # account id for android_keystore), so the error wording differs.
      def pick_android_keychain_id(ids, hint:)
        return nil if ids.empty?

        if hint
          return hint if ids.include?(hint)

          return nil
        end

        return ids.first if ids.length == 1

        raise AmbiguousCredentialsError,
              "Multiple Android keystore credentials in Keychain (#{ids.join(', ')}). " \
              'Pass --key-alias ALIAS (or set MYSIGNER_KEY_ALIAS) to disambiguate.'
      end

      def fetch_keychain_envelope(kind, id, label:)
        require 'mysigner/local_credentials'
        raw = Mysigner::LocalCredentials.fetch(kind: kind, id: id)
        if raw.nil?
          raise CredentialNotFoundError,
                "Keychain index lists `#{id}` but the secret is missing. " \
                'Re-store with `mysigner onboard --local-only`.'
        end

        parsed = begin
          JSON.parse(raw)
        rescue JSON::ParserError => e
          raise CredentialNotFoundError,
                "#{label} Keychain entry `#{id}` is not valid JSON (#{e.message}). " \
                'Re-store with `mysigner onboard --local-only`.'
        end

        unless parsed.is_a?(Hash) && parsed['issuer_id'] && parsed['p8_pem']
          raise CredentialNotFoundError,
                "#{label} Keychain entry `#{id}` is missing required fields (need issuer_id + p8_pem). " \
                'Re-store with `mysigner onboard --local-only`.'
        end

        parsed
      end

      def fetch_keychain_raw(kind, id, label:)
        require 'mysigner/local_credentials'
        raw = Mysigner::LocalCredentials.fetch(kind: kind, id: id)
        return raw if raw && !raw.empty?

        raise CredentialNotFoundError,
              "#{label} Keychain index lists `#{id}` but the secret is missing. " \
              'Re-store with `mysigner onboard --local-only`.'
      end

      def scan_apple_private_keys_dir(tried)
        dir = APPLE_PRIVATE_KEYS_DIR
        unless File.directory?(dir)
          tried << "disk: #{dir} (not present)"
          return [nil, nil]
        end

        files = Dir.glob(File.join(dir, 'AuthKey_*.p8'))
        files_word = files.length == 1 ? 'file' : 'files'
        tried << "disk: #{dir} (#{files.length} AuthKey_*.p8 #{files_word})"

        if files.length == 1
          path = files.first
          [path, derive_key_id_from_filename(path)]
        elsif files.length > 1
          # Multiple files on disk is ambiguous in the SAME way as multi-
          # Keychain. Surface it; let the flag/env-var pick.
          raise AmbiguousCredentialsError,
                "Multiple ASC private keys found in #{dir}: " \
                "#{files.map { |f| File.basename(f) }.join(', ')}. " \
                'Pass --asc-key-path PATH (or set APP_STORE_CONNECT_API_KEY_PATH) to pick one.'
        else
          [nil, nil]
        end
      end

      def derive_key_id_from_filename(path)
        return nil if path.nil?

        File.basename(path) =~ /\AAuthKey_([A-Z0-9]+)\.p8\z/i ? Regexp.last_match(1) : nil
      end

      # Build the "what we have, what we need" triple by overlaying tiers from
      # high → low priority. Returns [path, key_id, issuer_id, winning_source].
      # WHY return :source from here: the cascade can win at the highest tier
      # that contributed the path (which is what we tell the user about).
      # `parts` is a single Hash to keep the parameter list under the cop
      # limit; every key is required so a missing one is a programmer error.
      def assemble_asc_pieces(parts)
        # If keychain has a complete triple, prefer it over disk because the
        # user explicitly onboarded it (intent signal). The keychain branch
        # short-circuits in the caller, so we just signal it here.
        return [nil, parts[:keychain_id], nil, :keychain] if parts[:keychain_id]

        path   = parts[:flag_path] || parts[:env_path] || parts[:disk_path]
        key_id = parts[:flag_key_id] || parts[:env_key_id] || derive_key_id_from_filename(path) || parts[:disk_key_id]
        issuer = parts[:flag_issuer] || parts[:env_issuer]
        source = source_for(path, flag_path: parts[:flag_path], env_path: parts[:env_path], disk_path: parts[:disk_path])
        [path, key_id, issuer, source]
      end

      def source_for(path, flag_path:, env_path:, disk_path:)
        return :flag if path && path == flag_path
        return :env  if path && path == env_path
        return :disk if path && path == disk_path

        nil
      end

      def source_label(source)
        case source
        when :flag then '--asc-key-path'
        when :env  then 'APP_STORE_CONNECT_API_KEY_PATH'
        when :disk then APPLE_PRIVATE_KEYS_DIR
        else 'prompt'
        end
      end

      def read_pem!(path, label:)
        expanded = File.expand_path(path)
        unless File.exist?(expanded)
          raise CredentialNotFoundError,
                "ASC private key file not found at #{expanded} (from #{label}). " \
                'Check the path and try again.'
        end

        File.read(expanded)
      end

      def read_sa_json!(path, label:)
        expanded = File.expand_path(path)
        unless File.exist?(expanded)
          raise CredentialNotFoundError,
                "Google Play service-account JSON not found at #{expanded} (from #{label}). " \
                'Check the path and try again.'
        end

        raw = File.read(expanded)
        parsed = begin
          JSON.parse(raw)
        rescue JSON::ParserError => e
          raise CredentialNotFoundError,
                "Google Play service-account JSON at #{expanded} is not valid JSON (#{e.message})."
        end

        unless parsed['type'] == 'service_account' && parsed['client_email'] && parsed['private_key']
          raise CredentialNotFoundError,
                "Google Play service-account JSON at #{expanded} is missing required fields " \
                "(need type='service_account', client_email, private_key)."
        end

        [raw, parsed['client_email']]
      end

      # Walks `cwd` up to PROJECT_SNIFF_MAX_DEPTH parents looking for any of:
      #   - eas.json with submit.<profile>.android.serviceAccountKeyPath
      #   - PLAY_PROJECT_FILE_NAMES at the root
      # First hit wins (closer-to-cwd dirs first). Records what was tried so
      # the not-found error names the dirs.
      def sniff_project_for_play(cwd, tried)
        return nil if cwd.nil?

        dir = File.expand_path(cwd)
        PROJECT_SNIFF_MAX_DEPTH.times do
          tried << "disk: project-sniff in #{dir}"

          eas_path = File.join(dir, 'eas.json')
          if File.exist?(eas_path)
            sa = extract_sa_path_from_eas(eas_path, dir)
            return sa if sa
          end

          PLAY_PROJECT_FILE_NAMES.each do |name|
            candidate = File.join(dir, name)
            return candidate if File.exist?(candidate)
          end

          parent = File.dirname(dir)
          break if parent == dir # filesystem root

          dir = parent
        end

        nil
      end

      # eas.json shape: submit.<profile>.android.serviceAccountKeyPath. Walk
      # the production / preview / default profiles in that order — production
      # is the canonical ship target, preview is the second most common in
      # Expo docs.
      def extract_sa_path_from_eas(eas_path, dir)
        json = JSON.parse(File.read(eas_path))
        submit = json['submit'] || {}
        %w[production preview default].each do |profile|
          path = submit.dig(profile, 'android', 'serviceAccountKeyPath')
          next if path.nil? || path.to_s.strip.empty?

          # EAS paths can be relative to the eas.json dir.
          resolved = File.expand_path(path, dir)
          return resolved if File.exist?(resolved)
        end
        nil
      rescue JSON::ParserError
        # Malformed eas.json is the user's problem in their own toolchain;
        # we just skip it and let the cascade fall through.
        nil
      end

      def prompt(stderr, stdin, label)
        stderr.print "#{label} " if stderr.respond_to?(:print)
        stdin.gets.to_s.strip.gsub(/\A['"]|['"]\z/, '')
      end

      def asc_not_found_message(tried:, missing:)
        missing_pieces = []
        missing_pieces << 'path to .p8' if missing[:path]
        missing_pieces << 'Key ID'      if missing[:key_id]
        missing_pieces << 'Issuer ID'   if missing[:issuer_id]

        <<~MSG.strip
          No usable App Store Connect credentials found (missing: #{missing_pieces.join(', ')}).

          Tried in order:
          #{tried.map { |t| "  - #{t}" }.join("\n")}

          To fix, set ANY of these:
            * Per-command flags:   --asc-key-path PATH  --asc-key-id KEY_ID  --asc-issuer-id UUID
            * Environment:         APP_STORE_CONNECT_API_KEY_PATH, APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_KEY_ISSUER_ID
            * Onboard locally:     mysigner onboard --local-only
            * Standard location:   place AuthKey_<KEY_ID>.p8 in #{APPLE_PRIVATE_KEYS_DIR}/
        MSG
      end

      # ---- Android keystore cascade helpers ------------------------------

      # Higher tiers never overwrite lower tiers when they're nil, and lower
      # tiers never overwrite higher tiers when both have a value. That's the
      # invariant `layer_android_*_pieces!` keeps: a key in `pieces` is set
      # exactly once, by the highest tier that supplied it.
      def layer_android_piece!(pieces, key, value, source:)
        return if value.nil? || value.to_s.empty?
        return unless pieces[key].nil?

        pieces[key] = value
        # Only the path drives the `:source` audit label — passwords and
        # alias are metadata. Mirrors the ASC contract (path = primary
        # material, issuer_id = metadata).
        pieces[:source] ||= source if key == :path
      end

      def layer_android_flag_pieces!(pieces, options)
        layer_android_piece!(pieces, :path, expand_or_nil(string_option(options, :keystore_path)), source: :flag)
        layer_android_piece!(pieces, :keystore_password, string_option(options, :keystore_password), source: :flag)
        layer_android_piece!(pieces, :key_alias, string_option(options, :key_alias), source: :flag)
        layer_android_piece!(pieces, :key_password, string_option(options, :key_password), source: :flag)
      end

      def layer_android_env_pieces!(pieces, env)
        layer_android_piece!(pieces, :path,
                             expand_or_nil(string_env(env, 'MYSIGNER_KEYSTORE_PATH') || string_env(env, 'ANDROID_KEYSTORE_PATH')),
                             source: :env)
        layer_android_piece!(pieces, :keystore_password,
                             string_env(env, 'MYSIGNER_KEYSTORE_PASSWORD') || string_env(env, 'ANDROID_KEYSTORE_PASSWORD'),
                             source: :env)
        layer_android_piece!(pieces, :key_alias,
                             string_env(env, 'MYSIGNER_KEY_ALIAS') || string_env(env, 'ANDROID_KEY_ALIAS'),
                             source: :env)
        layer_android_piece!(pieces, :key_password,
                             string_env(env, 'MYSIGNER_KEY_PASSWORD') || string_env(env, 'ANDROID_KEY_PASSWORD'),
                             source: :env)
      end

      def layer_android_keychain_pieces!(pieces, hint:, tried:)
        ids = safe_list_keychain(:android_keystore)
        tried << "keychain: #{ids.length} entr#{ids.length == 1 ? 'y' : 'ies'}"

        chosen_id = pick_android_keychain_id(ids, hint: hint)
        return if chosen_id.nil?

        envelope = fetch_keystore_envelope!(chosen_id)

        # Materialize the base64-encoded .jks to a tmp file. Gradle and apksigner
        # both expect a path, so we write once per process and keep the Tempfile
        # alive on the Struct so GC doesn't unlink it mid-build.
        tmp = materialize_keystore_tmpfile!(envelope.fetch('keystore_b64'), chosen_id)

        layer_android_piece!(pieces, :path, tmp.path, source: :keychain)
        layer_android_piece!(pieces, :keystore_password, envelope['keystore_password'], source: :keychain)
        layer_android_piece!(pieces, :key_alias, envelope['key_alias'] || chosen_id, source: :keychain)
        layer_android_piece!(pieces, :key_password, envelope['key_password'], source: :keychain)
        pieces[:tmpfile] = tmp
      end

      def layer_android_sniff_pieces!(pieces, cwd:, tried:)
        return if pieces[:path] # higher tier already supplied a path

        dir = File.expand_path(cwd)
        # Manual loop (not `.times`) so we can `break` out cleanly on the
        # first match without a non-local return-from-iterator (Lint cop).
        # Per-dir order: highest-priority project-local explicit (key.properties,
        # the Flutter / Gradle-only standard) → eas.json (Expo) → inline
        # `signingConfigs.release` in `android/app/build.gradle[.kts]` (the
        # most common pure-Android-Studio convention; later in order because
        # `key.properties` is more explicit and many Studio projects load it
        # via `keystoreProperties[...]` inside the gradle file anyway, in
        # which case the .properties file is the source of truth).
        depth = 0
        while depth < PROJECT_SNIFF_MAX_DEPTH
          tried << "disk: project-sniff in #{dir}"

          break if try_layer_android_key_properties!(pieces, dir)
          break if try_layer_android_eas_json!(pieces, dir)
          break if try_layer_android_build_gradle!(pieces, dir)

          parent = File.dirname(dir)
          break if parent == dir

          dir = parent
          depth += 1
        end

        # Global per-user fallback: only consulted if project-local sources
        # didn't fill every piece. Scoped by `pieces[:path].nil?` so a project
        # that fully self-describes its keystore via key.properties / eas.json /
        # build.gradle never silently picks up a stale entry from a developer's
        # ~/.gradle/gradle.properties.
        try_layer_gradle_properties!(pieces, tried) if pieces[:path].nil?
      end

      def try_layer_android_key_properties!(pieces, dir)
        ANDROID_KEY_PROPERTIES_FILES.each do |rel|
          kp_path = File.join(dir, rel)
          next unless File.exist?(kp_path)

          kp = parse_key_properties(kp_path)
          next unless kp[:storeFile]

          resolved = File.expand_path(kp[:storeFile], File.dirname(kp_path))
          next unless File.exist?(resolved)

          layer_android_piece!(pieces, :path, resolved, source: :disk)
          layer_android_piece!(pieces, :keystore_password, kp[:storePassword], source: :disk)
          layer_android_piece!(pieces, :key_alias, kp[:keyAlias], source: :disk)
          layer_android_piece!(pieces, :key_password, kp[:keyPassword], source: :disk)
          return true
        end
        false
      end

      def try_layer_android_eas_json!(pieces, dir)
        eas_path = File.join(dir, 'eas.json')
        return false unless File.exist?(eas_path)

        extract_keystore_from_eas!(pieces, eas_path, dir)
      end

      # mysigner-22 Phase 7 follow-up — pure-Android-Studio convention.
      # Inline `signingConfigs { release { ... } }` in `android/app/build.gradle`
      # (Groovy DSL) or `android/app/build.gradle.kts` (Kotlin DSL).
      #
      # We deliberately do NOT write a Groovy/Kotlin parser; we extract literal
      # string values for the four `release {}` fields and skip anything that
      # is a `System.getenv(...)`, `project.properties[...]`, or
      # `keystoreProperties[...]` reference — those are handled by the env tier
      # and the key.properties sniff respectively.
      #
      # WHY source :disk (not a new :gradle): the user-facing audit attribution
      # is "we found credentials on disk in your project tree", same conceptual
      # tier as key.properties and eas.json. Adding a new source label would
      # bloat the audit log for no operational benefit — the file extension
      # already disambiguates in tried_log.
      def try_layer_android_build_gradle!(pieces, dir)
        %w[android/app/build.gradle android/app/build.gradle.kts].each do |rel|
          gradle_path = File.join(dir, rel)
          next unless File.exist?(gradle_path)

          release_body = extract_gradle_release_block(gradle_path)
          next if release_body.nil? || release_body.empty?

          extracted = extract_gradle_release_fields(release_body)
          # Resolve storeFile relative to the gradle file's own dir (matches
          # Gradle's `file(...)` resolution semantics).
          if extracted[:storeFile]
            resolved = File.expand_path(extracted[:storeFile], File.dirname(gradle_path))
            layer_android_piece!(pieces, :path, resolved, source: :disk) if File.exist?(resolved)
          end
          layer_android_piece!(pieces, :keystore_password, extracted[:storePassword], source: :disk)
          layer_android_piece!(pieces, :key_alias, extracted[:keyAlias], source: :disk)
          layer_android_piece!(pieces, :key_password, extracted[:keyPassword], source: :disk)

          return true if pieces[:path]
        end
        false
      end

      # Match `signingConfigs { ... release { <body> } ... }` and return the
      # inner release-block body. Tolerant of whitespace; uses a brace-depth
      # walk (NOT a regex with nested capture, which can't match balanced
      # braces) so deeply nested debug { ... } release { ... } structures
      # don't trip up the extraction.
      def extract_gradle_release_block(path)
        src = File.read(path)
        return nil unless src

        signing_body = extract_balanced_brace_body(src, /signingConfigs\s*\{/)
        return nil if signing_body.nil?

        # Match three release-block forms:
        #   Groovy DSL:    release {
        #   Kotlin DSL:    create("release") { ... } OR getByName("release") { ... }
        # Both Kotlin variants are how Android Studio's New Project wizard
        # actually writes signingConfigs in build.gradle.kts — bare `release {`
        # is illegal Kotlin (no such top-level identifier). Without the
        # `create|getByName` alternation, every modern AS Kotlin project
        # silently fell through to the prompt tier.
        extract_balanced_brace_body(
          signing_body,
          /(?:release|(?:create|getByName)\s*\(\s*["']release["']\s*\))\s*\{/
        )
      rescue StandardError
        nil
      end

      # Find the first match of `opener_regex` ending at `{`, then walk forward
      # counting braces until the matching `}`. Returns the body BETWEEN the
      # braces (exclusive). Returns nil if no match or unbalanced braces.
      def extract_balanced_brace_body(src, opener_regex)
        m = src.match(opener_regex)
        return nil unless m

        start_idx = m.end(0) # position right after the `{`
        depth = 1
        idx = start_idx
        while idx < src.length
          ch = src[idx]
          depth += 1 if ch == '{'
          depth -= 1 if ch == '}'
          return src[start_idx...idx] if depth.zero?

          idx += 1
        end
        nil
      end

      # Pull the four literal field values from a release-block body. The
      # patterns intentionally only match double / single quoted string
      # literals — `System.getenv(...)`, `project.properties[...]`,
      # `keystoreProperties[...]` references all fall through (no match) and
      # are left for the env tier / key.properties sniff to fill.
      #
      # Optional `=` between identifier and value handles the Kotlin DSL form
      # (`storePassword = "pw"`) without a second pattern set.
      def extract_gradle_release_fields(body)
        out = {}
        # storeFile: must be `storeFile [= ]file("<literal>")`. We require the
        # `file(` wrapper because that's what every Android signing config uses
        # for path values; bare strings here would be wrong syntax.
        if (m = body.match(/storeFile\s*=?\s*file\(\s*["']([^"']+)["']\s*\)/))
          out[:storeFile] = m[1]
        end
        if (m = body.match(/storePassword\s*=?\s*["']([^"']+)["']/))
          out[:storePassword] = m[1]
        end
        if (m = body.match(/keyAlias\s*=?\s*["']([^"']+)["']/))
          out[:keyAlias] = m[1]
        end
        if (m = body.match(/keyPassword\s*=?\s*["']([^"']+)["']/))
          out[:keyPassword] = m[1]
        end
        out
      end

      # mysigner-22 Phase 7 follow-up — Android Studio per-user convention.
      # The "secure shared keystore" pattern from
      # https://developer.android.com/studio/publish/app-signing#secure-shared-keystore
      # stores signing config in `~/.gradle/gradle.properties` with a project-
      # chosen prefix:
      #
      #   MYAPP_RELEASE_STORE_FILE=/path/to/release.jks
      #   MYAPP_RELEASE_STORE_PASSWORD=...
      #   MYAPP_RELEASE_KEY_ALIAS=upload
      #   MYAPP_RELEASE_KEY_PASSWORD=...
      #
      # The docs use `MYAPP_RELEASE_` as the example prefix but each project
      # picks its own. We scan all keys, group by prefix, and:
      #   - if exactly one prefix has all four fields → layer it in
      #   - if multiple prefixes are full → raise AmbiguousCredentialsError
      #   - if only partial sets exist → skip silently and let other tiers fill
      def try_layer_gradle_properties!(pieces, tried)
        gradle_props_path = File.expand_path('~/.gradle/gradle.properties')
        return unless File.exist?(gradle_props_path)

        tried << "disk: #{gradle_props_path}"

        parsed = parse_key_properties(gradle_props_path)
        return if parsed.empty?

        full_prefixes = group_gradle_keystore_prefixes(parsed)

        if full_prefixes.length > 1
          raise AmbiguousCredentialsError,
                "Multiple Android keystore prefixes in #{gradle_props_path} " \
                "(#{full_prefixes.keys.sort.join(', ')}). " \
                'Pass --key-alias ALIAS (or set MYSIGNER_KEY_ALIAS) to disambiguate, ' \
                'or remove the unused prefix entries.'
        end

        return if full_prefixes.empty?

        _prefix, fields = full_prefixes.first
        resolved_path = File.expand_path(fields[:store_file])
        return unless File.exist?(resolved_path)

        layer_android_piece!(pieces, :path, resolved_path, source: :disk)
        layer_android_piece!(pieces, :keystore_password, fields[:store_password], source: :disk)
        layer_android_piece!(pieces, :key_alias, fields[:key_alias], source: :disk)
        layer_android_piece!(pieces, :key_password, fields[:key_password], source: :disk)
      end

      # Walk every parsed key, bin by prefix-before-_STORE_FILE (and the three
      # siblings). Returns only prefixes that have ALL four fields present
      # AND non-empty — partials get filtered out so they don't trigger the
      # ambiguity check (a partial set is "noise", not a competing candidate).
      def group_gradle_keystore_prefixes(parsed)
        buckets = Hash.new { |h, k| h[k] = {} }
        parsed.each do |key, value|
          next if value.nil? || value.to_s.empty?

          key_str = key.to_s
          case key_str
          when /\A(.+)_STORE_FILE\z/     then buckets[Regexp.last_match(1)][:store_file] = value
          when /\A(.+)_STORE_PASSWORD\z/ then buckets[Regexp.last_match(1)][:store_password] = value
          when /\A(.+)_KEY_ALIAS\z/      then buckets[Regexp.last_match(1)][:key_alias] = value
          when /\A(.+)_KEY_PASSWORD\z/   then buckets[Regexp.last_match(1)][:key_password] = value
          end
        end

        required = %i[store_file store_password key_alias key_password]
        buckets.select { |_, fields| required.all? { |f| fields[f] } }
      end

      # `key.properties` is INI-ish: key=value lines, `#` comments, blank
      # lines OK. The Flutter docs explicitly use four keys: storeFile,
      # storePassword, keyAlias, keyPassword. We deliberately don't pull in
      # an ini-parser gem — the format is two lines of regex.
      #
      # Strips a single leading + single trailing matching quote pair after
      # `.strip` — `storePassword="my pw"` is valid `.properties` syntax used
      # in many Android docs examples; without this, the literal 8-char string
      # `"my pw"` (quotes included) flows through to apksigner and is rejected.
      # Mirrors the `prompt` helper's de-quoting for parity.
      def parse_key_properties(path)
        out = {}
        File.foreach(path) do |line|
          line = line.strip
          next if line.empty? || line.start_with?('#', ';')

          key, _, value = line.partition('=')
          next if value.empty?

          value = value.strip.gsub(/\A['"]|['"]\z/, '')
          out[key.strip.to_sym] = value
        end
        out
      rescue StandardError
        {}
      end

      # eas.json — Expo's android keystore lives at:
      #   credentials.android.keystore.{keystorePath, keystorePassword, keyAlias, keyPassword}
      # Same profile-walk as the Play SA-JSON variant: production → preview → default.
      def extract_keystore_from_eas!(pieces, eas_path, dir)
        json = JSON.parse(File.read(eas_path))
        ks = json.dig('credentials', 'android', 'keystore')
        return false unless ks.is_a?(Hash)

        rel_path = ks['keystorePath']
        return false if rel_path.nil? || rel_path.to_s.strip.empty?

        resolved = File.expand_path(rel_path, dir)
        return false unless File.exist?(resolved)

        layer_android_piece!(pieces, :path, resolved, source: :disk)
        layer_android_piece!(pieces, :keystore_password, ks['keystorePassword'], source: :disk)
        layer_android_piece!(pieces, :key_alias, ks['keyAlias'], source: :disk)
        layer_android_piece!(pieces, :key_password, ks['keyPassword'], source: :disk)
        true
      rescue JSON::ParserError
        false
      end

      def fetch_keystore_envelope!(id)
        require 'mysigner/local_credentials'
        raw = Mysigner::LocalCredentials.fetch(kind: :android_keystore, id: id)
        if raw.nil?
          raise CredentialNotFoundError,
                "Keychain index lists Android keystore `#{id}` but the secret is missing. " \
                'Re-store with `mysigner onboard --local-only`.'
        end

        parsed = begin
          JSON.parse(raw)
        rescue JSON::ParserError => e
          raise CredentialNotFoundError,
                "Android keystore Keychain entry `#{id}` is not valid JSON (#{e.message}). " \
                'Re-store with `mysigner onboard --local-only`.'
        end

        unless parsed.is_a?(Hash) && parsed['keystore_b64']
          raise CredentialNotFoundError,
                "Android keystore Keychain entry `#{id}` is missing required `keystore_b64`. " \
                'Re-store with `mysigner onboard --local-only`.'
        end

        parsed
      end

      # WHY Tempfile (not Tempfile.create) + held on the Struct: the build
      # pipeline runs in the same Ruby process, so the Tempfile finalizer
      # cleans up at process exit. If we used Tempfile.create with a block,
      # the file would unlink immediately. If we just dropped the reference,
      # GC could unlink mid-build. Holding it on the Struct ties lifetime
      # to the caller's grip on AndroidKeystoreCreds.
      def materialize_keystore_tmpfile!(b64, id)
        bytes = Base64.strict_decode64(b64)
        safe_id = id.to_s.gsub(/[^a-zA-Z0-9._-]/, '_')
        tmp = Tempfile.new(["mysigner-keystore-#{safe_id}-", '.jks'])
        tmp.binmode
        tmp.write(bytes)
        tmp.flush
        File.chmod(0o600, tmp.path)
        tmp
      rescue ArgumentError => e
        raise CredentialNotFoundError,
              "Android keystore Keychain entry `#{id}` has invalid base64 (#{e.message}). " \
              'Re-store with `mysigner onboard --local-only`.'
      end

      def android_missing_pieces(pieces)
        out = []
        out << :path if pieces[:path].nil?
        out << :keystore_password if pieces[:keystore_password].nil?
        out << :key_alias if pieces[:key_alias].nil?
        # key_password is optional — defaults to keystore_password when nil
        # (long-standing Gradle convention). Don't force a separate prompt.
        out
      end

      def fill_android_pieces_from_prompt!(pieces, missing, stdin:, stderr:)
        if missing.include?(:path)
          path = prompt(stderr, stdin, 'Path to your Android keystore (.jks / .keystore):')
          pieces[:path] = File.expand_path(path)
          pieces[:source] ||= :prompt
          unless File.exist?(pieces[:path])
            raise CredentialNotFoundError,
                  "Android keystore not found at #{pieces[:path]} (from prompt). " \
                  'Check the path and try again.'
          end
        end
        if missing.include?(:keystore_password)
          pieces[:keystore_password] = prompt_password(stderr, stdin, 'Keystore password:')
          # Ask for an optional distinct key_password. Without this, users
          # whose key has a different password than the keystore get a silent
          # fuse to keystore_password (via the final `||` defaulting in
          # `resolve_android_keystore`) and a downstream apksigner failure
          # ("incorrect key password") with no hint. Empty input → keep nil
          # so the existing default kicks in.
          if pieces[:key_password].nil?
            key_pw = prompt_password(stderr, stdin, 'Key password (press Enter to reuse keystore password):')
            pieces[:key_password] = key_pw unless key_pw.nil? || key_pw.empty?
          end
        end
        return unless missing.include?(:key_alias)

        pieces[:key_alias] = prompt(stderr, stdin, 'Key alias:')
      end

      # Password prompt — disables terminal echo so the password doesn't show
      # in the user's scrollback. Falls back to a plain prompt when echo
      # control isn't available (non-TTY tests, weird terminals). The prompt
      # is gated by the same TTY check the caller already does, so the
      # fallback path is mostly for instance_double stdin in specs.
      def prompt_password(stderr, stdin, label)
        # `noecho` lives in io/console — load lazily so test doubles that
        # don't implement it aren't required to.
        begin
          require 'io/console'
        rescue LoadError
          # If io/console is unavailable, fall back silently.
        end

        return prompt(stderr, stdin, label) unless stdin.respond_to?(:noecho)

        stderr.print "#{label} " if stderr.respond_to?(:print)
        value = stdin.noecho(&:gets).to_s.strip
        stderr.puts if stderr.respond_to?(:puts)
        value
      rescue IOError
        prompt(stderr, stdin, label)
      end

      def expand_or_nil(path)
        return nil if path.nil?

        File.expand_path(path)
      end

      def android_keystore_not_found_message(tried:, missing:)
        missing_labels = missing.map { |m| ANDROID_MISSING_LABELS[m] }

        <<~MSG.strip
          No usable Android keystore found (missing: #{missing_labels.join(', ')}).

          Tried in order:
          #{tried.map { |t| "  - #{t}" }.join("\n")}

          To fix, set ANY of these:
            * Per-command flags:   --keystore-path PATH  --keystore-password PWD
                                   --key-alias ALIAS    --key-password PWD
            * Environment:         MYSIGNER_KEYSTORE_PATH (or ANDROID_KEYSTORE_PATH)
                                   MYSIGNER_KEYSTORE_PASSWORD (or ANDROID_KEYSTORE_PASSWORD)
                                   MYSIGNER_KEY_ALIAS (or ANDROID_KEY_ALIAS)
                                   MYSIGNER_KEY_PASSWORD (or ANDROID_KEY_PASSWORD)
            * Onboard locally:     mysigner onboard --local-only
            * Project file:        android/key.properties (Flutter convention),
                                   android/keystore.properties, or key.properties at project root,
                                   with storeFile=, storePassword=, keyAlias=, keyPassword=,
                                   or credentials.android.keystore.* in eas.json,
                                   or inline signingConfigs.release in android/app/build.gradle[.kts]
            * Global gradle:       ~/.gradle/gradle.properties with PREFIX_STORE_FILE,
                                   PREFIX_STORE_PASSWORD, PREFIX_KEY_ALIAS, PREFIX_KEY_PASSWORD
        MSG
      end

      def play_not_found_message(tried:)
        <<~MSG.strip
          No usable Google Play credentials found.

          Tried in order:
          #{tried.map { |t| "  - #{t}" }.join("\n")}

          To fix, set ANY of these:
            * Per-command flag:    --play-credentials PATH
            * Environment:         GOOGLE_APPLICATION_CREDENTIALS
            * Onboard locally:     mysigner onboard --local-only
            * Project file:        place service-account.json (or play-credentials.json) at your project root,
                                   or add submit.<profile>.android.serviceAccountKeyPath to eas.json
        MSG
      end
    end
  end
end
