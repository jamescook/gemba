# frozen_string_literal: true

module Gemba
  class BoxartFetcher
    # No-op backend that never resolves URLs. Used in tests and offline mode.
    class NullBackend
      def url_for(_game_code)
        nil
      end
    end
  end
end
