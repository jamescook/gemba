# frozen_string_literal: true

require "json"

module Gemba
  # Lookup table mapping ROM serial codes to canonical game names.
  #
  # Data is pre-baked from No-Intro DAT files via script/bake_game_index.rb
  # and stored as JSON in lib/gemba/data/{platform}_games.json.
  #
  # Loaded lazily on first lookup per platform.
  #
  #   GameIndex.lookup("AGB-AXVE")  # => "Pokemon - Ruby Version (USA)"
  #   GameIndex.lookup("CGB-BYTE")  # => nil (unknown)
  #
  class GameIndex
    DATA_DIR = File.expand_path("data", __dir__)

    PLATFORM_FILES = {
      "AGB" => "gba_games.json",
      "CGB" => "gbc_games.json",
      "DMG" => "gb_games.json",
    }.freeze

    class << self
      # Look up a canonical game name by serial code.
      # @param game_code [String] e.g. "AGB-AXVE", "CGB-BYTE", "DMG-XXXX"
      # @return [String, nil] canonical name or nil if not found
      def lookup(game_code)
        return nil unless game_code && !game_code.empty?

        platform = game_code.split("-", 2).first
        index = index_for(platform)
        return nil unless index

        index[game_code]
      end

      # Force-reload all indexes (useful after re-baking).
      def reset!
        @indexes = {}
      end

      private

      def index_for(platform)
        @indexes ||= {}
        return @indexes[platform] if @indexes.key?(platform)

        file = PLATFORM_FILES[platform]
        return(@indexes[platform] = nil) unless file

        path = File.join(DATA_DIR, file)
        return(@indexes[platform] = nil) unless File.exist?(path)

        @indexes[platform] = JSON.parse(File.read(path))
      end
    end
  end
end
