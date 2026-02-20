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

    MD5_FILES = {
      "AGB" => "gba_md5.json",
      "CGB" => "gbc_md5.json",
      "DMG" => "gb_md5.json",
    }.freeze

    # Maps RomLibrary platform short names → GameIndex prefixes
    PLATFORM_PREFIX = { "gba" => "AGB", "gbc" => "CGB", "gb" => "DMG" }.freeze

    class << self
      # Look up a canonical game name by serial code.
      # @param game_code [String] e.g. "AGB-AXVE", "CGB-BYTE", "DMG-XXXX"
      # @return [String, nil] canonical name or nil if not found
      def lookup(game_code)
        return nil unless game_code && !game_code.empty?

        platform = game_code.split("-", 2).first
        index = index_for(platform, PLATFORM_FILES)
        return nil unless index

        index[game_code]
      end

      # Look up a canonical game name by MD5 hex digest.
      # @param md5      [String] hex MD5 of ROM content (any case)
      # @param platform [String] short name from RomLibrary — "gba", "gbc", or "gb"
      # @return [String, nil]
      def lookup_by_md5(md5, platform)
        return nil unless md5 && !md5.empty?

        prefix = PLATFORM_PREFIX[platform.to_s.downcase]
        return nil unless prefix

        idx = index_for(prefix, MD5_FILES)
        idx&.[](md5.downcase)
      end

      # Force-reload all indexes (useful after re-baking).
      def reset!
        @indexes = {}
      end

      private

      def index_for(platform, files)
        @indexes ||= {}
        key = "#{platform}:#{files.object_id}"
        return @indexes[key] if @indexes.key?(key)

        file = files[platform]
        return(@indexes[key] = nil) unless file

        path = File.join(DATA_DIR, file)
        return(@indexes[key] = nil) unless File.exist?(path)

        @indexes[key] = JSON.parse(File.read(path))
      end
    end
  end
end
