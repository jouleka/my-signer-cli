# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'mysigner/version'

Gem::Specification.new do |spec|
  spec.name          = 'mysigner'
  spec.version       = Mysigner::VERSION
  spec.authors       = ['Jurgen Leka']
  spec.email         = ['lekacoding@gmail.com']

  spec.summary       = 'CLI tool for iOS and Android code signing automation via My Signer API'
  spec.description   = "Command-line interface for managing iOS certificates, devices, provisioning profiles, and Android keystores. Build, sign, and upload to App Store Connect and Google Play with simple commands like 'mysigner ship testflight' and 'mysigner ship internal --platform android'."
  spec.homepage      = 'https://mysigner.dev'
  spec.license       = 'Apache-2.0'

  spec.required_ruby_version = '>= 3.2.0'

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = 'https://rubygems.org'

    spec.metadata['homepage_uri'] = spec.homepage
    spec.metadata['changelog_uri'] = 'https://mysigner.dev/docs/changelog'
    spec.metadata['documentation_uri'] = 'https://mysigner.dev/docs/commands'
    spec.metadata['rubygems_mfa_required'] = 'true'
  else
    raise 'RubyGems 2.0 or newer is required to protect against ' \
          'public gem pushes.'
  end

  spec.post_install_message = <<~MSG
    \e[36m╔══════════════════════════════════════════════════════════════╗\e[0m
    \e[36m║ \e[1m🚀  Welcome to My Signer CLI\e[0m\e[36m                                      ║\e[0m
    \e[36m╚══════════════════════════════════════════════════════════════╝\e[0m

    \e[32m✓\e[0m  You're ready to automate iOS & Android code signing.

    \e[35mTwo ways to use it:\e[0m
      • \e[1mWith a free My Signer account\e[0m (keys stored & synced for you):
          \e[33mRun\e[0m \e[1m`mysigner onboard`\e[0m
      • \e[1mNo account — your keys stay on this machine\e[0m (nothing sent to a server):
          \e[33mRun\e[0m \e[1m`mysigner --local-only onboard`\e[0m
        \e[33mNot sure? Start with --local-only.\e[0m

    \e[35mAlso handy:\e[0m
      • \e[33mRun\e[0m \e[1m`mysigner doctor`\e[0m   – Check your dev environment (JDK, SDK, Xcode…)
      • \e[33mRun\e[0m \e[1m`mysigner help`\e[0m     – Explore every command

    \e[35miOS (needs a Mac):\e[0m  mysigner ship testflight
    \e[35mAndroid:\e[0m           mysigner ship internal --platform android

    \e[36mDocs:\e[0m https://mysigner.dev/docs/commands
  MSG

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    # Ship only what the installed gem needs. Exclude tests, the dev-only
    # bin/ helpers (console/setup — the real CLI is exe/mysigner), and the
    # internal MANUAL_TEST.md process notes.
    `git ls-files -z`.split("\x0").reject do |f|
      f.match(%r{\A(?:test|spec|features|bin)/}) || f == 'MANUAL_TEST.md'
    end
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'base64', '~> 0.2'
  spec.add_dependency 'faraday', '~> 2.14'
  spec.add_dependency 'faraday-retry', '~> 2.2'
  spec.add_dependency 'plist', '~> 3.7'
  spec.add_dependency 'thor', '~> 1.4'
  spec.add_dependency 'xcodeproj', '~> 1.27'

  # Android/Google Play dependencies
  spec.add_dependency 'google-apis-androidpublisher_v3', '~> 0.54'
  spec.add_dependency 'googleauth', '~> 1.11'

  # Development dependencies
  spec.add_development_dependency 'bundler', '~> 2.5'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rubocop', '~> 1.79'
  spec.add_development_dependency 'webmock', '~> 3.24'
end
