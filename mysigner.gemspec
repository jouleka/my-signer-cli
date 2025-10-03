
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "mysigner/version"

Gem::Specification.new do |spec|
  spec.name          = "mysigner"
  spec.version       = Mysigner::VERSION
  spec.authors       = ["Jurgen Leka"]
  spec.email         = ["lekacoding@gmail.com"]

  spec.summary       = %q{CLI tool for iOS code signing automation via My Signer API}
  spec.description   = %q{Command-line interface for managing iOS certificates, devices, and provisioning profiles. Eliminates provisioning profile hell with simple commands like 'mysigner device add' and 'mysigner profile download'.}
  spec.homepage      = "https://github.com/jurgenleka/my-signer-cli"
  spec.license       = "Apache-2.0"

  spec.required_ruby_version = ">= 3.2.0"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata["allowed_push_host"] = "https://rubygems.org"

    spec.metadata["homepage_uri"] = spec.homepage
    spec.metadata["source_code_uri"] = "https://github.com/jurgenleka/my-signer-cli"
    spec.metadata["changelog_uri"] = "https://github.com/jurgenleka/my-signer-cli/blob/main/CHANGELOG.md"
  else
    raise "RubyGems 2.0 or newer is required to protect against " \
      "public gem pushes."
  end

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_runtime_dependency "thor", "~> 1.4"
  spec.add_runtime_dependency "faraday", "~> 2.14"
  spec.add_runtime_dependency "faraday-retry", "~> 2.2"
  spec.add_runtime_dependency "reline", "~> 0.5"
  spec.add_runtime_dependency "base64", "~> 0.2"
  spec.add_runtime_dependency "xcodeproj", "~> 1.27"

  # Development dependencies
  spec.add_development_dependency "bundler", "~> 2.5"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.24"
end
