module Mysigner
  class CLI < Thor
    module DiagnosticCommands
      def self.included(base)
        base.class_eval do
          desc "doctor", "Diagnose common issues and check your environment"
          def doctor
            say "🩺 My Signer Health Check", :cyan
            say "=" * 80, :cyan
            say ""
            
            issues = []
            warnings = []
            
            # Check 1: Xcode
            say "Checking Xcode...", :yellow
            if system('which xcodebuild > /dev/null 2>&1')
              xcode_version = `xcodebuild -version`.lines.first.strip rescue "Unknown"
              say "  ✓ Xcode installed: #{xcode_version}", :green
            else
              say "  ✗ Xcode not found", :red
              issues << "Xcode is not installed or not in PATH"
            end
            say ""
            
            # Check 2: Command Line Tools
            say "Checking Command Line Tools...", :yellow
            if system('xcode-select -p > /dev/null 2>&1')
              say "  ✓ Command Line Tools installed", :green
            else
              say "  ✗ Command Line Tools not found", :red
              issues << "Install with: xcode-select --install"
            end
            say ""
            
            # Check 3: xcrun altool
            say "Checking upload tools...", :yellow
            if system('xcrun --find altool > /dev/null 2>&1')
              say "  ✓ xcrun altool available", :green
            else
              say "  ⚠️  xcrun altool not found", :yellow
              warnings << "altool not available (upload may fail)"
            end
            
            # Check for iTMSTransporter
            transporter_paths = [
              '/Applications/Xcode.app/Contents/Developer/usr/bin/iTMSTransporter',
              '/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter'
            ]
            transporter_found = transporter_paths.any? { |path| File.exist?(path) }
            
            if transporter_found
              say "  ✓ iTMSTransporter available (fallback)", :green
            else
              say "  ⚠️  iTMSTransporter not found (optional)", :yellow
            end
            say ""
            
            # Check 4: My Signer Configuration
            say "Checking My Signer configuration...", :yellow
            config = Config.new
            if config.exists?
              config.load
              say "  ✓ Logged in", :green
              
              begin
                client = Client.new(api_url: config.api_url, api_token: config.api_token)
                response = client.test_connection
                say "  ✓ API connection working", :green
              rescue
                say "  ✗ Cannot connect to API", :red
                issues << "API connection failed - check your network or API URL"
              end
            else
              say "  ✗ Not logged in", :red
              issues << "Run 'mysigner login' to authenticate"
            end
            say ""
            
            # Check 5: Disk Space
            say "Checking disk space...", :yellow
            begin
              df_output = `df -h . 2>/dev/null | tail -1`.strip
              if df_output =~ /(\d+)%/
                usage = $1.to_i
                if usage > 90
                  say "  ⚠️  Low disk space: #{usage}% used", :yellow
                  warnings << "Low disk space may cause build failures"
                else
                  say "  ✓ Sufficient disk space: #{usage}% used", :green
                end
              else
                say "  ⚠️  Could not check disk space", :yellow
              end
            rescue
              say "  ⚠️  Could not check disk space", :yellow
            end
            say ""
            
            # Check 6: Project Detection (if in a project directory)
            say "Checking current directory...", :yellow
            begin
              project_info = Build::Detector.detect
              framework = case project_info[:framework]
              when :capacitor then "Capacitor/Ionic"
              when :react_native then "React Native"
              when :flutter then "Flutter"
              else "Native iOS"
              end
              say "  ✓ Found #{framework} project: #{File.basename(project_info[:path])}", :green
            rescue
              say "  ℹ️  No project detected in current directory", :cyan
            end
            say ""
            
            # Final Report
            say "=" * 80, :cyan
            say "Health Report", :bold
            say "=" * 80, :cyan
            say ""
            
            if issues.empty? && warnings.empty?
              say "🎉 All checks passed! You're good to go!", :green
              say ""
              say "Try: mysigner ship testflight", :cyan
            elsif issues.empty?
              say "⚠️  #{warnings.length} warning(s), but you're mostly good!", :yellow
              say ""
              warnings.each do |warning|
                say "  • #{warning}", :yellow
              end
            else
              say "✗ #{issues.length} issue(s) found:", :red
              say ""
              issues.each do |issue|
                say "  • #{issue}", :red
              end
              
              if warnings.any?
                say ""
                say "⚠️  #{warnings.length} warning(s):", :yellow
                warnings.each do |warning|
                  say "  • #{warning}", :yellow
                end
              end
            end
            
            say ""
          end
        end
      end
    end
  end
end
