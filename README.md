# My Signer CLI

**One command from code to TestFlight or Google Play. No provisioning hell, no manual certificate wrangling.**

Command-line interface for [My Signer](https://github.com/jurgenleka/my-signer) - the modern mobile app signing and deployment automation tool for iOS and Android.

---

## What is My Signer CLI?

My Signer CLI is a command-line tool that connects to the My Signer API to manage iOS/Android signing assets and deploy apps directly from your terminal or CI/CD pipeline.

### The Problem We Solve

Mobile developers spend hours dealing with:
- ❌ Manual device registration through Apple Developer Portal
- ❌ Downloading and installing provisioning profiles
- ❌ Certificate and keystore management
- ❌ Complex Xcode/Gradle build configurations
- ❌ TestFlight and Google Play upload processes
- ❌ Version code conflicts on Play Store

### Our Solution

✅ **One Command Deploy** - `mysigner ship testflight` or `mysigner ship production --platform android`  
✅ **iOS + Android** - Full support for both platforms  
✅ **CI/CD Ready** - Automate builds in GitHub Actions, GitLab CI, etc.  
✅ **API-Powered** - Backed by My Signer API for team collaboration  
✅ **Smart Version Handling** - Auto-increment version codes for Android  
✅ **Secure** - Token-based authentication, credentials stored locally

---

## Installation

### Prerequisites

- Ruby 3.2+ (recommended: 3.4.5)
- [My Signer API](https://github.com/jurgenleka/my-signer) account and API token

### Install via RubyGems

```bash
gem install mysigner
```

### Install from source

```bash
git clone https://github.com/jurgenleka/my-signer-cli.git
cd my-signer-cli
bundle install
bundle exec rake install
```

---

## Quick Start

### 1. Get Your API Token

1. Log in to your My Signer dashboard
2. Navigate to your organization settings
3. Go to "API Tokens"
4. Create a new token with appropriate scopes
5. Copy the token (you'll only see it once!)

### 2. Login

```bash
mysigner login
# Enter your API URL (default: https://mysigner.dev or localhost if available)
# Enter your email address
# Paste your API token
# The CLI validates the token and auto-detects its organization
```

### 3. Ship Your App

```bash
# iOS: Build and upload to TestFlight
mysigner ship testflight

# iOS: Build and submit to App Store
mysigner ship appstore

# Android: Build and upload to internal testing
mysigner ship internal --platform android

# Android: Build and upload to production
mysigner ship production --platform android
```

### 4. Manage Signing Assets

```bash
# List devices
mysigner devices

# Add a new device
mysigner device add "John's iPhone" 00008030-001A1B2C3D4E567F

# List provisioning profiles
mysigner profiles

# Download a profile
mysigner profile download 42

# Check connection status
mysigner status
```

---

## Commands

### Build & Ship (Main Workflow)

```bash
# iOS
mysigner ship testflight                   # Build + upload to TestFlight
mysigner ship appstore                     # Build + submit to App Store
mysigner ship appstore --submit-for-review # Auto-submit for review

# Android
mysigner ship internal --platform android  # Build + upload to internal testing
mysigner ship alpha --platform android     # Build + upload to closed testing
mysigner ship beta --platform android      # Build + upload to open testing
mysigner ship production --platform android # Build + upload to production

# Advanced options
mysigner ship testflight --wait            # Wait for Apple to process build
mysigner ship appstore --release-type SCHEDULED --scheduled-date 2026-02-01T10:00:00Z
mysigner ship internal --platform android --release-notes "Bug fixes"
```

### Submit Existing Builds

```bash
# Submit already-uploaded iOS build
mysigner submit                            # Submit latest build
mysigner submit --bundle-id com.app.id     # Specify bundle ID
mysigner submit --build-number 42          # Submit specific build

# Promote Android build to different track
mysigner submit production --platform android
mysigner submit beta --platform android --version-code 123
```

### Build & Export (Advanced)

```bash
mysigner build                             # Build .xcarchive only
mysigner build --configuration Debug       # Specify configuration
mysigner build --target MyApp              # Specify target
mysigner export ARCHIVE_PATH               # Export archive to IPA
mysigner upload testflight IPA_PATH        # Upload existing IPA
```

### Diagnostics

```bash
mysigner doctor                            # Run health check (fixes common issues)
mysigner doctor --platform ios             # Check iOS setup only
mysigner doctor --platform android         # Check Android setup only
mysigner status                            # Check connection, credentials, and ASC setup
```

### Authentication

```bash
mysigner login              # Authenticate with API token
mysigner logout             # Clear stored credentials
mysigner onboard            # Guided setup wizard
```

### Organizations

```bash
mysigner orgs               # List accessible organizations
mysigner switch             # Switch active organization
```

### Devices

```bash
mysigner devices                           # List all devices
mysigner devices --platform ios            # Filter by platform
mysigner devices --search "iPhone"         # Search devices
mysigner device detect                     # Detect connected iOS devices
mysigner device add NAME UDID              # Register new device
mysigner device update ID "New Name"       # Update device name
```

### Provisioning Profiles

```bash
mysigner profiles                          # List all profiles
mysigner profiles --type development       # Filter by type
mysigner profile download ID               # Download .mobileprovision
mysigner profile delete ID                 # Delete profile
```

### Certificates

```bash
mysigner certificates                      # List all certificates
mysigner certificates --type development   # Filter by type
mysigner certificate check                 # Check local keychain certificates
mysigner certificate download ID           # Download .cer file
```

### Bundle IDs

```bash
mysigner bundleid list                     # List all bundle IDs
mysigner bundleid register com.example.app # Register a bundle ID
```

### Android Keystores

```bash
mysigner keystore list                     # List all keystores
mysigner keystore upload PATH              # Upload keystore file
mysigner keystore download ID              # Download keystore
mysigner keystore activate ID              # Set as active keystore
mysigner keystore delete ID                # Delete keystore
```

### Google Play Credentials

```bash
mysigner gp-credential list               # List all credentials
mysigner gp-credential activate ID        # Set as active credential
mysigner gp-credential test ID            # Test Google Play connection
mysigner gp-credential delete ID          # Delete credential
```

### App Store Releases

```bash
mysigner release list                      # List release configurations
mysigner release list --bundle-id com.app  # Filter by bundle ID
mysigner release show ID                   # Show release details
mysigner release create --bundle-id-id 42  # Create release config
mysigner release update ID --auto-submit   # Update release config
mysigner release update ID --whats-new "Bug fixes"
```

### Google Play Tracks

```bash
mysigner tracks com.example.app                # List tracks for an app
mysigner tracks com.example.app --sort         # Sort alphabetically
mysigner track com.example.app production      # Show track details
mysigner track com.example.app beta            # Show beta track details
```

### Android Apps

```bash
mysigner android init                          # Detect and register Android app
mysigner android add com.example.app           # Register app manually
mysigner android build                         # Build AAB file
mysigner android list                          # List registered Android apps
```

### Apps

```bash
mysigner apps                                  # List all apps (iOS + Android)
mysigner apps --platform ios                   # iOS apps only
mysigner apps --platform android               # Android apps only
mysigner apps -q "myapp"                       # Search by name
```

### Merchant IDs

```bash
mysigner merchant-ids                          # List Apple Pay Merchant IDs
mysigner merchant-id create IDENTIFIER         # Create a Merchant ID
mysigner merchant-id delete IDENTIFIER         # Delete a Merchant ID
```

### App Groups

```bash
mysigner app-groups                            # List App Groups
mysigner app-group register IDENTIFIER         # Register an App Group
mysigner app-group delete IDENTIFIER           # Delete an App Group
```

### Validate Signing

```bash
mysigner validate -b com.example.app -t development   # Validate signing config
mysigner validate --type appstore                      # Auto-detect bundle ID
```

### Sync

```bash
mysigner sync                # Sync from App Store Connect (iOS)
mysigner sync android        # Sync from Google Play
mysigner sync all            # Sync both platforms
mysigner sync --force        # Force sync even if recently synced
```

### Signing Configuration

```bash
mysigner signing configure                 # Interactive signing setup wizard
mysigner signing configure --target Widget # Configure specific target
mysigner signing configure --all-targets   # Configure all targets
```

---

## Configuration

My Signer CLI stores configuration in `~/.mysigner/config.yml`:

```yaml
api_url: http://localhost:3000
api_token: your_token_here
organization_id: 1
```

You can manually edit this file or use `mysigner config` commands:

```bash
mysigner config show        # Display current configuration
mysigner config set KEY VAL # Update configuration value
```

---

## Development Status

**Current Version**: 0.1.0

✅ **Complete**:
- ✅ Gem structure and dependencies (Thor, Faraday, Reline, Google APIs)
- ✅ Config management (`~/.mysigner/config.yml`)
- ✅ API client (Faraday with retry & error handling)
- ✅ Core commands (login, logout, config, status, orgs, switch, onboard)
- ✅ Resource commands (devices, profiles, certificates, bundleid)
- ✅ **iOS Build & Ship** (`mysigner ship testflight`, `mysigner ship appstore`)
- ✅ **Android Build & Ship** (`mysigner ship internal/alpha/beta/production`)
- ✅ Android keystore management (`mysigner keystore upload/download/activate`)
- ✅ Google Play credential management (`mysigner gp-credential list/activate/test/delete`)
- ✅ Automatic version code increment for Android
- ✅ App Store submission with release types (AFTER_APPROVAL, MANUAL, SCHEDULED)
- ✅ App Store release configuration (`mysigner release list/show/create/update`)
- ✅ Server-side signing validation (`mysigner validate`)
- ✅ Project detection (Native iOS/Android, React Native, Flutter, Capacitor/Ionic)
- ✅ `mysigner doctor` health check with auto-fix capabilities
- ✅ 260+ RSpec tests
- ✅ Interactive prompts and wizards

📅 **Future**:
- Pretty tables (TTY::Table)
- Progress spinners (TTY::Spinner)
- `--json` flag for scripting
- CI/CD templates (GitHub Actions, GitLab CI)

See the [main project roadmap](https://github.com/jurgenleka/my-signer/blob/main/ROADMAP.md) for detailed plans.

---

## Development

### Setup

```bash
git clone https://github.com/jurgenleka/my-signer-cli.git
cd my-signer-cli
bundle install
```

### Run locally

```bash
bundle exec exe/mysigner [command]
```

### Run tests

```bash
bundle exec rspec
```

### Install locally

```bash
bundle exec rake install
```

---

## Architecture

My Signer CLI is a **standalone Ruby gem** that communicates with the My Signer API via HTTP:

```
┌─────────────────────────────────────────────────────────────┐
│                      mysigner CLI                            │
│                       (This Repo)                            │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────┐ │
│  │ Auth/Config │  │ Build/Export │  │   Upload/Submit     │ │
│  └─────────────┘  └──────────────┘  └─────────────────────┘ │
└────────────────────────┬────────────────────────────────────┘
                         │ HTTP REST API
                         │ Bearer Token Auth
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                     My Signer API                            │
│                      (Rails App)                             │
└───────┬─────────────────────────────────────┬───────────────┘
        │ JWT Auth                            │ Service Account
        ▼                                     ▼
┌─────────────────┐                   ┌─────────────────┐
│  App Store      │                   │  Google Play    │
│  Connect API    │                   │  Developer API  │
└─────────────────┘                   └─────────────────┘
```

**Why Separate Repositories?**
- ✅ Clean separation of concerns
- ✅ Independent versioning
- ✅ CLI can be open-sourced while API stays private
- ✅ Standard approach (Stripe, Heroku, GitHub use this model)

---

## Troubleshooting

### Run the Doctor

The fastest way to diagnose and fix issues:

```bash
mysigner doctor
```

This checks your entire setup and offers to fix common problems automatically.

### Common Issues

#### "Build not found" after upload

Apple takes 5-15 minutes to process builds. Run sync to fetch the latest:

```bash
mysigner sync
```

#### "Profile expired" or signing errors

Re-sync to refresh profiles, or check in the dashboard:

```bash
mysigner sync --force
mysigner profiles
```

#### "Keystore not found" (Android)

Upload your keystore and activate it:

```bash
mysigner keystore upload /path/to/keystore.jks
mysigner keystore activate ID
```

#### "No signing identity for team"

Your certificate isn't in the keychain. Open Xcode:
1. Xcode → Settings → Accounts
2. Select your team
3. Click "Download Manual Profiles" or "Manage Certificates"

#### Version code conflict (Android)

My Signer auto-increments version codes. Just run the command again:

```bash
mysigner ship internal --platform android
```

#### "App Store Connect credentials not configured"

Run the doctor to set up credentials interactively:

```bash
mysigner doctor
```

Or re-run onboarding:

```bash
mysigner onboard
```

#### JAVA_HOME issues (Android)

The doctor can auto-detect and fix JAVA_HOME:

```bash
mysigner doctor --platform android
```

### Debug Mode

For verbose output, set the DEBUG environment variable:

```bash
DEBUG=1 mysigner ship testflight
```

---

## Contributing

This is currently a private project. Contributions are not being accepted at this time.

---

## Related Projects

- **[My Signer API](https://github.com/jurgenleka/my-signer)** - The backend API and web dashboard
- **[My Signer Docs](https://github.com/jurgenleka/my-signer/tree/main/app/views/docs)** - In-app documentation source

---

## Support

For questions or issues:
- Check the [main project README](https://github.com/jurgenleka/my-signer/blob/main/README.md)
- See [ROADMAP.md](https://github.com/jurgenleka/my-signer/blob/main/ROADMAP.md) for development plans
- Review [CHANGELOG.md](https://github.com/jurgenleka/my-signer/blob/main/CHANGELOG.md) for recent updates

---

## License

Copyright 2025 MySigner

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

---

**Built with ❤️ by developers who hate provisioning profile hell.**
