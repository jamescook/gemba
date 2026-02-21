# frozen_string_literal: true

module Gemba
  module Achievements
    # Build the appropriate backend based on config.
    # Returns NullBackend if RA is disabled.
    # Requires app: (Teek app) for RetroAchievements::Backend's BackgroundWork HTTP calls.
    #
    # @param config [Config]
    # @param app    [Teek::App, nil]
    # @return [Backend]
    def self.backend_for(config, app: nil)
      return NullBackend.new unless config.ra_enabled?
      return NullBackend.new unless app

      RetroAchievements::Backend.new(app: app)
    end
  end
end
