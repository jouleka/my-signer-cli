#!/usr/bin/env ruby
# Manual test script to verify Config and Client work
# Run with: bundle exec ruby test_manual.rb

require_relative 'lib/mysigner'

puts "=" * 60
puts "My Signer CLI - Manual Test"
puts "=" * 60
puts

# Test 1: Config Management
puts "1. Testing Config Management"
puts "-" * 60

config = Mysigner::Config.new
puts "✅ Config instance created"

# Set some values
config.api_url = "http://localhost:3000"
config.api_token = "test_token_12345678"
config.organization_id = 1

puts "✅ Config values set:"
puts "   - API URL: #{config.api_url}"
puts "   - API Token: #{config.display[:api_token]}"
puts "   - Org ID: #{config.organization_id}"

# Save config
config.save
puts "✅ Config saved to #{Mysigner::Config::CONFIG_FILE}"

# Load config
new_config = Mysigner::Config.new
puts "✅ Config loaded from file"
puts "   - API URL: #{new_config.api_url}"
puts "   - Valid?: #{new_config.valid?}"

# Clean up
new_config.clear
puts "✅ Config cleared"
puts

# Test 2: API Client (requires running API server)
puts "2. Testing API Client"
puts "-" * 60

puts
puts "⚠️  Note: To test the API client, you need:"
puts "   1. My Signer API running at http://localhost:3000"
puts "   2. A valid API token"
puts
puts "Example usage:"
puts

puts "# Create client"
puts "client = Mysigner::Client.new("
puts "  api_url: 'http://localhost:3000',"
puts "  api_token: 'your_token_here'"
puts ")"
puts

puts "# Test connection"
puts "response = client.test_connection"
puts "puts response[:data]  # => { 'status' => 'ok', 'message' => '...' }"
puts

puts "# List organizations"
puts "response = client.get('/api/v1/organizations')"
puts "organizations = response[:data]['organizations']"
puts

puts "# List devices for org #1"
puts "response = client.get('/api/v1/organizations/1/devices')"
puts "devices = response[:data]['devices']"
puts

puts "# Register a new device"
puts "response = client.post('/api/v1/organizations/1/devices', body: {"
puts "  name: 'Test iPhone',"
puts "  udid: '00008030-001A1B2C3D4E567F',"
puts "  platform: 'IOS'"
puts "})"
puts

puts "# Error handling"
puts "begin"
puts "  client.get('/api/v1/organizations/999')  # Non-existent org"
puts "rescue Mysigner::NotFoundError => e"
puts "  puts \"Error: \#{e.message}\""
puts "end"
puts

puts "=" * 60
puts "✅ All basic tests completed!"
puts "=" * 60
puts
puts "To run automated tests: bundle exec rspec"
puts

