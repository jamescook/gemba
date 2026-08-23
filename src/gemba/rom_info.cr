require "./rom_library"
require "./game_index"
require "./boxart_fetcher"
require "./rom_overrides"

module Gemba
  # Immutable snapshot of everything known about a single ROM, for the
  # picker UI. Aggregates:
  #   RomLibrary::Entry - title, path, rom_id, game_code
  #   GameIndex          - has_official_entry, and a better title if one exists
  #   BoxartFetcher      - cached_boxart_path (auto-fetched cover art)
  #   RomOverrides       - custom_boxart_path (user-chosen cover art)
  #
  # rom_id/game_code are "" (RomLibrary::Entry's own sentinel for "not
  # backfilled yet" - see RomLibrary#update_identity) rather than nil,
  # so this class never introduces a second representation for "unknown"
  # alongside RomLibrary's existing one.
  #
  # platform is hardcoded "GBA" rather than read from the entry - unlike
  # ruby, RomLibrary::Entry doesn't track a per-ROM platform field yet
  # (this port's mGBA core only plays GBA carts today; a real GB/GBC
  # platform field is future work if that ever changes).
  #
  # .from_rom and #boxart_path both do real File I/O (BoxartFetcher/
  # RomOverrides reads) - callers on the main thread must wrap them in
  # App#off_thread, same convention as every other blocking call in
  # this app.
  record RomInfo,
    rom_id : String,
    title : String,
    platform : String,
    game_code : String,
    path : String,
    has_official_entry : Bool,
    cached_boxart_path : String?,
    custom_boxart_path : String? do
    # Re-checks File.exists? for both rather than trusting the paths as
    # constructed - either could have been deleted since .from_rom ran
    # (e.g. a cleared cache).
    def boxart_path : String?
      custom = custom_boxart_path
      return custom if custom && File.exists?(custom)

      cached = cached_boxart_path
      return cached if cached && File.exists?(cached)

      nil
    end

    def self.from_rom(entry : RomLibrary::Entry, fetcher : BoxartFetcher? = nil,
                      overrides : RomOverrides? = nil) : RomInfo
      game_code = entry.game_code
      official_name = GameIndex.lookup(game_code)

      new(
        rom_id: entry.rom_id,
        title: official_name || entry.title,
        platform: "GBA",
        game_code: game_code,
        path: entry.path,
        has_official_entry: !official_name.nil?,
        cached_boxart_path: (fetcher.cached_path(game_code) if fetcher && !game_code.empty? && fetcher.cached?(game_code)),
        custom_boxart_path: (overrides.custom_boxart(entry.rom_id) if overrides && !entry.rom_id.empty?),
      )
    end
  end
end
