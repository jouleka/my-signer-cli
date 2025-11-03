require 'fileutils'
require 'json'

module Mysigner
  module Upload
    class Uploader
      class UploadError < Mysigner::Error; end
      class TransporterNotFoundError < UploadError; end
      class AuthenticationError < UploadError; end

      TRANSPORTER_PATHS = [
        '/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter', # Bundled with Xcode (primary)
        '/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter',    # Standalone Transporter app
        '/usr/local/itms/bin/iTMSTransporter'                                  # Custom installation
      ].freeze

      def initialize(ipa_path, api_key:, api_issuer:, private_key:)
        @ipa_path = File.expand_path(ipa_path)
        @api_key = api_key
        @api_issuer = api_issuer
        @private_key = private_key
        
        validate_ipa!
        detect_transporter!
        setup_private_key!
      end

      def upload!(wait_for_processing: false)
        say_uploading
        
        begin
          # Validate IPA first
          validate_result = validate_ipa
          unless validate_result[:success]
            raise UploadError, "IPA validation failed: #{validate_result[:error]}"
          end
          
          # Upload to App Store Connect
          upload_result = upload_ipa
          unless upload_result[:success]
            raise UploadError, "Upload failed: #{upload_result[:error]}"
          end
          
          say_success
          
          # Optionally wait for processing
          if wait_for_processing
            say_waiting_for_processing
            # TODO: Poll App Store Connect API for build status
            # This requires the App Store Connect API integration
          end
          
          {
            success: true,
            message: "Upload completed successfully"
          }
        rescue => e
          raise UploadError, "Upload failed: #{e.message}"
        end
      end

      private

      def validate_ipa!
        unless File.exist?(@ipa_path)
          raise UploadError, "IPA file not found: #{@ipa_path}"
        end
        
        unless @ipa_path.end_with?('.ipa')
          raise UploadError, "Invalid file type: #{@ipa_path} (must be .ipa)"
        end
        
        # Check file size (should be at least 10KB to catch truly corrupt files)
        file_size = File.size(@ipa_path)
        if file_size < 10_000
          raise UploadError, "IPA file seems too small: #{file_size} bytes (possible corruption)"
        end
      end

      def detect_transporter!
        # We primarily use xcrun altool, but check for iTMSTransporter as fallback
        @transporter_path = TRANSPORTER_PATHS.find { |path| File.exist?(path) }
        
        # Even if iTMSTransporter is not found, xcrun altool should work
        # This is just for informational purposes
        @using_altool = true
      end

      def setup_private_key!
        # iTMSTransporter looks for .p8 files in these locations:
        # - ./private_keys/AuthKey_<KEY_ID>.p8
        # - ~/private_keys/AuthKey_<KEY_ID>.p8
        # - ~/.private_keys/AuthKey_<KEY_ID>.p8  
        # - ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
        
        @private_keys_dir = File.expand_path("~/.private_keys")
        FileUtils.mkdir_p(@private_keys_dir)
        
        @private_key_path = File.join(@private_keys_dir, "AuthKey_#{@api_key}.p8")
        
        # Write the private key to disk
        File.write(@private_key_path, @private_key)
        File.chmod(0600, @private_key_path) # Secure permissions
      end

      def validate_ipa
        puts "📋 Validating IPA..."
        puts ""
        
        # Try altool first (simpler, works today)
        if altool_available?
          validate_with_altool
        elsif @transporter_path
          validate_with_transporter
        else
          puts "⚠️  Skipping validation (no tools available)"
          { success: true } # Continue anyway
        end
      end

      def validate_with_altool
        cmd = [
          'xcrun', 'altool',
          '--validate-app',
          '-f', @ipa_path,
          '-t', 'ios',
          '--apiKey', @api_key,
          '--apiIssuer', @api_issuer
        ].join(' ')
        
        output = `#{cmd} 2>&1`
        success = $?.success?
        
        if success
          puts "✓ Validation passed (altool)"
          { success: true }
        else
          error_message = extract_error_from_output(output)
          puts "✗ Validation failed: #{error_message}"
          { success: false, error: error_message }
        end
      end

      def validate_with_transporter
        # iTMSTransporter verify mode
        # According to https://help.apple.com/itc/transporteruserguide/en.lproj/static.html
        cmd = [
          @transporter_path,
          '-m', 'verify',
          '-f', @ipa_path,
          '-apiKey', @api_key,
          '-apiIssuer', @api_issuer,
          '-t', 'Signiant'  # Transport mode
        ].join(' ')
        
        output = `#{cmd} 2>&1`
        success = $?.success?
        
        if success
          puts "✓ Validation passed (iTMSTransporter)"
          { success: true }
        else
          error_message = extract_error_from_output(output)
          puts "✗ Validation failed: #{error_message}"
          { success: false, error: error_message }
        end
      end

      def upload_ipa
        puts ""
        puts "☁️  Uploading to App Store Connect..."
        puts ""
        
        # Try altool first, fall back to iTMSTransporter
        if altool_available?
          upload_with_altool
        elsif @transporter_path
          upload_with_transporter
        else
          raise UploadError, "No upload tool available. Please ensure Xcode is installed."
        end
      end

      def upload_with_altool
        puts "Using: xcrun altool"
        puts ""
        
        cmd = [
          'xcrun', 'altool',
          '--upload-app',
          '-f', @ipa_path,
          '-t', 'ios',
          '--apiKey', @api_key,
          '--apiIssuer', @api_issuer
        ].join(' ')
        
        # Capture full output for error detection
        output = []
        has_errors = false
        
        # Run with live output
        IO.popen(cmd, err: [:child, :out]) do |io|
          io.each_line do |line|
            output << line
            next if line.strip.empty?
            
            # Detect errors
            if line.include?('ERROR') || line.include?('UPLOAD FAILED')
              has_errors = true
            end
            
            # Show progress indicators
            if line.include?('Uploading') || line.include?('Processing') || 
               line.include?('Verifying') || line.include?('Package')
              print '.'
            elsif line.include?('error') || line.include?('ERROR')
              puts ""
              puts line
            elsif line.include?('SUCCESS') || line.include?('No errors')
              puts ""
              puts line
            end
          end
        end
        
        puts "" # New line after progress dots
        
        # Check both exit code and output for errors
        if $?.success? && !has_errors
          { success: true }
        else
          error_msg = extract_error_from_output(output.join("\n"))
          { success: false, error: error_msg }
        end
      end

      def upload_with_transporter
        puts "Using: iTMSTransporter (future-proof)"
        puts ""
        
        # iTMSTransporter upload mode
        # According to https://help.apple.com/itc/transporteruserguide/en.lproj/static.html
        cmd = [
          @transporter_path,
          '-m', 'upload',
          '-f', @ipa_path,
          '-apiKey', @api_key,
          '-apiIssuer', @api_issuer,
          '-t', 'Signiant'  # Transport mode (can also use 'Aspera' or 'DAV')
        ].join(' ')
        
        # Capture output
        output = []
        
        IO.popen(cmd, err: [:child, :out]) do |io|
          io.each_line do |line|
            output << line
            next if line.strip.empty?
            
            # Show progress
            if line.include?('Uploading') || line.include?('Processing') || 
               line.include?('Verifying')
              print '.'
            elsif line.include?('ERROR')
              puts ""
              puts line
            elsif line.include?('SUCCESS')
              puts ""
              puts line
            end
          end
        end
        
        puts ""
        
        if $?.success?
          { success: true }
        else
          error_msg = extract_error_from_output(output.join("\n"))
          { success: false, error: error_msg }
        end
      end

      def altool_available?
        # Check if altool is available
        system('xcrun --find altool > /dev/null 2>&1')
      end

      def extract_error_from_output(output)
        # Try to extract meaningful error from altool output
        error_lines = output.lines.select do |l|
          l.include?('ERROR') || l.include?('error') || l.include?('Invalid')
        end
        
        if error_lines.any?
          # Clean up and join error messages
          cleaned_errors = error_lines.map(&:strip)
                    .reject { |l| l.empty? || l.start_with?('code :') || l.start_with?('iris-code') }
                    .join("\n")
          
          # Add helpful context for common errors
          if output.include?('Cannot determine the Apple ID from Bundle ID')
            cleaned_errors += "\n\n💡 This usually means:\n"
            cleaned_errors += "   • Your bundle ID doesn't have an App created in App Store Connect\n"
            cleaned_errors += "   • Or your Xcode project's bundle ID doesn't match the App's bundle ID\n"
            cleaned_errors += "\n   Fix:\n"
            cleaned_errors += "   1. Check your app in App Store Connect → App Information\n"
            cleaned_errors += "   2. Note the Bundle ID shown there\n"
            cleaned_errors += "   3. Either:\n"
            cleaned_errors += "      a) Update your Xcode project to use that bundle ID\n"
            cleaned_errors += "      b) Or run: mysigner ship testflight --bundle-id <correct-bundle-id>\n"
          elsif output.include?('Missing required icon file')
            cleaned_errors += "\n\n💡 Your app is missing required icon assets.\n"
            cleaned_errors += "   Fix:\n"
            cleaned_errors += "   1. Open your Xcode project\n"
            cleaned_errors += "   2. Go to Assets.xcassets → AppIcon\n"
            cleaned_errors += "   3. Add icon images for all required sizes\n"
            cleaned_errors += "   4. Or use a tool like https://appicon.co to generate all sizes\n"
          end
          
          cleaned_errors
        else
          "Unknown error"
        end
      end

      def say_uploading
        puts "☁️  Uploading to TestFlight..."
        puts ""
        puts "IPA:        #{File.basename(@ipa_path)}"
        puts "Size:       #{format_bytes(File.size(@ipa_path))}"
        
        # Show which tool will be used
        if altool_available?
          puts "Tool:       xcrun altool"
        elsif @transporter_path
          puts "Tool:       iTMSTransporter (future-proof)"
        else
          puts "Tool:       Auto-detect"
        end
        puts ""
      end

      def say_success
        puts ""
        puts "=" * 80
        puts "✓ Upload succeeded!"
        puts "=" * 80
        puts ""
        puts "🎉 Your build is now processing in App Store Connect"
        puts ""
      end

      def say_waiting_for_processing
        puts "⏳ Waiting for App Store Connect to process the build..."
        puts "This may take 5-15 minutes..."
        puts ""
      end

      def format_bytes(bytes)
        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)} KB"
        else
          "#{(bytes / (1024.0 * 1024)).round(1)} MB"
        end
      end
    end
  end
end

