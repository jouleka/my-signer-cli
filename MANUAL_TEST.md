# Manual Testing Guide

## Prerequisites

1. Ruby 3.4.5 installed via rbenv
2. Bundle install completed (`bundle install`)
3. My Signer API running at `http://localhost:3000` (for Client tests)
4. Valid API token (get from My Signer dashboard)

## Running Automated Tests

```bash
# Run all tests
bundle exec rspec

# Run specific tests
bundle exec rspec spec/config_spec.rb  # Config tests (18 examples)
bundle exec rspec spec/client_spec.rb  # Client tests (15 examples)

# With documentation format
bundle exec rspec --format documentation
```

## Test 1: Config Management

```bash
# In the my-signer-cli directory
bundle exec irb
```

```ruby
require_relative 'lib/mysigner'

# Create config
config = Mysigner::Config.new

# Set values
config.api_url = "http://localhost:3000"
config.current_organization_id = 1
config.save_token_for_org(1, 'My Organization', 'your_token_here')

# Save config (creates ~/.mysigner/config.yml)
config.save

# Display config (token is masked)
config.display
# => {:api_url=>"http://localhost:3000", :current_organization=>"My Organization (ID: 1)", :current_token=>"your...here"}

# Check if valid
config.valid?
# => true

# Load config in new instance
new_config = Mysigner::Config.new
new_config.api_url
# => "http://localhost:3000"

# Clear config
config.clear
```

## Test 2: API Client

**⚠️ Requires My Signer API running on http://localhost:3000**

```bash
bundle exec irb
```

```ruby
require_relative 'lib/mysigner'

# Create client
client = Mysigner::Client.new(
  api_url: 'http://localhost:3000',
  api_token: 'your_actual_token'  # Get from My Signer dashboard
)

# Test connection
response = client.test_connection
puts response[:data]
# => {"status"=>"ok", "message"=>"My Signer API v1"}

# List organizations
response = client.get('/api/v1/organizations')
orgs = response[:data]['organizations']
puts orgs.first
# => {"id"=>1, "name"=>"My Org", ...}

# List devices for organization #1
response = client.get('/api/v1/organizations/1/devices')
devices = response[:data]['devices']
puts "Found #{devices.count} devices"

# Register a new device
response = client.post('/api/v1/organizations/1/devices', body: {
  name: 'Test iPhone',
  udid: '00008030-001A1B2C3D4E567F',
  platform: 'IOS'
})
puts response[:data]
# => {"message"=>"Device registered successfully", "device"=>{...}}

# Error handling
begin
  client.get('/api/v1/organizations/999')  # Non-existent org
rescue Mysigner::NotFoundError => e
  puts "Caught error: #{e.message}"
end
# => "Caught error: Not found: Organization not found"
```

## Test Results ✅

**All tests passing:**
- ✅ Total: 87 examples, 0 failures (16 pending)
- ✅ Ship tests: 34 examples, 0 failures
- ✅ Config: 18 examples, 0 failures
- ✅ Client: 15 examples, 0 failures

Note: 16 tests are pending because they require specific test project setups (tvOS, watchOS, macOS platforms, etc.)

## What's Working

### Config Class (`lib/mysigner/config.rb`)
- ✅ Save/load YAML configuration
- ✅ Store API credentials securely (600 permissions)
- ✅ Validate required fields
- ✅ Mask sensitive tokens in display
- ✅ Clear configuration

### Client Class (`lib/mysigner/client.rb`)
- ✅ GET/POST/PATCH/DELETE HTTP methods
- ✅ Bearer token authentication
- ✅ Automatic JSON encoding/decoding
- ✅ Retry with exponential backoff (3 attempts)
- ✅ Custom error classes:
  - `UnauthorizedError` (401)
  - `ForbiddenError` (403)
  - `NotFoundError` (404)
  - `ValidationError` (422) - with details
  - `RateLimitError` (429) - with retry_after
  - `ServerError` (500+)
  - `ConnectionError` - network issues
  - `TimeoutError` - request timeouts

## iOS Ship/Submit Commands

### Ship Targets

| Command | What it does |
|---------|--------------|
| `mysigner ship testflight` | Full workflow: Build → Export → Upload to TestFlight |
| `mysigner ship appstore` | Full workflow: Build → Export → Upload → Wait for processing → Submit for App Store review |

### Testing iOS Ship Commands

**Prerequisites:**
1. Logged in with `mysigner login`
2. App Store Connect credentials configured in dashboard
3. Navigate to an iOS project directory

```bash
# Navigate to iOS project
cd ~/path/to/your/ios-project

# Check project is detected
mysigner doctor

# Ship to TestFlight (beta testing)
mysigner ship testflight

# Ship to App Store (production)
mysigner ship appstore

# Ship with options
mysigner ship testflight --team YOUR_TEAM_ID    # Override team
mysigner ship testflight --bundle-id com.app.id # Override bundle ID
mysigner ship testflight --scheme MyScheme      # Specify scheme
mysigner ship appstore --wait                   # Wait for processing

# Advanced: Release type options (App Store only)
mysigner ship appstore --release-type AFTER_APPROVAL  # Auto-release after approval
mysigner ship appstore --release-type MANUAL          # Hold for manual release
mysigner ship appstore --release-type SCHEDULED --scheduled-date 2026-02-01T10:00:00Z
```

### Submit Command (No Build)

Submit an existing build that's already uploaded:

```bash
# Submit latest iOS build for review
mysigner submit

# Submit specific build
mysigner submit --build-number 123

# Submit with metadata overrides
mysigner submit --whats-new "Bug fixes" --support-url https://example.com/support

# Submit with release type
mysigner submit --release-type MANUAL
```

### Error Handling

The CLI provides actionable error messages:

```
✗ App Store Connect credentials not configured

Quick fix:
  mysigner doctor    # Auto-configure now

Or manually:
  1. Run: mysigner onboard
  2. Follow Step 5 to add credentials
```

### Workflow Steps

**TestFlight (3 steps):**
1. Build xcarchive
2. Export IPA
3. Upload to TestFlight

**App Store (5 steps):**
1. Build xcarchive
2. Export IPA
3. Upload to App Store Connect
4. Wait for Apple to process build
5. Submit for App Store review

## Android Ship/Submit Commands

### Ship vs Submit

| Command | What it does |
|---------|--------------|
| `mysigner ship internal --platform android` | Full workflow: Build → Sign → Upload → Assign to track |
| `mysigner submit beta --platform android` | Promote existing version to different track (no build) |

### Auto-Increment Behavior

The CLI automatically increments version codes:

1. **Queries backend** for highest version code recorded for the app
2. **Increments** if local version ≤ highest
3. **Regenerates android folder** (for Expo projects) with new version
4. **Saves build record** to backend after successful upload

### Build Record Auto-Save

After successful upload, the CLI saves a build record to MySigner backend. This ensures:
- Next upload knows the correct version to use
- No "version code already used" errors
- Dashboard shows accurate version history

### Partial Failure Handling

When AAB uploads but track assignment fails (e.g., Play Console not configured):

```
✗ Upload Failed
Error: Google Play API error: Precondition check failed

💡 Google Play Console requires setup before publishing to beta:
   For BETA/ALPHA tracks:
   • Create a closed/open testing track in Play Console
   • Add at least one tester email

   ✅ Your AAB was uploaded successfully!
   → Go to Play Console to complete track setup, then use:
     mysigner submit beta --platform android --version-code VERSION

📝 Build v8 recorded (prevents version conflicts on retry)
```

The build record is still saved so your next `ship` command will use the next version code.

### Manual Testing Android Commands

```bash
# Navigate to an Android/Expo project
cd ~/path/to/your/app

# Ship to internal track
mysigner ship internal --platform android

# Ship to other tracks
mysigner ship alpha --platform android
mysigner ship beta --platform android
mysigner ship production --platform android

# Promote existing build to different track
mysigner submit beta --platform android --version-code 7

# List Android apps
mysigner android list

# Register app from current project
mysigner android init

# Manually add an app
mysigner android add com.example.app --name "My App"
```

## Implemented Commands

All major commands are implemented:

### Authentication
- `mysigner login` - Login with API token
- `mysigner logout` - Clear saved credentials
- `mysigner status` - Show current login status
- `mysigner switch` - Switch organizations

### iOS Commands
- `mysigner ship testflight` - Build and upload to TestFlight
- `mysigner ship appstore` - Build, upload, and submit to App Store
- `mysigner submit` - Submit existing build for review
- `mysigner build` - Build xcarchive only
- `mysigner export` - Export archive to IPA
- `mysigner upload testflight` - Upload existing IPA

### Android Commands
- `mysigner ship internal/alpha/beta/production --platform android`
- `mysigner submit TRACK --platform android`
- `mysigner keystore upload/download`

### Resource Management
- `mysigner devices` - List/add/update devices
- `mysigner profiles` - List/download profiles
- `mysigner certificates` - List/download certificates
- `mysigner orgs` - List organizations

### Diagnostics
- `mysigner doctor` - Health check and auto-fix
- `mysigner onboard` - Interactive setup wizard

