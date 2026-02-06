module Mysigner
  module Upload
    class AppStoreAutomation
      class AutomationError < Mysigner::Error; end

      DEFAULT_WAIT_TIMEOUT = 900 # 15 minutes
      DEFAULT_POLL_INTERVAL = 15

      attr_reader :wait_enabled, :poll_interval, :timeout, :no_submit

      def initialize(client:, organization_id:, opts: {})
        @client = client
        @organization_id = organization_id
        @wait_enabled = opts.key?(:wait) ? !!opts[:wait] : true

        poll = opts[:poll_interval] || opts[:poll_seconds]
        poll = poll.to_i if poll
        @poll_interval = poll && poll.positive? ? poll : DEFAULT_POLL_INTERVAL

        timeout = opts[:timeout] || opts[:timeout_seconds]
        timeout = timeout.to_i if timeout
        @timeout = timeout && timeout.positive? ? timeout : DEFAULT_WAIT_TIMEOUT

        @no_submit = !!opts[:no_submit]
        @now = opts[:now]
      end

      def perform!(metadata:, build_info:, metadata_overrides: {})
        build_info = symbolize_keys(build_info)
        metadata = metadata || {}

        result = {
          wait: {
            enabled: @wait_enabled,
            poll_seconds: @poll_interval,
            timeout_seconds: @timeout,
            timed_out: false,
            elapsed_seconds: 0,
            last_state: nil
          },
          submitted: false,
          skip_reason: nil,
          submission_source: nil
        }

        puts ""
        puts "🤖 App Store automation in progress..."
        puts ""

        app = ensure_app(build_info[:bundle_id])
        raise AutomationError, "App with bundle ID #{build_info[:bundle_id]} not found" unless app

        build, wait_status = wait_for_build(app['id'], build_info)
        result[:wait].merge!(wait_status)

        unless build
          version_info = [build_info[:version], build_info[:build_number]].compact.join(' / ')
          version_info = "for #{version_info}" unless version_info.empty?
          raise AutomationError, "No processed build found #{version_info}. Upload a build first with 'mysigner ship appstore --wait'"
        end

        unless build_processed?(build)
          raise AutomationError, "Build #{build_info[:version]} (#{build_info[:build_number]}) is still processing. Wait for it or use --wait flag."
        end

        version = ensure_app_store_version(app_id: app['id'], metadata: metadata, overrides: metadata_overrides)
        attach_build_to_version(version_id: version['id'], build_id: build['id'])

        should_submit, submit_source, skip_reason = should_submit_with_reason(metadata, metadata_overrides)

        if should_submit
          submit_for_review(
            version_id: version['id'], 
            version_string: version['version_string'],
            metadata: metadata, 
            overrides: metadata_overrides
          )
          puts "✓ Submitted for App Store review"
          result[:submitted] = true
          result[:submission_source] = submit_source
        else
          puts "💡 Skipping automatic submission (#{skip_reason})"
          result[:skip_reason] = skip_reason
        end

        puts ""
        puts "✅ App Store automation complete"

        result
      end

      private

      def ensure_app(bundle_id)
        response = @client.get(
          "/api/v1/organizations/#{@organization_id}/apple_apps",
          params: { bundle_id: bundle_id }
        )

        Array(response[:data]['data']['apps']).first
      rescue StandardError => e
        raise AutomationError, "Failed to fetch app: #{e.message}"
      end

      def wait_for_build(app_id, build_info)
        build = latest_build(app_id, build_info)
        status = {
          timed_out: false,
          elapsed_seconds: 0,
          last_state: build_state(build)
        }

        return [build, status] unless @wait_enabled

        puts "⏳ Waiting for Apple to finish processing the build..."
        puts "   Polling every #{@poll_interval}s (timeout #{@timeout}s)"
        print ""

        start_time = current_time
        
        loop do
          build = latest_build(app_id, build_info)
          status[:last_state] = build_state(build)

          if build && build_processed?(build)
            puts "\r✓ Build is processed and ready".ljust(70)
            puts ""
            return [build, status]
          end
          
          elapsed = current_time - start_time
          status[:elapsed_seconds] = elapsed

          if elapsed >= @timeout
            status[:timed_out] = true
            puts "\r✗ Timed out after #{format_duration(elapsed)} (use --asc-timeout-seconds to extend)".ljust(90)
            puts ""
            return [build, status]
          end

          state_msg = status[:last_state] || (build ? 'pending from Apple' : 'waiting for sync')
          print "\r   Waiting #{format_duration(elapsed)} / #{format_duration(@timeout)} – #{state_msg}"
          $stdout.flush
          sleep @poll_interval
        end
      end

      def latest_build(app_id, build_info)
        # For ship appstore (use_latest): get absolute latest build, no filtering
        # For mysigner submit: filter by version/build_number to get a specific one
        params = {
          app_id: app_id,
          processed_only: !@wait_enabled
        }
        
        # Only filter by version/build if NOT using latest
        unless build_info[:use_latest]
          params[:version] = build_info[:version] if build_info[:version]
          params[:build_number] = build_info[:build_number] if build_info[:build_number]
        end
        
        # Apply min_build_number filter if set in release config
        if build_info[:min_build_number]
          params[:min_build_number] = build_info[:min_build_number]
        end
        
        response = @client.get(
          "/api/v1/organizations/#{@organization_id}/builds",
          params: params.compact
        )

        builds = Array(response[:data]['data']['builds'])
        
        # Smart build selection: filter by min_build_number client-side if API doesn't support it
        if build_info[:min_build_number] && builds.any?
          min_bn = build_info[:min_build_number].to_i
          builds = builds.select { |b| b['build_number'].to_i >= min_bn }
        end
        
        builds.first  # Already ordered by uploaded_date desc
      rescue Mysigner::NotFoundError
        nil
      rescue StandardError => e
        raise AutomationError, "Failed to fetch build: #{e.message}"
      end

      def build_processed?(build)
        processing_state = build['processing_state'] || build.dig('attributes', 'processingState')
        status = build['status'] || build.dig('attributes', 'buildStatus')

        %w[VALID PROCESSING_COMPLETE].include?(processing_state) || status == 'valid'
      end

      def build_state(build)
        return nil unless build

        state = build['processing_state'] || build.dig('attributes', 'processingState')
        status = build['status'] || build.dig('attributes', 'buildStatus')
        joined = [state, status].compact.map { |value| value.to_s.upcase }.reject(&:empty?).join(' / ')
        joined.empty? ? 'processing' : joined
      end

      def ensure_app_store_version(app_id:, metadata:, overrides: {})
        desired_version = overrides['version_string'] || metadata['version_string'] || metadata['version']
        desired_version ||= metadata.dig('localizations', 0, 'version_string')

        current_version = fetch_editable_version(app_id)

        if current_version && version_matches?(current_version, desired_version)
          puts "✓ Reusing existing App Store version #{current_version['version_string']}"
          update_version(current_version['id'], metadata, overrides)
          current_version
        else
          version_to_create = desired_version || build_default_version
          puts "✨ Creating new App Store version #{version_to_create}"
          create_version(app_id, version_to_create, metadata, overrides)
        end
      end

      def fetch_editable_version(app_id)
        response = @client.get(
          "/api/v1/organizations/#{@organization_id}/app_store_versions",
          params: { app_id: app_id, editable: true }
        )

        Array(response[:data]['data']['versions']).first
      rescue StandardError => e
        raise AutomationError, "Failed to fetch App Store versions: #{e.message}"
      end

      def version_matches?(version, desired)
        return false unless desired

        normalized = desired.to_s.strip
        return false if normalized.empty?

        version['version_string'] == normalized || version.dig('attributes', 'versionString') == normalized
      end

      def build_default_version
        current_time.strftime('%Y.%m.%d')
      end

      def create_version(app_id, version_string, metadata, overrides)
        payload = {
          app_store_version: {
            app_id: app_id,
            version_string: version_string,
            release_type: determine_release_type(metadata, overrides),
            earliest_release_date: determine_earliest_release_date(metadata, overrides)
          }.compact
        }

        response = @client.post(
          "/api/v1/organizations/#{@organization_id}/app_store_versions",
          body: payload
        )

        response[:data]['data']
      rescue StandardError => e
        raise AutomationError, "Failed to create App Store version: #{e.message}"
      end

      def determine_earliest_release_date(metadata, overrides)
        date = overrides['earliest_release_date'] || metadata['earliest_release_date']
        return nil unless date
        
        # Convert to ISO 8601 if not already
        date.respond_to?(:iso8601) ? date.iso8601 : date.to_s
      end

      def update_version(version_id, metadata, overrides)
        payload = {
          app_store_version: {
            release_type: determine_release_type(metadata, overrides),
            earliest_release_date: determine_earliest_release_date(metadata, overrides)
          }.compact
        }

        @client.patch(
          "/api/v1/organizations/#{@organization_id}/app_store_versions/#{version_id}",
          body: payload
        )
      rescue StandardError => e
        raise AutomationError, "Failed to update App Store version: #{e.message}"
      end

      def determine_release_type(metadata, overrides)
        result = overrides['release_type'] || metadata['release_type']
        
        # FIX v7: Changed default from MANUAL to AFTER_APPROVAL
        # Log deprecation notice if no explicit release_type is set
        if result.nil?
          if ENV['MYSIGNER_DEBUG'] || @deprecation_warned.nil?
            puts "   Note: Using default release_type AFTER_APPROVAL (was MANUAL in older versions)"
            @deprecation_warned = true
          end
          result = 'AFTER_APPROVAL'
        end
        
        result
      end

      def attach_build_to_version(version_id:, build_id:)
        @client.post(
          "/api/v1/organizations/#{@organization_id}/app_store_versions/#{version_id}/build",
          body: { build_id: build_id }
        )

        puts "✓ Attached build to App Store version"
      rescue StandardError => e
        raise AutomationError, "Failed to attach build to version: #{e.message}"
      end

      def should_submit_with_reason(metadata, overrides)
        return [false, nil, '--no-auto-submit flag'] if @no_submit

        if overrides.key?('auto_submit')
          return overrides['auto_submit'] ? [true, 'CLI override', nil] : [false, nil, 'CLI override disabled auto_submit']
        end

        if metadata.key?('auto_submit')
          return metadata['auto_submit'] ? [true, 'Dashboard configuration', nil] : [false, nil, 'Dashboard auto_submit disabled']
        end

        [false, nil, 'No auto_submit configuration']
      end

      def submit_for_review(version_id:, version_string: nil, metadata: {}, overrides: {})
        # Merge metadata and overrides
        merged = metadata.merge(overrides)
        
        # Get version string to check if first version
        version_string ||= merged['version_string'] || merged['version'] || '1.0'
        is_first_version = version_string.split('.').first.to_i <= 1
        
        # Validate required fields for Apple submission
        # Note: What's New is NOT required for version 1.0 (first release)
        # Support URL may already be set in App Store Connect, so we only warn if missing
        missing_fields = []
        missing_fields << "What's New text" if !is_first_version && merged['whats_new'].to_s.strip.empty?
        
        # Don't block on missing support_url - it may already be in App Store Connect
        # Just warn about it
        if merged['support_url'].to_s.strip.empty?
          puts "⚠️  Note: No Support URL provided via CLI - using value from App Store Connect if available"
        end
        
        unless missing_fields.empty?
          raise AutomationError, "Cannot submit to Apple Store: missing required fields: #{missing_fields.join(', ')}. Please configure these in your My Signer dashboard or provide via --whats-new flag."
        end
        
        payload = {
          whats_new: merged['whats_new'],
          keywords: merged['keywords'],
          marketing_url: merged['marketing_url'],
          promotional_text: merged['promotional_text'],
          support_url: merged['support_url'],
          locale: merged['locale']
        }.compact  # Remove nil values

        @client.post(
          "/api/v1/organizations/#{@organization_id}/app_store_versions/#{version_id}/submit",
          body: payload
        )
      rescue AutomationError
        raise
      rescue StandardError => e
        raise AutomationError, "Failed to submit for review: #{e.message}"
      end

      def symbolize_keys(hash)
        hash.each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end
      end


      def format_duration(seconds)
        minutes = (seconds / 60).floor
        seconds = (seconds % 60).round
        format('%<m>02d:%<s>02d', m: minutes, s: seconds)
      end

      def current_time
        (@now && @now.call) || Time.now
      end
    end
  end
end
