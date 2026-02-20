# frozen_string_literal: true

module Gemba
  module Achievements
    # No-op backend used when RetroAchievements is disabled.
    # All methods are inherited no-ops from Backend.
    class NullBackend
      include Backend
    end
  end
end
