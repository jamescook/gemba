# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "gemba/headless"

class TestRomInfo < Minitest::Test
  # Stub that returns nil for every lookup — isolates RomInfo from real DAT data.
  NULL_INDEX = Struct.new(:_) {
    def lookup(_)        = nil
    def lookup_by_md5(*) = nil
  }.new(nil)

  ROM = {
    'rom_id'    => 'AGB_AXVE-DEADBEEF',
    'title'     => 'Pokemon Ruby',
    'platform'  => 'gba',
    'game_code' => 'AGB-AXVE',
    'path'      => '/games/ruby.gba',
  }.freeze

  def test_from_rom_sets_basic_fields
    info = Gemba::RomInfo.from_rom(ROM, game_index: NULL_INDEX)
    assert_equal 'AGB_AXVE-DEADBEEF', info.rom_id
    assert_equal 'Pokemon Ruby',       info.title
    assert_equal 'GBA',                info.platform
    assert_equal 'AGB-AXVE',           info.game_code
    assert_equal '/games/ruby.gba',    info.path
  end

  def test_platform_is_uppercased
    info = Gemba::RomInfo.from_rom(ROM.merge('platform' => 'gbc'), game_index: NULL_INDEX)
    assert_equal 'GBC', info.platform
  end

  def test_title_falls_back_to_rom_id
    rom  = ROM.merge('title' => nil)
    info = Gemba::RomInfo.from_rom(rom, game_index: NULL_INDEX)
    assert_equal 'AGB_AXVE-DEADBEEF', info.title
  end

  def test_title_from_game_index_wins_over_stored_title
    index = Struct.new(:_) {
      def lookup(_)        = 'Index Title'
      def lookup_by_md5(*) = nil
    }.new(nil)
    info = Gemba::RomInfo.from_rom(ROM, game_index: index)
    assert_equal 'Index Title', info.title
  end

  def test_no_fetcher_or_overrides_yields_nil_boxart_fields
    info = Gemba::RomInfo.from_rom(ROM, game_index: NULL_INDEX)
    assert_nil info.cached_boxart_path
    assert_nil info.custom_boxart_path
    assert_nil info.boxart_path
  end

  def test_has_official_entry_true_when_index_returns_title
    index = Struct.new(:_) {
      def lookup(_)        = 'Some Game'
      def lookup_by_md5(*) = nil
    }.new(nil)
    info = Gemba::RomInfo.from_rom(ROM, game_index: index)
    assert info.has_official_entry
  end

  def test_has_official_entry_false_when_index_returns_nil
    info = Gemba::RomInfo.from_rom(ROM, game_index: NULL_INDEX)
    refute info.has_official_entry
  end

  def test_has_official_entry_false_when_no_game_code
    rom  = ROM.merge('game_code' => nil)
    info = Gemba::RomInfo.from_rom(rom, game_index: NULL_INDEX)
    refute info.has_official_entry
  end

  def test_boxart_path_returns_custom_when_file_exists
    Dir.mktmpdir do |dir|
      ENV['GEMBA_CONFIG_DIR'] = dir
      custom    = File.join(dir, "custom.png")
      File.write(custom, "fake")
      overrides = Gemba::RomOverrides.new(File.join(dir, "overrides.json"))
      overrides.set_custom_boxart('AGB_AXVE-DEADBEEF', custom)

      info = Gemba::RomInfo.from_rom(ROM, overrides: overrides, game_index: NULL_INDEX)
      assert_equal File.join(dir, 'boxart', 'AGB_AXVE-DEADBEEF', 'custom.png'), info.boxart_path
    ensure
      ENV.delete('GEMBA_CONFIG_DIR')
    end
  end

  def test_boxart_path_falls_back_to_cache_when_no_custom
    Dir.mktmpdir do |dir|
      ENV['GEMBA_CONFIG_DIR'] = dir
      cache_dir = File.join(dir, "boxart")
      fetcher   = Gemba::BoxartFetcher.new(app: nil, cache_dir: cache_dir,
                                            backend: Gemba::BoxartFetcher::NullBackend.new)
      overrides = Gemba::RomOverrides.new(File.join(dir, "overrides.json"))

      cached = fetcher.cached_path('AGB-AXVE')
      FileUtils.mkdir_p(File.dirname(cached))
      File.write(cached, "fake")

      info = Gemba::RomInfo.from_rom(ROM, fetcher: fetcher, overrides: overrides, game_index: NULL_INDEX)
      assert_equal cached, info.boxart_path
    ensure
      ENV.delete('GEMBA_CONFIG_DIR')
    end
  end

  def test_boxart_path_nil_when_neither_present
    Dir.mktmpdir do |dir|
      ENV['GEMBA_CONFIG_DIR'] = dir
      fetcher   = Gemba::BoxartFetcher.new(app: nil, cache_dir: File.join(dir, "boxart"),
                                            backend: Gemba::BoxartFetcher::NullBackend.new)
      overrides = Gemba::RomOverrides.new(File.join(dir, "overrides.json"))

      info = Gemba::RomInfo.from_rom(ROM, fetcher: fetcher, overrides: overrides, game_index: NULL_INDEX)
      assert_nil info.boxart_path
    ensure
      ENV.delete('GEMBA_CONFIG_DIR')
    end
  end

  def test_custom_beats_cache_in_boxart_path
    Dir.mktmpdir do |dir|
      ENV['GEMBA_CONFIG_DIR'] = dir
      cache_dir = File.join(dir, "boxart")
      fetcher   = Gemba::BoxartFetcher.new(app: nil, cache_dir: cache_dir,
                                            backend: Gemba::BoxartFetcher::NullBackend.new)
      overrides = Gemba::RomOverrides.new(File.join(dir, "overrides.json"))

      cached = fetcher.cached_path('AGB-AXVE')
      FileUtils.mkdir_p(File.dirname(cached))
      File.write(cached, "cached")

      src = File.join(dir, "my_cover.png")
      File.write(src, "custom")
      overrides.set_custom_boxart('AGB_AXVE-DEADBEEF', src)

      info = Gemba::RomInfo.from_rom(ROM, fetcher: fetcher, overrides: overrides, game_index: NULL_INDEX)
      assert_match %r{custom\.png$}, info.boxart_path, "Custom should beat cached"
    ensure
      ENV.delete('GEMBA_CONFIG_DIR')
    end
  end
end
