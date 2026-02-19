# frozen_string_literal: true

require 'json'
require 'fileutils'

module Gemba
  # Persists per-ROM user overrides to config_dir/rom_overrides.json.
  #
  # Keyed by rom_id (game_code + CRC32 checksum) — the most stable
  # identifier for a ROM across renames or moves.
  #
  # Currently tracks:
  #   custom_boxart — absolute path to a user-chosen cover image
  #
  # Custom images are copied into config_dir/boxart/{rom_id}/custom.{ext}
  # so they remain accessible even if the original file is moved or deleted.
  class RomOverrides
    def initialize(path = Config.rom_overrides_path)
      @path = path
      @data = File.exist?(path) ? JSON.parse(File.read(path)) : {}
    end

    # @return [String, nil] absolute path to the custom boxart, or nil
    def custom_boxart(rom_id)
      @data.dig(rom_id.to_s, 'custom_boxart')
    end

    # Copies src_path into the gemba boxart cache and records the dest path.
    # @return [String] the destination path
    def set_custom_boxart(rom_id, src_path)
      ext  = File.extname(src_path)
      dest = File.join(Config.boxart_dir, rom_id.to_s, "custom#{ext}")
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(src_path, dest)
      (@data[rom_id.to_s] ||= {})['custom_boxart'] = dest
      save
      dest
    end

    private

    def save
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(@data))
    end
  end
end
