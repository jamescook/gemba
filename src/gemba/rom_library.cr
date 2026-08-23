require "json"
require "./paths"

module Gemba
  # A catalog of ROMs the user has opened before, persisted as JSON at
  # Paths.config_dir/rom_library.json - the SAME file ruby gemba's own
  # RomLibrary reads and writes, not a separate Crystal-only file. Must
  # write ruby's on-disk shape (a top-level {"roms": [...]} object, not
  # a bare array) and keep the WHOLE parsed JSON::Any tree, since ruby's
  # entries carry fields this port doesn't populate (platform, md5,
  # ...) that a narrower struct would silently drop on the next write.
  #
  # rom_id/game_code fill in asynchronously: EmulationWorker loads Core
  # on its own thread, so neither is available the moment a ROM is
  # opened - #update_identity patches them in once the worker reports
  # back.
  #
  # Upserts by path rather than by rom_id, since rom_id isn't available
  # at #remember time either - the same ROM opened via two different
  # paths gets two entries here.
  class RomLibrary
    # A read-only view of one catalog entry, for the picker UI - only
    # the fields it actually displays or that GameIndex/BoxartFetcher/
    # RomInfo need to key off of. The full JSON (platform, md5,
    # added_at, ...) lives in the raw tree; see the class comment on why
    # this class doesn't model ALL of it as typed fields. rom_id/
    # game_code are "" until #update_identity has run at least once for
    # this entry (see its own comment).
    record Entry, title : String, path : String, last_played : String, rom_id : String, game_code : String

    FILENAME = "rom_library.json"

    def self.path : String
      File.join(Paths.config_dir, FILENAME)
    end

    @data : JSON::Any

    def initialize(@path : String = self.class.path)
      @data = File.exists?(@path) ? JSON.parse(File.read(@path)) : self.class.empty_tree
    end

    def self.empty_tree : JSON::Any
      JSON.parse(%({"roms": []}))
    end

    # Most-recently-played first.
    def all : Array(Entry)
      roms.map do |rom|
        Entry.new(str(rom, "title") || "???", str(rom, "path") || "", str(rom, "last_played") || "",
          str(rom, "rom_id") || "", str(rom, "game_code") || "")
      end.sort_by!(&.last_played).reverse!
    end

    # Upserts by path (see the class comment on why not rom_id). An
    # existing entry keeps every OTHER field it already had (rom_id,
    # game_code, md5, added_at, whatever ruby wrote) - only title and
    # last_played are ever replaced.
    def remember(title : String, path : String, played_at : String) : Nil
      existing = roms.find { |rom| str(rom, "path") == path }

      if existing
        hash = existing.as_h
        hash["title"] = JSON::Any.new(title)
        hash["last_played"] = JSON::Any.new(played_at)
      else
        roms << JSON::Any.new({
          "path"        => JSON::Any.new(path),
          "title"       => JSON::Any.new(title),
          "added_at"    => JSON::Any.new(played_at),
          "last_played" => JSON::Any.new(played_at),
        } of String => JSON::Any)
      end

      save!
    end

    # Patches rom_id/game_code onto the entry at path, once EmulationWorker
    # reports them back.
    def update_identity(path : String, game_code : String, checksum : UInt32) : Nil
      existing = roms.find { |rom| str(rom, "path") == path }
      return unless existing

      hash = existing.as_h
      hash["game_code"] = JSON::Any.new(game_code)
      hash["rom_id"] = JSON::Any.new(self.class.rom_id(game_code, checksum))
      save!
    end

    # Removes the entry at path (see the class comment on why path, not
    # ruby's own rom_id, is this class's key) - a no-op if there is none.
    def remove(path : String) : Nil
      roms.reject! { |rom| str(rom, "path") == path }
      save!
    end

    # Canonical stable ROM identifier - game_code plus its CRC32 checksum,
    # sanitized for filesystem use. Same shape ruby's Config.rom_id
    # builds and SaveStateManager.state_dir_for's own directory name
    # component uses - one builder, so a game_code with characters that
    # need sanitizing can't drift between the two call sites.
    def self.rom_id(game_code : String, checksum : UInt32) : String
      code = game_code.gsub(/[^a-zA-Z0-9_.\-]/, "_")
      crc = checksum.to_s(16).rjust(8, '0').upcase
      "#{code}-#{crc}"
    end

    private def roms : Array(JSON::Any)
      h = @data.as_h
      h["roms"] = JSON::Any.new([] of JSON::Any) unless h["roms"]?
      h["roms"].as_a
    end

    private def str(rom : JSON::Any, key : String) : String?
      rom.as_h[key]?.try(&.as_s?)
    end

    private def save!
      dir = File.dirname(@path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write(@path, @data.to_json)
    end
  end
end
