# frozen_string_literal: true

require 'open3'
require 'tmpdir'

module Mysigner
  module Upload
    # IPA metadata reader. The legacy iTMSTransporter/altool *instance*
    # uploader that used to live here was removed once the iOS upload path
    # moved to AscRestUploader/AscSubmitter — only this class method is still
    # used (by build_commands.rb to read an IPA's build info before upload).
    class Uploader
      # Parses CFBundleVersion + CFBundleShortVersionString + CFBundleIdentifier
      # from an .ipa (reads Info.plist from the Payload/*.app/ inside the zip).
      def self.extract_ipa_info(ipa_path)
        result = { cf_bundle_version: nil, cf_bundle_short_version_string: nil, bundle_id: nil }
        Dir.mktmpdir('mysigner-ipa-inspect-') do |tmp|
          plist_path = File.join(tmp, 'Info.plist')
          zip_out, status = Open3.capture2e('unzip', '-p', ipa_path, 'Payload/*.app/Info.plist')
          return result unless status.success? && !zip_out.empty?

          File.binwrite(plist_path, zip_out)
          xml_out, xml_status = Open3.capture2e('plutil', '-convert', 'xml1', '-o', '-', plist_path)
          return result unless xml_status.success?

          result[:cf_bundle_version] = xml_out[%r{<key>CFBundleVersion</key>\s*<string>([^<]+)</string>}, 1]
          result[:cf_bundle_short_version_string] =
            xml_out[%r{<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>}, 1]
          result[:bundle_id] = xml_out[%r{<key>CFBundleIdentifier</key>\s*<string>([^<]+)</string>}, 1]
        end
        result
      rescue StandardError
        { cf_bundle_version: nil, cf_bundle_short_version_string: nil, bundle_id: nil }
      end
    end
  end
end
