require "../boxart_fetcher"

module Gemba
  class BoxartFetcher
    class NullBackend < Backend
      def url_for(game_code : String) : String?
        nil
      end
    end
  end
end
