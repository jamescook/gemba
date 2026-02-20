# frozen_string_literal: true

# Minimal config stand-in for AchievementsWindow tests.
# The window only reads ra_unofficial? from config at build time.
FakeConfig = Struct.new(:ra_unofficial) {
  def ra_unofficial? = ra_unofficial
} unless defined?(FakeConfig)

# Build a plain rom hash suitable for RomLibrary stubbing.
def make_rom_entry(id:, title:, platform: 'gba', game_code: 'AGB-TEST', md5: "#{id}abcd")
  { 'rom_id' => id, 'title' => title, 'platform' => platform,
    'game_code' => game_code, 'path' => "/games/#{id}.gba", 'md5' => md5 }
end unless respond_to?(:make_rom_entry, true)

# Wrap an array of rom hashes in a minimal RomLibrary-compatible struct.
def make_rom_library(*roms)
  Struct.new(:roms) { def all = roms }.new(roms)
end unless respond_to?(:make_rom_library, true)
