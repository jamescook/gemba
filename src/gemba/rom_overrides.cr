require "json"
require "./paths"

module Gemba
  # Persists per-ROM user overrides to Paths.config_dir/rom_overrides.json
  # - the SAME file ruby gemba already writes, not a separate Crystal-only
  # file, same reasoning as Config/RomLibrary (see their own class
  # comments). Keyed by rom_id.
  #
  # Custom images are copied into Paths.boxart_dir/{rom_id}/custom.{ext}
  # so they stay accessible even if the original file is moved or
  # deleted.
  #
  # Keeps the whole parsed JSON::Any tree rather than a narrow typed
  # struct, same reasoning as Config/RomLibrary - a future key this port
  # doesn't know about yet shouldn't get silently dropped on the next
  # write.
  #
  # Every method here does blocking File I/O and has no App reference of
  # its own to route through #off_thread, same as Config/RomLibrary - a
  # caller with a live App is responsible for wrapping calls in
  # App#off_thread, same as MainWindow already does for those two.
  class RomOverrides
    FILENAME = "rom_overrides.json"

    def self.path : String
      File.join(Paths.config_dir, FILENAME)
    end

    @data : JSON::Any

    # boxart_dir is injectable (defaulting to the real Paths.boxart_dir)
    # for the same reason path is - a test must never let a copied
    # override image land in a real user's actual boxart cache.
    def initialize(@path : String = self.class.path, @boxart_dir : String = Paths.boxart_dir)
      @data = File.exists?(@path) ? JSON.parse(File.read(@path)) : JSON::Any.new({} of String => JSON::Any)
    end

    # @return absolute path to the custom boxart for rom_id, or nil
    def custom_boxart(rom_id : String) : String?
      @data.as_h[rom_id]?.try(&.as_h["custom_boxart"]?).try(&.as_s?)
    end

    # Copies src_path into @boxart_dir and records the dest path -
    # preserves any OTHER keys already stored for rom_id (see the class
    # comment), only ever replacing custom_boxart itself.
    # @return the destination path
    def set_custom_boxart(rom_id : String, src_path : String) : String
      ext = File.extname(src_path)
      dest = File.join(@boxart_dir, rom_id, "custom#{ext}")
      Dir.mkdir_p(File.dirname(dest))
      File.copy(src_path, dest)

      hash = @data.as_h
      hash[rom_id] = JSON::Any.new({} of String => JSON::Any) unless hash[rom_id]?
      hash[rom_id].as_h["custom_boxart"] = JSON::Any.new(dest)
      save!
      dest
    end

    private def save! : Nil
      dir = File.dirname(@path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write(@path, @data.to_json)
    end
  end
end
