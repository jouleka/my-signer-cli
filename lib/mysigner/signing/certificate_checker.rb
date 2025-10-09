require 'open3'
require 'time'

module Mysigner
  module Signing
    class CertificateChecker
      class CheckError < StandardError; end

      # Certificate status based on expiry
      STATUS_VALID = :valid
      STATUS_EXPIRING_SOON = :expiring_soon
      STATUS_EXPIRED = :expired

      def initialize
        @certificates = []
      end

      # Check all code signing certificates installed on the system
      def check!
        @certificates = find_certificates
        @certificates
      end

      # Get certificates grouped by status
      def by_status
        {
          valid: @certificates.select { |c| c[:status] == STATUS_VALID },
          expiring_soon: @certificates.select { |c| c[:status] == STATUS_EXPIRING_SOON },
          expired: @certificates.select { |c| c[:status] == STATUS_EXPIRED }
        }
      end

      # Check if there are any issues
      def has_issues?
        @certificates.any? { |c| c[:status] != STATUS_VALID }
      end

      private

      def find_certificates
        # Use security command to find code signing identities
        cmd = 'security find-identity -v -p codesigning'
        stdout, stderr, status = Open3.capture3(cmd)

        unless status.success?
          raise CheckError, "Failed to query certificates: #{stderr}"
        end

        certificates = []
        
        # Parse output: "  1) HASH \"Certificate Name\""
        stdout.each_line do |line|
          next unless line =~ /\d+\)\s+([A-F0-9]+)\s+"([^"]+)"/
          
          hash = $1
          name = $2
          
          # Get certificate details
          details = get_certificate_details(name)
          next unless details
          
          certificates << {
            hash: hash,
            name: name,
            team_id: extract_team_id(name),
            type: determine_cert_type(name),
            expires_at: details[:expires_at],
            days_until_expiry: details[:days_until_expiry],
            status: determine_status(details[:days_until_expiry])
          }
        end

        certificates
      end

      def get_certificate_details(name)
        # Get certificate in PEM format by name
        cmd = "security find-certificate -c \"#{name}\" -p"
        stdout, stderr, status = Open3.capture3(cmd)

        # If not found, return nil
        if !status.success? || stdout.empty?
          return nil
        end

        # Save to temp file and use openssl to read expiry
        require 'tempfile'
        temp = Tempfile.new(['cert', '.pem'])
        begin
          temp.write(stdout)
          temp.close

          # Get expiry date using openssl
          cmd = "openssl x509 -in #{temp.path} -noout -enddate"
          out, err, stat = Open3.capture3(cmd)

          if stat.success? && out =~ /notAfter=(.+)/
            expiry_str = $1.strip
            expires_at = Time.parse(expiry_str)
            days_until_expiry = ((expires_at - Time.now) / 86400).to_i

            return {
              expires_at: expires_at,
              days_until_expiry: days_until_expiry
            }
          end
        ensure
          temp.unlink
        end

        nil
      end

      def extract_team_id(name)
        # Team ID is usually in parentheses at the end
        if name =~ /\(([A-Z0-9]{10})\)$/
          $1
        else
          nil
        end
      end

      def determine_cert_type(name)
        case name
        when /Distribution/i
          'Distribution'
        when /Development/i
          'Development'
        when /Developer ID/i
          'Developer ID'
        else
          'Unknown'
        end
      end

      def determine_status(days_until_expiry)
        if days_until_expiry < 0
          STATUS_EXPIRED
        elsif days_until_expiry < 30
          STATUS_EXPIRING_SOON
        else
          STATUS_VALID
        end
      end
    end
  end
end

