# frozen_string_literal: true

require_relative "platform/gba"
require_relative "platform/gb"
require_relative "platform/gbc"

module Gemba
  module Platform
    # Build a Platform from a loaded Core.
    # @param core [Gemba::Core] initialized core with ROM loaded
    # @return [GBA, GB, GBC]
    def self.for(core)
      case core.platform
      when "GBA" then GBA.new
      when "GBC" then GBC.new
      else            GB.new
      end
    end

    # Default platform before any ROM is loaded (most common case).
    def self.default = GBA.new
  end
end
