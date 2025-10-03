require 'faraday'
require 'faraday/retry'
require 'json'

module Mysigner
  class Client
    attr_reader :api_url, :api_token

    def initialize(api_url:, api_token:)
      @api_url = api_url
      @api_token = api_token
    end

    # GET request
    def get(path, params: {})
      response = connection.get(path) do |req|
        req.params = params
      end
      handle_response(response)
    rescue Faraday::Error => e
      handle_faraday_error(e)
    end

    # POST request
    def post(path, body: {})
      response = connection.post(path) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = body.to_json
      end
      handle_response(response)
    rescue Faraday::Error => e
      handle_faraday_error(e)
    end

    # PATCH request
    def patch(path, body: {})
      response = connection.patch(path) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = body.to_json
      end
      handle_response(response)
    rescue Faraday::Error => e
      handle_faraday_error(e)
    end

    # DELETE request
    def delete(path)
      response = connection.delete(path)
      handle_response(response)
    rescue Faraday::Error => e
      handle_faraday_error(e)
    end

    # Test connection with status endpoint
    def test_connection
      get('/api/v1/status')
    rescue ClientError => e
      raise e
    rescue => e
      raise ConnectionError, "Failed to connect: #{e.message}"
    end

    # Expose connection for direct access (e.g., binary downloads)
    def connection
      @connection ||= Faraday.new(url: @api_url) do |f|
        # Request middleware
        f.request :authorization, 'Bearer', @api_token
        f.request :json

        # Retry failed requests
        f.request :retry, {
          max: 3,
          interval: 0.5,
          interval_randomness: 0.5,
          backoff_factor: 2,
          retry_statuses: [429, 500, 502, 503, 504],
          methods: [:get, :post, :patch, :delete]
        }

        # Response middleware
        f.response :json, content_type: /\bjson$/
        # Don't use raise_error - we'll handle errors manually

        # Adapter
        f.adapter Faraday.default_adapter
      end
    end

    private

    def handle_response(response)
      case response.status
      when 200..299
        {
          success: true,
          status: response.status,
          data: response.body,
          headers: response.headers
        }
      else
        handle_error_response(response)
      end
    rescue Faraday::Error => e
      handle_faraday_error(e)
    end

    def handle_error_response(response)
      error_data = response.body.is_a?(Hash) ? response.body : {}
      error_message = error_data['message'] || error_data['error'] || 'Unknown error'

      case response.status
      when 401
        raise UnauthorizedError, "Unauthorized: #{error_message}"
      when 403
        raise ForbiddenError, "Forbidden: #{error_message}"
      when 404
        raise NotFoundError, "Not found: #{error_message}"
      when 422
        raise ValidationError.new(error_message, error_data['details'])
      when 429
        raise RateLimitError.new(error_message, error_data['retry_after'])
      when 500..599
        raise ServerError, "Server error (#{response.status}): #{error_message}"
      else
        raise ClientError, "Request failed (#{response.status}): #{error_message}"
      end
    end

    def handle_faraday_error(error)
      case error
      when Faraday::TimeoutError
        raise TimeoutError, "Request timeout: #{error.message}"
      when Faraday::ConnectionFailed
        # Check if it's a wrapped timeout error
        if error.wrapped_exception.is_a?(Net::OpenTimeout) || error.wrapped_exception.is_a?(Net::ReadTimeout)
          raise TimeoutError, "Request timeout: #{error.message}"
        else
          raise ConnectionError, "Connection failed: #{error.message}"
        end
      when Faraday::UnauthorizedError
        raise UnauthorizedError, "Invalid or missing API token"
      when Faraday::ForbiddenError
        raise ForbiddenError, "Access forbidden"
      when Faraday::ResourceNotFound
        raise NotFoundError, "Resource not found"
      when Faraday::ClientError
        raise ClientError, "Client error: #{error.message}"
      when Faraday::ServerError
        raise ServerError, "Server error: #{error.message}"
      else
        raise ClientError, "Request failed: #{error.message}"
      end
    end
  end

  # Custom errors
  class ClientError < StandardError; end
  class ConnectionError < ClientError; end
  class TimeoutError < ClientError; end
  class UnauthorizedError < ClientError; end
  class ForbiddenError < ClientError; end
  class NotFoundError < ClientError; end
  class ServerError < ClientError; end
  
  class ValidationError < ClientError
    attr_reader :details

    def initialize(message, details = nil)
      super(message)
      @details = details
    end
  end

  class RateLimitError < ClientError
    attr_reader :retry_after

    def initialize(message, retry_after = nil)
      super(message)
      @retry_after = retry_after
    end
  end
end

