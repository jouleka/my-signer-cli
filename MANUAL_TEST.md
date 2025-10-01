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
config.api_token = "your_token_here"
config.organization_id = 1

# Save config (creates ~/.mysigner/config.yml)
config.save

# Display config (token is masked)
config.display
# => {:api_url=>"http://localhost:3000", :api_token=>"your...here", :organization_id=>1}

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
- ✅ Config: 18 examples, 0 failures
- ✅ Client: 15 examples, 0 failures
- ✅ Total: 35 examples, 0 failures

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

## Next Steps

With Config and Client complete, we can now build:
- Thor CLI framework
- `mysigner login` command
- `mysigner logout` command
- `mysigner status` command
- Resource listing commands (devices, profiles, etc.)

