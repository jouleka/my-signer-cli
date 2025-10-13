# My Signer CLI

**One command from code to TestFlight. No provisioning hell, no manual certificate wrangling.**

Command-line interface for [My Signer](https://github.com/jurgenleka/my-signer) - the modern iOS code signing automation tool.

---

## What is My Signer CLI?

My Signer CLI is a command-line tool that connects to the My Signer API to manage iOS certificates, devices, and provisioning profiles directly from your terminal or CI/CD pipeline.

### The Problem We Solve

iOS developers spend hours dealing with:
- ❌ Manual device registration through Apple Developer Portal
- ❌ Downloading and installing provisioning profiles
- ❌ Certificate management and renewal
- ❌ Complex Xcode build configurations
- ❌ TestFlight upload processes

### Our Solution

✅ **Simple Commands** - `mysigner device add`, `mysigner profile download`  
✅ **CI/CD Ready** - Automate builds in GitHub Actions, GitLab CI, etc.  
✅ **API-Powered** - Backed by My Signer API for team collaboration  
✅ **Fast** - No GUI overhead, pure command-line efficiency  
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
# Enter your API token when prompted
# Enter your API URL (default: http://localhost:3000)
# Select your organization
```

### 3. Start Managing Your iOS Signing

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

### Authentication

```bash
mysigner login              # Authenticate with API token
mysigner logout             # Clear stored credentials
mysigner status             # Check connection and show stats
```

### Organizations

```bash
mysigner orgs               # List accessible organizations
mysigner org:switch ID      # Switch active organization
```

### Devices

```bash
mysigner devices                           # List all devices
mysigner devices --platform ios            # Filter by platform
mysigner devices --search "iPhone"         # Search devices
mysigner device show ID                    # Show device details
mysigner device add NAME UDID              # Register new device
mysigner device rename ID "New Name"       # Update device name
```

### Provisioning Profiles

```bash
mysigner profiles                          # List all profiles
mysigner profiles --type development       # Filter by type
mysigner profile show ID                   # Show profile details
mysigner profile download ID               # Download .mobileprovision
mysigner profile create                    # Create new profile (interactive)
mysigner profile delete ID                 # Delete profile
```

### Certificates

```bash
mysigner certificates                      # List all certificates
mysigner certificates --type development   # Filter by type
mysigner certificate show ID               # Show certificate details
mysigner certificate download ID           # Download .cer file
```

### Bundle IDs

```bash
mysigner bundle-ids                        # List all bundle IDs
mysigner bundle-ids --search "com.example" # Search bundle IDs
mysigner bundle-id show ID                 # Show bundle ID details
```

### Sync

```bash
mysigner sync               # Trigger App Store Connect sync
mysigner sync:status        # Check sync status
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

**Current Version**: 0.1.0 (Alpha - Functional)

✅ **Complete**:
- ✅ Gem structure and dependencies (Thor, Faraday, Reline, Base64)
- ✅ Config management (`~/.mysigner/config.yml`)
- ✅ API client (Faraday with retry & error handling)
- ✅ Core commands (login, logout, config, status, orgs, switch)
- ✅ Resource commands (devices, profiles, certificates)
- ✅ 90 RSpec tests (100% passing)
- ✅ Interactive prompts and confirmations
- ✅ Binary file downloads

📅 **Next Up**:
- v0.1.0 Polish & Release
- OR Phase 6: Build & Ship
  - `mysigner build` - Xcode build wrapper
  - `mysigner upload testflight` - TestFlight upload
- `mysigner ship` - One-command deploy (TestFlight & App Store)

📅 **Future**:
- Pretty tables (TTY::Table)
- Progress spinners (TTY::Spinner)
- `--json` flag for scripting
- Xcode project detection
- Interactive wizards
- CI/CD templates

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
┌─────────────────┐
│  mysigner CLI   │
│   (This Repo)   │
└────────┬────────┘
         │ HTTP REST API
         │ Bearer Token Auth
         ▼
┌─────────────────┐
│ My Signer API   │
│  (Rails App)    │
└────────┬────────┘
         │ JWT Auth
         ▼
┌─────────────────┐
│  App Store      │
│  Connect API    │
└─────────────────┘
```

**Why Separate Repositories?**
- ✅ Clean separation of concerns
- ✅ Independent versioning
- ✅ CLI can be open-sourced while API stays private
- ✅ Standard approach (Stripe, Heroku, GitHub use this model)

---

## Contributing

This is currently a private project. Contributions are not being accepted at this time.

---

## Related Projects

- **[My Signer API](https://github.com/jurgenleka/my-signer)** - The backend API and web dashboard
- **[My Signer Docs](https://github.com/jurgenleka/my-signer/blob/main/PROJECT_DOCS.md)** - Documentation organization

---

## Support

For questions or issues:
- Check the [main project README](https://github.com/jurgenleka/my-signer/blob/main/README.md)
- See [ROADMAP.md](https://github.com/jurgenleka/my-signer/blob/main/ROADMAP.md) for development plans
- Review [CHANGELOG.md](https://github.com/jurgenleka/my-signer/blob/main/CHANGELOG.md) for recent updates

---

## License

Copyright 2025 Jurgen Leka

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

### Ship to App Store

```bash
mysigner ship appstore --submit-for-review
mysigner ship appstore --release-notes "Bug fixes"         # Inline release notes override
mysigner ship appstore --metadata-file metadata.json        # Merge custom metadata (JSON/YAML)
mysigner ship appstore --no-wait                           # Skip build-processing wait (manual submission)
mysigner ship appstore --asc-poll-seconds 30               # Custom ASC polling cadence
mysigner ship appstore --no-auto-submit                    # Run automation but skip final submission
```
