require "uri"
require "../boxart_fetcher"
require "../game_index"

module Gemba
  class BoxartFetcher
    # URL pattern:
    #   https://thumbnails.libretro.com/{system}/Named_Boxarts/{encoded_name}.png
    #
    # Requires GameIndex to already know the game_code -> canonical name
    # mapping (see GameIndex.preload!).
    class LibretroBackend < Backend
      SYSTEMS = {
        "AGB" => "Nintendo - Game Boy Advance",
        "CGB" => "Nintendo - Game Boy Color",
        "DMG" => "Nintendo - Game Boy",
      }

      BASE_URL = "https://thumbnails.libretro.com"

      # @param game_code [String] e.g. "AGB-BPEE"
      # @return full URL to the box art PNG, or nil if unknown
      def url_for(game_code : String) : String?
        platform = game_code.split('-', 2).first
        system = SYSTEMS[platform]?
        return unless system

        name = GameIndex.lookup(game_code)
        return unless name

        "#{BASE_URL}/#{URI.encode_path_segment(system)}/Named_Boxarts/#{URI.encode_path_segment(name)}.png"
      end
    end
  end
end
