# Changelog

All notable changes to My Signer CLI will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.3] - 2026-06-25

### Fixed
- `logout` no longer dead-ends when the stored token is unreadable. Previously a corrupt/undecryptable token made the default `logout` (which revokes the server token) fail with misleading "once the server is reachable" advice and refuse to clear the local config — trapping the user, since re-login requires logging out first. Now an unreadable-token purge failure logs you out locally with a clear note to revoke the old token in the dashboard; transient server/network failures still keep the local config and suggest a retry.

## [0.3.2] - 2026-06-25

### Fixed
- Robustness: an undecryptable stored token no longer crashes nearly every command with a raw backtrace — it degrades to a clear "re-login" message. `config show` now works.
- `doctor --platform android` no longer reports "All checks passed" when the JDK/Android SDK are missing (they're now reported as issues).
- `doctor` and `validate` no longer run a tree-mutating `npx expo prebuild` from a read-only diagnostic; `validate` no longer crashes on a project with no native iOS project.
- Android versionCode auto-increment now actually takes effect — it's injected via the Gradle init script (a bare `-PversionCode` is ignored by stock `build.gradle`), gated to the application module so library submodules don't break.
- Expo version bumps back up `android/` and restore it on failure (no data loss).
- `onboard --local-only` no longer crashes with `uninitialized constant StringIO`.
- iOS-only commands (`ship testflight/appstore`, `build`, `export`, `upload`) now fail with a clear "requires macOS" message on Linux/Windows instead of a raw backtrace; `doctor` skips iOS checks on non-macOS instead of showing red Xcode issues.
- Dropped the `-q` flag that hid Gradle output; AAB selected by newest mtime; camelCase build variants fixed; Linux/WSL JDK + Android SDK auto-detection.
- Security: faraday 2.14.2 → 2.14.3 (CVE-2026-54297).

### Changed
- Local-only mode (no My Signer account) is now surfaced at the front door: post-install message, `onboard` (interactive mode choice), `login`, and the README Quick Start.
- `ship` help explains Android tracks in plain words (incl. "production = PUBLIC — goes live to everyone") and what an AAB is; `--local-only` credential flags are documented.
- `onboard` now also sets up Google Play (vault) and an Android signing keystore (local-only).
- Connection-error guidance no longer leaks Rails/server internals to CLI users; Android build failures include a short triage block.

## [0.1.0] - 2026-01-23

### Added

#### Build & Ship Commands
- `mysigner ship testflight` - Build iOS app and upload to TestFlight in one command
- `mysigner ship appstore` - Build iOS app and submit to App Store Connect
- `mysigner ship internal/alpha/beta/production --platform android` - Build and upload Android app to Google Play
- `mysigner submit` - Submit existing builds for App Store/Play Store review
- `mysigner build` - Build .xcarchive for iOS (advanced)
- `mysigner export` - Export archive to IPA (advanced)
- `mysigner upload testflight` - Upload existing IPA to TestFlight (advanced)

#### Android Support
- Full Android build and upload workflow
- Keystore management: `mysigner keystore list/upload/download/activate/delete`
- Automatic version code increment when uploading to Google Play
- Support for all Google Play tracks: internal, alpha, beta, production
- Native Android, React Native, Flutter, and Capacitor/Ionic project detection

#### iOS Features
- App Store submission with release types (AFTER_APPROVAL, MANUAL, SCHEDULED)
- Scheduled release support with `--scheduled-date`
- Build processing wait with polling
- Automatic team ID detection from My Signer API
- Support for Native iOS, React Native, Flutter, and Capacitor/Ionic projects

#### Diagnostics & Onboarding
- `mysigner doctor` - Comprehensive health check with auto-fix capabilities
  - Checks Xcode, Command Line Tools, upload tools
  - Validates My Signer configuration and credentials
  - Checks signing identity in keychain
  - Verifies App Store Connect credentials (with interactive setup)
  - Checks disk space, network connectivity
  - Detects iOS and Android projects
  - Auto-creates provisioning profiles when missing
  - Generates CSR for certificate creation
- `mysigner doctor --platform ios` - Check iOS setup only
- `mysigner doctor --platform android` - Check Android setup only (Java, Android SDK, Gradle, keystores)
- `mysigner onboard` - Guided setup wizard for new users

#### Core Commands
- `mysigner login` - Authenticate with API token
- `mysigner logout` - Clear stored credentials
- `mysigner status` - Check connection and show organization stats
- `mysigner orgs` - List accessible organizations
- `mysigner switch` - Switch active organization
- `mysigner config show/set` - Manage configuration

#### Resource Management
- **Devices**: `mysigner devices`, `mysigner device detect/add/update`
- **Profiles**: `mysigner profiles`, `mysigner profile download/delete`
- **Certificates**: `mysigner certificates`, `mysigner certificate check/download`
- **Bundle IDs**: `mysigner bundleid list/register`

#### Sync
- `mysigner sync` - Sync from App Store Connect (iOS)
- `mysigner sync android` - Sync from Google Play
- `mysigner sync all` - Sync both platforms
- `--force` flag to force sync even if recently synced

#### Signing Configuration
- `mysigner signing configure` - Interactive wizard for manual signing setup
- Support for configuring specific targets or all targets
- Automatic profile matching and creation

### Technical

- Thor-based CLI architecture with modular command structure
- Faraday HTTP client with retry and error handling
- Configuration stored in `~/.mysigner/config.yml`
- 90+ RSpec tests
- Support for multiple project types:
  - Native iOS (.xcodeproj, .xcworkspace)
  - Native Android (Gradle)
  - React Native
  - Flutter
  - Capacitor/Ionic

---

## [Unreleased]

### Planned
- `--json` flag for scripting output
- Pretty tables (TTY::Table)
- Progress spinners (TTY::Spinner)
- CI/CD templates for GitHub Actions and GitLab CI
- Phased release support for App Store

---

## [0.3.1] - 2026-05-29

### Fixed
- `mysigner android add PACKAGE_NAME` crashed with `NoMethodError: undefined method 'post' for nil` in local-only mode. The `android` dispatcher now gates `init` / `add` / `list` (which manage MySigner-registered records) — only `android build` is purely local. `android list`'s banner now reads "android list" instead of "apps" (it had been showing the underlying apps-command name because list is implemented as an alias).
- `mysigner status` reported `Source: MYSIGNER_LOCAL_ONLY env var` when `MYSIGNER_LOCAL_ONLY=0` was set in the environment AND the config file had `local_only: true`. The env value "0" is falsy per the cascade's truthy parser, so the source was actually the file. Status now uses the new `Mysigner::Config.local_only_from_env?` predicate (mirroring `local_only_from_file?`) for accurate attribution.
- README's local-only audit table classified `android init/add/build/list` as ✅ LOCAL across the board. Corrected: only `android build` is local; the other three are MySigner-only.

### Added
- `Mysigner::Config.local_only_from_env?` — public, mirrors `local_only_from_file?`. Symmetric source predicates so `mysigner status` can attribute the active source using the same truthy parser the cascade uses.

---

## [0.3.0] - 2026-05-28

### Added
- Persistent local-only mode: `mysigner config set local-only true` writes to `~/.mysigner/config.yml`, no flag repetition required ([mysigner-22](https://mysigner.youtrack.cloud/issue/mysigner-22) follow-up).
- `mysigner config set <key> <value>` — extensible CLI knob for tweaking `~/.mysigner/config.yml`. Settable keys: `local-only`.
- `Helpers#exit_unless_local_supported!` — every MySigner-only command now exits cleanly with an explanation when local-only is active, instead of the generic "Not logged in" error.

### Changed
- `doctor` now announces local-only mode and skips MySigner-side checks instead of reporting "Not logged in" as an issue.
- `status` prints a local-mode credential-discovery summary when local-only is active.
- `validate` runs the local `Signing::Validator` (same one used by `ship`) and skips the server POST when local-only is active.
- `--local-only` Thor class_option no longer defaults to `false` — `--no-local-only` now correctly overrides the env var and the new persistent file setting.

### Fixed
- Precedence bug: with `MYSIGNER_LOCAL_ONLY=1` in the environment, `--no-local-only` did not actually disable local-only mode for that invocation.

---

## [0.2.0] - 2026-05-26

### Added — `--local-only` mode

Brand-new opt-in mode that lets you ship to TestFlight / Play Store
without sending any signing credentials to the MySigner server.
Activate via the `--local-only` flag on any command or by setting
`MYSIGNER_LOCAL_ONLY=1`. Proven end-to-end against a real iOS app
(real TestFlight upload).

- **Credential auto-discovery cascade** (`Mysigner::CredentialResolver`):
  walks per-command flags → env vars (`APP_STORE_CONNECT_API_KEY_*`,
  `GOOGLE_APPLICATION_CREDENTIALS`, `MYSIGNER_KEYSTORE_*` /
  `ANDROID_KEYSTORE_*`) → macOS Keychain (`Mysigner::LocalCredentials`)
  → standard tool locations (`~/.appstoreconnect/private_keys/AuthKey_*.p8`,
  `eas.json`, `android/key.properties`, `android/app/build.gradle[.kts]`
  inline `signingConfigs`, `~/.gradle/gradle.properties`) → interactive
  prompt (TTY-gated; non-TTY fails loud with the exact override knob to
  set).
- **iOS local-only ship** (`mysigner --local-only ship appstore`):
  bypasses MySigner auth bootstrap entirely (no login required). Mints
  ASC JWT locally and shells out to `xcrun altool --upload-app` (Apple's
  canonical CLI). Submit-for-review automated via the modern 3-step
  `/v1/reviewSubmissions` choreography.
- **Android local-only ship** (`mysigner --local-only ship play`): mints
  Google OAuth2 access token locally from the discovered SA-JSON.
  Pre-checks Play's highest existing `versionCode` and exits with a
  "bump versionCode to N+1" hint before wasting an upload Google would
  reject. Bypasses every MySigner server endpoint that previously ran
  on the Android path (keystore download, build records, etc.).
- **`mysigner onboard --local-only`**: walks the user through local
  credential setup interactively; skips the per-platform prompt when
  credentials are already discoverable via the cascade.

### Added — Security & hygiene

- **`mysigner logout --purge`**: optionally hard-deletes stored
  credentials on the MySigner server AND wipes local Keychain entries.
  Default behavior prompts (TTY-only; non-TTY defaults to No). New
  `--no-purge` flag opts out without prompting.
- Two new global flags: `--local-only` and `--auto-submit` /
  `--no-auto-submit`.
- New per-command flags on `ship`: `--asc-key-path`, `--asc-key-id`,
  `--asc-issuer-id`, `--apple-id`, `--play-credentials`,
  `--keystore-path`, `--keystore-password`, `--key-alias`,
  `--key-password`.

### Changed

- "Not logged in" error now also suggests `--local-only` as an
  alternative for users who don't want a MySigner account.
- `Signing::Validator`'s no-team error message no longer suggests "Add
  team to My Signer" when in `--local-only` mode.
- Multiple Apple `appStoreState` values handled with actionable typed
  errors during submit-for-review (`VersionInFlightError`,
  `VersionAlreadyReleasedError`, `SubmissionRejectedError`,
  `BuildProcessingTimeoutError`, `AppleApiError`).
- Submit-for-review poll loop is resilient to transient errors and
  respects HTTP 429 `Retry-After`.
- `Config#load` uses `YAML.safe_load_file` instead of `YAML.load_file`
  — rejects `!ruby/object:` directives loud.

### Removed (breaking)

- **`MYSIGNER_USE_LEGACY_ASC` env var + the legacy altool path it
  gated**. The modern envelope-encryption path (vault mode) and the new
  `--local-only` mode supersede it. Users relying on this env var will
  need to migrate.
- `Mysigner::Signing::KeystoreManager#list` / `#active_keystore` no
  longer accept the deprecated `include_secrets:` keyword (fetch
  passwords via `#fetch_secrets` instead — already the modern path).
- Test certs / mobileprovision files removed from the gem bundle.

### Fixed

- Thor parser bug where `--local-only` (or any class_option) placed
  before the subcommand was eaten by Thor's command-name lookup,
  silently routing to `help`. The `exe/mysigner` entry point now hoists
  leading class_options past the subcommand word.
- The previous iOS REST upload reinvented Apple's `/v1/buildUploads`
  payload shape and got it wrong (Apple rejected with
  `ENTITY_ERROR.ATTRIBUTE.UNKNOWN` on `fileName` / `fileSize`); the
  resulting 409 handler silently mapped every 409 to "build version
  conflict" and masked the real error. Replaced with `xcrun altool`
  shell-out (Apple's canonical CLI).
- README's "Secure" bullet no longer says "credentials stored locally"
  — was misleading in default vault mode. New copy names the AES-256
  at-rest server encryption and points at the `--local-only` opt-in
  that delivers the literal property.
