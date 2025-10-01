require "spec_helper"
require "webmock/rspec"

RSpec.describe Mysigner::Client do
  let(:api_url) { 'http://localhost:3000' }
  let(:api_token) { 'test_token_12345' }
  let(:client) { Mysigner::Client.new(api_url: api_url, api_token: api_token) }

  describe "#initialize" do
    it "creates a client with api_url and api_token" do
      expect(client.api_url).to eq(api_url)
      expect(client.api_token).to eq(api_token)
    end
  end

  describe "#get" do
    it "makes a GET request with authorization header" do
      stub_request(:get, "#{api_url}/api/v1/organizations")
        .with(headers: { 'Authorization' => 'Bearer test_token_12345' })
        .to_return(
          status: 200,
          body: { data: 'test' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get('/api/v1/organizations')
      
      expect(response[:success]).to be true
      expect(response[:status]).to eq(200)
      expect(response[:data]['data']).to eq('test')
    end

    it "passes query parameters" do
      stub_request(:get, "#{api_url}/api/v1/devices")
        .with(query: { platform: 'IOS', page: '1' })
        .to_return(status: 200, body: {}.to_json)

      client.get('/api/v1/devices', params: { platform: 'IOS', page: 1 })

      expect(WebMock).to have_requested(:get, "#{api_url}/api/v1/devices")
        .with(query: { platform: 'IOS', page: '1' })
    end
  end

  describe "#post" do
    it "makes a POST request with JSON body" do
      stub_request(:post, "#{api_url}/api/v1/organizations/1/devices")
        .with(
          headers: { 'Authorization' => 'Bearer test_token_12345', 'Content-Type' => 'application/json' },
          body: { name: 'iPhone', udid: '12345' }.to_json
        )
        .to_return(status: 201, body: { id: 1, name: 'iPhone' }.to_json)

      response = client.post('/api/v1/organizations/1/devices', body: { name: 'iPhone', udid: '12345' })
      
      expect(response[:success]).to be true
      expect(response[:status]).to eq(201)
    end
  end

  describe "#patch" do
    it "makes a PATCH request with JSON body" do
      stub_request(:patch, "#{api_url}/api/v1/organizations/1/devices/1")
        .with(body: { name: 'Updated iPhone' }.to_json)
        .to_return(status: 200, body: { id: 1, name: 'Updated iPhone' }.to_json)

      response = client.patch('/api/v1/organizations/1/devices/1', body: { name: 'Updated iPhone' })
      
      expect(response[:success]).to be true
      expect(response[:status]).to eq(200)
    end
  end

  describe "#delete" do
    it "makes a DELETE request" do
      stub_request(:delete, "#{api_url}/api/v1/organizations/1/profiles/1")
        .to_return(status: 200, body: { message: 'Deleted' }.to_json)

      response = client.delete('/api/v1/organizations/1/profiles/1')
      
      expect(response[:success]).to be true
      expect(response[:status]).to eq(200)
    end
  end

  describe "#test_connection" do
    it "tests connection using status endpoint" do
      stub_request(:get, "#{api_url}/api/v1/status")
        .to_return(status: 200, body: { status: 'ok' }.to_json)

      response = client.test_connection
      expect(response[:success]).to be true
    end

    it "raises ConnectionError if connection fails" do
      stub_request(:get, "#{api_url}/api/v1/status")
        .to_raise(Faraday::ConnectionFailed.new("Failed to open TCP connection"))

      expect {
        client.test_connection
      }.to raise_error(Mysigner::ConnectionError, /Connection failed/)
    end
  end

  describe "error handling" do
    it "raises UnauthorizedError for 401 responses" do
      stub_request(:get, "#{api_url}/api/v1/organizations")
        .to_return(
          status: 401,
          body: { error: 'unauthorized', message: 'Invalid token' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect {
        client.get('/api/v1/organizations')
      }.to raise_error(Mysigner::UnauthorizedError, /Invalid token/)
    end

    it "raises ForbiddenError for 403 responses" do
      stub_request(:get, "#{api_url}/api/v1/organizations/1")
        .to_return(
          status: 403,
          body: { error: 'forbidden', message: 'Insufficient permissions' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect {
        client.get('/api/v1/organizations/1')
      }.to raise_error(Mysigner::ForbiddenError, /Insufficient permissions/)
    end

    it "raises NotFoundError for 404 responses" do
      stub_request(:get, "#{api_url}/api/v1/organizations/999")
        .to_return(
          status: 404,
          body: { error: 'not_found', message: 'Organization not found' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect {
        client.get('/api/v1/organizations/999')
      }.to raise_error(Mysigner::NotFoundError, /Organization not found/)
    end

    it "raises ValidationError for 422 responses with details" do
      stub_request(:post, "#{api_url}/api/v1/organizations/1/devices")
        .to_return(
          status: 422,
          body: {
            error: 'validation_failed',
            message: 'Validation failed',
            details: { name: ["can't be blank"], udid: ["is invalid"] }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect {
        client.post('/api/v1/organizations/1/devices', body: {})
      }.to raise_error(Mysigner::ValidationError) do |error|
        expect(error.message).to include('Validation failed')
        expect(error.details).to eq({ "name" => ["can't be blank"], "udid" => ["is invalid"] })
      end
    end

    it "raises RateLimitError for 429 responses" do
      stub_request(:get, "#{api_url}/api/v1/organizations")
        .to_return(
          status: 429,
          body: { error: 'rate_limit_exceeded', message: 'Rate limit exceeded', retry_after: 60 }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect {
        client.get('/api/v1/organizations')
      }.to raise_error(Mysigner::RateLimitError) do |error|
        expect(error.message).to include('Rate limit exceeded')
        expect(error.retry_after).to eq(60)
      end
    end

    it "raises ServerError for 500 responses" do
      stub_request(:get, "#{api_url}/api/v1/organizations")
        .to_return(
          status: 500,
          body: { error: 'internal_server_error', message: 'Something went wrong' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect {
        client.get('/api/v1/organizations')
      }.to raise_error(Mysigner::ServerError, /Something went wrong/)
    end

    it "raises TimeoutError for timeout errors" do
      stub_request(:get, "#{api_url}/api/v1/organizations")
        .to_timeout

      expect {
        client.get('/api/v1/organizations')
      }.to raise_error(Mysigner::TimeoutError, /Request timeout/)
    end
  end
end

