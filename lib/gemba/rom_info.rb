# frozen_string_literal: true


module Gemba
  # Immutable snapshot of everything known about a single ROM.
  #
  # Aggregates data from multiple sources:
  #   - RomLibrary entry  (title, path, game_code, platform, rom_id)
  #   - GameIndex         (has_official_entry — whether libretro knows about it)
  #   - BoxartFetcher     (cached_boxart_path — auto-fetched cover art)
  #   - RomOverrides      (custom_boxart_path — user-chosen cover art)
  #
  # Use RomInfo.from_rom to construct from a raw library entry hash.
  # Use #boxart_path to get the effective cover image (custom beats cache).
  RomInfo = Data.define(
    :rom_id,             # String  — unique ROM identifier (game_code + CRC32)
    :title,              # String  — display name
    :platform,           # String  — uppercased, e.g. "GBA"
    :game_code,          # String? — 4-char code e.g. "AGB-AXVE", or nil
    :path,               # String  — absolute path to the ROM file
    :md5,                # String? — MD5 hex digest of ROM content, or nil (lazy)
    :has_official_entry, # Boolean — GameIndex has an entry for this game_code
    :cached_boxart_path, # String? — auto-fetched cover from libretro CDN, or nil
    :custom_boxart_path  # String? — user-set cover image path, or nil
  ) do
    # Effective cover image path: custom override wins, then fetched cache, then nil.
    def boxart_path
      return custom_boxart_path if custom_boxart_path && File.exist?(custom_boxart_path)
      return cached_boxart_path if cached_boxart_path && File.exist?(cached_boxart_path)
      nil
    end

    # Build a RomInfo from a raw rom_library entry hash.
    #
    # @param rom      [Hash]          entry from RomLibrary#all
    # @param fetcher  [BoxartFetcher, nil]
    # @param overrides [RomOverrides, nil]
    def self.from_rom(rom, fetcher: nil, overrides: nil, game_index: GameIndex)
      game_code = rom['game_code']
      rom_id    = rom['rom_id']

      new(
        rom_id:             rom_id,
        title:              game_index.lookup(game_code) ||
                            game_index.lookup_by_md5(rom['md5'], rom['platform'] || 'gba') ||
                            rom['title'] || rom['rom_id'] || '???',
        platform:           (rom['platform'] || 'gba').upcase,
        game_code:          game_code,
        path:               rom['path'],
        md5:                rom['md5'],
        has_official_entry: game_code ? !game_index.lookup(game_code).nil? : false,
        cached_boxart_path: (fetcher.cached_path(game_code) if fetcher&.cached?(game_code)),
        custom_boxart_path: overrides&.custom_boxart(rom_id),
      )
    end
  end
end
