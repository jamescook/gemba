require "json"

module Gemba
  #   GameIndex.lookup("AGB-AXVE")                    # => "Pokemon - Ruby Version (USA)"
  #   GameIndex.lookup_by_md5("deadbeef...", "gba")   # => same, by ROM content hash
  #
  # #preload! loads every platform's data up front rather than lazily
  # on first lookup: the first lookup could otherwise happen from UI
  # code well after Tk's mainloop is already running, which would be a
  # File.read on Tk's own thread with no App to route it through
  # #off_thread.
  module GameIndex
    DATA_DIR = File.join(__DIR__, "data")

    # game_code prefix -> the serial-keyed JSON file for that platform.
    PLATFORM_FILES = {
      "AGB" => "gba_games.json",
      "CGB" => "gbc_games.json",
      "DMG" => "gb_games.json",
    }

    # game_code prefix -> the md5-keyed JSON file for that platform.
    MD5_FILES = {
      "AGB" => "gba_md5.json",
      "CGB" => "gbc_md5.json",
      "DMG" => "gb_md5.json",
    }

    # RomLibrary's own short platform name -> game_code prefix.
    PLATFORM_PREFIX = {"gba" => "AGB", "gbc" => "CGB", "gb" => "DMG"}

    @@name_indexes = {} of String => Hash(String, String)
    @@md5_indexes = {} of String => Hash(String, String)

    # @param game_code [String?] e.g. "AGB-AXVE"
    # @return canonical name, or nil if unknown/blank/not yet preloaded
    def self.lookup(game_code : String?) : String?
      return if game_code.nil? || game_code.empty?

      platform = game_code.split('-', 2).first
      @@name_indexes[platform]?.try(&.[game_code]?)
    end

    # @param md5 [String?] hex MD5 of ROM content, any case
    # @param platform [String] RomLibrary's own short name - "gba", "gbc", or "gb"
    def self.lookup_by_md5(md5 : String?, platform : String) : String?
      return if md5.nil? || md5.empty?

      prefix = PLATFORM_PREFIX[platform.downcase]?
      return unless prefix

      @@md5_indexes[prefix]?.try(&.[md5.downcase]?)
    end

    # Loads every platform's data up front. Idempotent - an index
    # that's already loaded (including one deliberately left empty
    # because its data file doesn't exist) is never reloaded.
    def self.preload! : Nil
      PLATFORM_FILES.each_key { |platform| load_index(@@name_indexes, platform, PLATFORM_FILES) }
      MD5_FILES.each_key { |platform| load_index(@@md5_indexes, platform, MD5_FILES) }
    end

    # Force-reload every index - test-only in practice, so one spec's
    # data doesn't leak into another's expectations. Mirrors ruby's own
    # reset!.
    def self.reset! : Nil
      @@name_indexes.clear
      @@md5_indexes.clear
    end

    private def self.load_index(into : Hash(String, Hash(String, String)), platform : String,
                                files : Hash(String, String)) : Nil
      return if into.has_key?(platform)

      path = File.join(DATA_DIR, files[platform])
      into[platform] = File.exists?(path) ? Hash(String, String).from_json(File.read(path)) : {} of String => String
    end
  end
end
