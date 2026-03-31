# Changelog

All notable changes to My Signer CLI will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
