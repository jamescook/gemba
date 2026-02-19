# frozen_string_literal: true

require "uri"
require_relative "../game_index"

module Gemba
  class BoxartFetcher
    # Resolves box art URLs from the LibRetro thumbnails CDN.
    #
    # URL pattern:
    #   https://thumbnails.libretro.com/{system}/Named_Boxarts/{encoded_name}.png
    #
    # Requires game_code → canonical name mapping via GameIndex.
    class LibretroBackend
      SYSTEMS = {
        "AGB" => "Nintendo - Game Boy Advance",
        "CGB" => "Nintendo - Game Boy Color",
        "DMG" => "Nintendo - Game Boy",
      }.freeze

      BASE_URL = "https://thumbnails.libretro.com"

      # @param game_code [String] e.g. "AGB-BPEE"
      # @return [String, nil] full URL to the box art PNG, or nil if unknown
      def url_for(game_code)
        platform = game_code.split("-", 2).first
        system = SYSTEMS[platform]
        return nil unless system

        name = GameIndex.lookup(game_code)
        return nil unless name

        encoded_system = URI.encode_www_form_component(system).gsub("+", "%20")
        encoded_name = URI.encode_www_form_component(name).gsub("+", "%20")

        "#{BASE_URL}/#{encoded_system}/Named_Boxarts/#{encoded_name}.png"
      end
    end
  end
end
