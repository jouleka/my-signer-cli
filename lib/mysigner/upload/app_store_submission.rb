require 'set'

module Mysigner
  module Upload
    class AppStoreSubmission
      class SubmissionError < Mysigner::Error; end

      def initialize(client, organization_id, build_info, metadata_overrides: {}, override_sources: [])
        @client = client
        @organization_id = organization_id
        @build_info = build_info # { bundle_id:, version:, build_number:, app_id:, build_id: }
        @metadata_overrides = metadata_overrides || {}
        @override_sources = Array(override_sources)
        @override_lookup = build_override_lookup(@override_sources)
      end

      # Submit build for App Store review
      def submit_for_review!(automation: nil)
        puts ""
        puts "📤 Preparing for App Store submission..."
        puts ""
        
        begin
          # Step 1: Fetch release metadata from My Signer API
          merged = merge_metadata(fetch_release_metadata)
          metadata = merged[:merged]
          
          if metadata && metadata.any?
            puts "✓ Loaded release configuration from My Signer"
            puts ""
            display_metadata(metadata)
          else
            puts "⚠️  No release configuration found in My Signer"
            puts "   Create one at: #{@client.api_url}/organizations/#{@organization_id}/app_store_releases"
            puts ""
          end
          
          # Enrich build_info with config values for smart build selection
          enriched_build_info = symbolize_keys(@build_info)
          if metadata
            # min_build_number: skip builds below this number
            if metadata['build_number'] && !enriched_build_info[:build_number]
              enriched_build_info[:min_build_number] = metadata['build_number'].to_i
            end
            # Use version_string from config if not specified
            if metadata['version_string'] && !enriched_build_info[:version]
              enriched_build_info[:version] = metadata['version_string']
            end
          end
          
          automation_result = if automation
            automation.perform!(
              metadata: metadata,
              build_info: enriched_build_info,
              metadata_overrides: @metadata_overrides
            )
          else
            guide_to_manual_submission(metadata)
            nil
          end

          { success: true, metadata: metadata, automation: automation_result }
          
        rescue => e
          raise SubmissionError, "Failed to prepare submission: #{e.message}"
        end
      end

      private

      def fetch_release_metadata
        # Fetch release metadata from My Signer API
        begin
          response = @client.get(
            "/api/v1/organizations/#{@organization_id}/app_store_releases",
            params: { bundle_id: @build_info[:bundle_id] }
          )
          
          if response[:success]
            data = response[:data]
            # API returns { app_store_releases: [...] } - extract first release
            if data.is_a?(Hash) && data['app_store_releases'].is_a?(Array)
              data['app_store_releases'].first
            elsif data.is_a?(Hash) && data['app_store_release']
              # Single release format
              data['app_store_release']
            else
              data
            end
          else
            nil
          end
        rescue Mysigner::NotFoundError
          # No configuration found - that's okay
          nil
        rescue StandardError => e
          puts "⚠️  Could not fetch release metadata: #{e.message}"
          nil
        end
      end

      # Fetch release config and extract min_build_number for smart build selection
      def fetch_release_config
        metadata = fetch_release_metadata
        return {} unless metadata
        
        config = {}
        config[:min_build_number] = metadata['build_number'].to_i if metadata['build_number']
        config[:release_type] = metadata['release_type'] if metadata['release_type']
        config[:earliest_release_date] = metadata['earliest_release_date'] if metadata['earliest_release_date']
        config
      end

      def merge_metadata(api_metadata)
        api_data = stringify_keys(api_metadata || {})
        overrides = stringify_keys(@metadata_overrides)
        {
          merged: deep_merge(api_data, overrides),
          api: api_data,
          overrides: overrides
        }
      end

      def guide_to_manual_submission(metadata)
        puts "📋 Next Steps for App Store Submission"
        puts "=" * 60
        puts ""
        puts "Your build is uploaded to App Store Connect!"
        puts ""
        puts "To submit for review:"
        puts "  1. Wait for Apple to process the build (5-15 minutes)"
        puts "  2. Open App Store Connect:"
        puts "     https://appstoreconnect.apple.com"
        puts "  3. Select your app and go to 'App Store' tab"
        puts "  4. Create a new version or select existing one"
        puts "  5. Select this build (#{@build_info[:version]} / #{@build_info[:build_number]})"
        puts "  6. Add screenshots and metadata if not already present"
        puts "  7. Click 'Submit for Review'"
        puts ""

        if metadata && metadata['auto_submit']
          puts "💡 Auto-submit enabled"
        end

        puts ""
        puts "Tip: rerun with --submit-for-review when ready"
        puts "     Use --wait/--asc-timeout-seconds to control polling"
        puts ""
      end

      def display_metadata(metadata)
        puts "📝 Release Configuration:"
        print_metadata_line('Bundle ID', metadata['bundle_identifier'], 'bundle_identifier')
        print_metadata_line('App Name', metadata['app_name'], 'app_name') if metadata['app_name']
        
        # Version info from config
        print_metadata_line('Version String', metadata['version_string'], 'version_string') if metadata['version_string']
        print_metadata_line('Min Build #', metadata['build_number'], 'build_number') if metadata['build_number']

        if metadata['whats_new'] && !metadata['whats_new'].to_s.strip.empty?
          puts "   What's New: #{truncate(metadata['whats_new'])}#{override_suffix('whats_new')}"
        else
          puts "   What's New: —#{override_suffix('whats_new')}"
        end
        
        if metadata['promotional_text'] && !metadata['promotional_text'].to_s.strip.empty?
          puts "   Promo Text: #{truncate(metadata['promotional_text'])}#{override_suffix('promotional_text')}"
        end

        print_metadata_line('Support URL', metadata['support_url'], 'support_url')
        print_metadata_line('Marketing URL', metadata['marketing_url'], 'marketing_url')
        print_metadata_line('Privacy URL', metadata['privacy_policy_url'], 'privacy_policy_url')
        
        # Release settings
        release_type_label = format_release_type(metadata['release_type'])
        print_metadata_line('Release Type', release_type_label, 'release_type')
        if metadata['release_type'] == 'SCHEDULED' && metadata['earliest_release_date']
          print_metadata_line('Scheduled Date', metadata['earliest_release_date'], 'earliest_release_date')
        end
        
        print_metadata_toggle('Auto-submit', metadata['auto_submit'], 'auto_submit')
        print_metadata_toggle('Phased Release', metadata['phased_release'], 'phased_release')

        if metadata['localizations'].is_a?(Array) && metadata['localizations'].any?
          first_locale = metadata['localizations'].first
          locale_code = first_locale['locale'] || first_locale['localeCode'] || 'default'
          puts "   Localizations: #{metadata['localizations'].count} (showing #{locale_code})#{override_suffix('localizations')}"
        end

        warn_missing_submission_fields(metadata)
        puts ""
      end
      
      def format_release_type(release_type)
        case release_type
        when 'AFTER_APPROVAL' then 'After Approval (auto-release)'
        when 'MANUAL' then 'Manual (hold for manual release)'
        when 'SCHEDULED' then 'Scheduled'
        else release_type || 'After Approval (default)'
        end
      end

      def deep_merge(base, overrides)
        merged = base.dup

        overrides.each do |key, value|
          merged[key] = if merged[key].is_a?(Hash) && value.is_a?(Hash)
            deep_merge(merged[key], value)
          else
            value
          end
        end

        merged
      end

      def stringify_keys(object)
        case object
        when Hash
          object.each_with_object({}) do |(k, v), memo|
            memo[k.to_s] = stringify_keys(v)
          end
        when Array
          object.map { |item| stringify_keys(item) }
        else
          object
        end
      end

      def symbolize_keys(object)
        case object
        when Hash
          object.each_with_object({}) do |(k, v), memo|
            memo[k.to_sym] = symbolize_keys(v)
          end
        when Array
          object.map { |item| symbolize_keys(item) }
        else
          object
        end
      end

      def truncate(text, max = 100)
        text = text.to_s
        return '—' if text.strip.empty?

        text.length > max ? "#{text[0, max]}..." : text
      end

      def print_metadata_line(label, value, key)
        display = value && !value.to_s.strip.empty? ? value : '—'
        puts "   #{label}: #{display}#{override_suffix(key)}"
      end

      def print_metadata_toggle(label, value, key)
        human = value.nil? ? '—' : (value ? 'Yes' : 'No')
        puts "   #{label}: #{human}#{override_suffix(key)}"
      end

      def override_suffix(key)
        sources = Array(@override_lookup[key])
        return '' if sources.empty?

        formatted = sources.map do |source|
          case source[:type]
          when :inline then 'CLI flag'
          when :file
            File.basename(source[:path])
          else
            source[:type].to_s
          end
        end.uniq

        " (override: #{formatted.join(', ')})"
      end

      def build_override_lookup(sources)
        lookup = Hash.new { |h, k| h[k] = [] }
        sources.each do |source|
          Array(source[:keys]).each do |key|
            lookup[key] << source
          end
        end
        lookup
      end

      def warn_missing_submission_fields(metadata)
        return unless metadata['auto_submit']

        # Get version to check if first version
        version_string = metadata['version_string'] || metadata['version'] || '1.0'
        is_first_version = version_string.split('.').first.to_i <= 1

        warnings = []
        # What's New only required for updates (version > 1.0)
        warnings << "Missing What's New copy (required for version updates)" if !is_first_version && metadata['whats_new'].to_s.strip.empty?
        
        # Support URL may already be in App Store Connect, so just note it
        if metadata['support_url'].to_s.strip.empty?
          warnings << "Support URL not configured in My Signer (will use App Store Connect value if available)"
        end

        return if warnings.empty?

        puts "   ⚠️  Notes:" unless warnings.empty?
        warnings.each { |msg| puts "     - #{msg}" }
      end
    end
  end
end


