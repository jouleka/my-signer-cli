# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'tmpdir'

module Mysigner
  module Export
    class Exporter
      class ExportError < Mysigner::Error; end

      def initialize(archive_path, output_dir: nil)
        @archive_path = File.expand_path(archive_path)
        @output_dir = output_dir || File.dirname(@archive_path)

        validate_archive!
      end

      def export!(method: :appstore, team_id: nil, signing_style: 'automatic')
        say_exporting(method)

        # Generate export options plist
        options_plist = generate_export_options(method, team_id, signing_style)

        begin
          # Run xcodebuild -exportArchive
          success = execute_export(options_plist)

          raise ExportError, 'Export failed. Check output above for errors.' unless success

          # Find the generated .ipa file
          ipa_path = find_ipa_file

          raise ExportError, "Export reported success but .ipa file not found in: #{@output_dir}" unless ipa_path

          ipa_path
        ensure
          # Clean up temp plist
          File.delete(options_plist) if options_plist && File.exist?(options_plist)
        end
      end

      private

      def validate_archive!
        raise ExportError, "Archive not found: #{@archive_path}" unless File.exist?(@archive_path)

        return if File.directory?(@archive_path) && @archive_path.end_with?('.xcarchive')

        raise ExportError, "Invalid archive: #{@archive_path} (must be a .xcarchive directory)"
      end

      def generate_export_options(method, team_id, signing_style)
        require 'plist'

        options = {
          'method' => export_method_string(method),
          'uploadBitcode' => false,
          'uploadSymbols' => false,
          'compileBitcode' => false
        }

        # Add team ID if provided
        options['teamID'] = team_id if team_id

        # Signing style
        if signing_style.to_s.downcase == 'manual'
          options['signingStyle'] = 'manual'
          # NOTE: For manual signing, we'd need to specify provisioningProfiles
          # But since the archive was already signed during build, we can often omit this
        else
          options['signingStyle'] = 'automatic'
          options['signingCertificate'] = 'Apple Distribution'
        end

        # Create temp plist file
        plist_path = File.join(Dir.tmpdir, "exportOptions-#{Time.now.to_i}.plist")
        File.write(plist_path, options.to_plist)

        plist_path
      end

      def export_method_string(method)
        case method.to_sym
        when :appstore, :app_store
          'app-store'
        when :adhoc, :ad_hoc
          'ad-hoc'
        when :enterprise
          'enterprise'
        when :development
          'development'
        else
          'app-store'
        end
      end

      def execute_export(options_plist)
        FileUtils.mkdir_p(@output_dir)
        puts ''

        cmd = [
          'xcodebuild',
          '-exportArchive',
          '-archivePath', @archive_path,
          '-exportPath', @output_dir,
          '-exportOptionsPlist', options_plist,
          '-allowProvisioningUpdates' # Allow Xcode to update profiles if needed
        ].join(' ')

        # Run command and capture output. xcodebuild output can contain
        # non-ASCII bytes (smart quotes in Apple error messages, emoji in
        # file paths) — force UTF-8 + scrub so `.strip` / `.include?` don't
        # raise Encoding::CompatibilityError under the default US-ASCII
        # locale (e.g. on CI runners without LANG set).
        IO.popen(cmd, err: %i[child out]) do |io|
          io.each_line do |line|
            line = line.force_encoding('UTF-8').scrub
            next if line.strip.empty?

            # Show errors and warnings
            if line.include?('error:') || line.include?('warning:')
              puts line
            # Show progress markers
            elsif line.include?('Exporting') || line.include?('Processing') ||
                  line.include?('Validating')
              print '.'
            end
          end
        end

        puts '' # New line after dots

        $CHILD_STATUS.success?
      end

      def find_ipa_file
        # Look for .ipa files in output directory
        ipa_files = Dir.glob(File.join(@output_dir, '*.ipa'))

        # Return the most recently created one
        ipa_files.max_by { |f| File.mtime(f) }
      end

      def say_exporting(method)
        puts "📦 Exporting archive for #{method}..."
        puts ''
      end
    end
  end
end
