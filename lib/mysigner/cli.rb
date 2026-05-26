# frozen_string_literal: true

require 'thor'
require 'json'
require 'time'

# Load all CLI components
require_relative 'cli/concerns/helpers'
require_relative 'cli/concerns/api_helpers'
require_relative 'cli/concerns/error_handlers'
require_relative 'cli/concerns/actionable_suggestions'
require_relative 'cli/auth_commands'
require_relative 'cli/diagnostic_commands'
require_relative 'cli/build_commands'
require_relative 'cli/resource_commands'
require_relative 'cli/validate_commands'
require_relative 'cleanup/private_keys_purger'

# Phase 0: one-time cleanup of legacy plaintext .p8 files that older CLI
# versions wrote to ~/.private_keys/ and ~/.appstoreconnect/private_keys/.
# Idempotent — a marker file at ~/.mysigner/.private_keys_purged prevents
# re-running.
Mysigner::Cleanup::PrivateKeysPurger.new.call

module Mysigner
  class CLI < Thor
    class_option :verbose, type: :boolean, aliases: '-v', desc: 'Verbose output'
    class_option :local_only, type: :boolean, default: false,
                              desc: 'Do not send credentials to the server (local-only mode)'

    def self.exit_on_failure?
      true
    end

    # Include all concerns (helper methods)
    include Concerns::Helpers
    include Concerns::ApiHelpers
    include Concerns::ErrorHandlers
    include Concerns::ActionableSuggestions

    # Include all command modules
    include AuthCommands
    include DiagnosticCommands
    include BuildCommands
    include ResourceCommands
    include ValidateCommands

    # Command aliases for power users
    map 's' => :ship
    map 'b' => :build
    map 'e' => :export
    map 'u' => :upload
    map 'st' => :status
    map 'd' => :doctor
  end
end
