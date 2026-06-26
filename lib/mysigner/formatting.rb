# frozen_string_literal: true

module Mysigner
  # Shared human-readable formatting helpers — single source of truth so the
  # CLI concern and the upload classes don't each carry their own copy.
  #
  # NOTE: format_duration is deliberately NOT here. The CLI concern's
  # format_duration ("2m 5s" units) and AppStoreAutomation's ("02:05" clock)
  # are different formats for different displays, not duplicates.
  module Formatting
    module_function

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
