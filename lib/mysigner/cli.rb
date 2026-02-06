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

module Mysigner
  class CLI < Thor
    class_option :verbose, type: :boolean, aliases: '-v', desc: 'Verbose output'

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