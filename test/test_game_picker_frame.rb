# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestGamePickerFrame < Minitest::Test
  include TeekTestHelper

  # Each test gets a fresh picker. Since Teek::TestWorker persists across tests,
  # we must destroy .game_picker at the end of each test so the next test can
  # recreate it cleanly (ttk::frame fails if the path already exists).
  def cleanup_picker(app)
    app.command(:destroy, '.game_picker') rescue nil
  end

  def test_empty_library_shows_all_hollow_cards
    assert_tk_app("empty library shows all hollow cards") do
      require "gemba/game_picker_frame"

      lib = Struct.new(:roms) { def all = roms }.new([])
      picker = Gemba::GamePickerFrame.new(app: app, rom_library: lib)
      picker.show

      16.times do |i|
        title = app.command(".game_picker.card#{i}.title", :cget, '-text')
        assert_equal '', title, "Card #{i} title should be empty"

        img = app.command(".game_picker.card#{i}.img", :cget, '-image')
        assert_equal 'boxart_placeholder', img, "Card #{i} should show placeholder image"

        bg = app.command(".game_picker.card#{i}", :cget, '-bg')
        assert_equal '#1a1a1a', bg, "Card #{i} should have hollow background"
      end

      picker.cleanup
      app.command(:destroy, '.game_picker') rescue nil
    end
  end

  def test_populated_card_shows_title_and_platform
    assert_tk_app("populated card shows title and platform text") do
      require "gemba/game_picker_frame"

      rom = { 'title' => 'Pokemon Ruby', 'platform' => 'gba',
              'game_code' => 'AGB-AXVE', 'path' => '/games/ruby.gba' }
      lib = Struct.new(:roms) { def all = roms }.new([rom])
      picker = Gemba::GamePickerFrame.new(app: app, rom_library: lib)
      picker.show

      assert_equal 'Pokemon Ruby', app.command('.game_picker.card0.title', :cget, '-text')
      assert_equal 'GBA',          app.command('.game_picker.card0.plat',  :cget, '-text')

      picker.cleanup
      app.command(:destroy, '.game_picker') rescue nil
    end
  end

  def test_platform_is_uppercased
    assert_tk_app("platform label is uppercased") do
      require "gemba/game_picker_frame"

      rom = { 'title' => 'Tetris', 'platform' => 'gbc', 'path' => '/games/tetris.gbc' }
      lib = Struct.new(:roms) { def all = roms }.new([rom])
      picker = Gemba::GamePickerFrame.new(app: app, rom_library: lib)
      picker.show

      assert_equal 'GBC', app.command('.game_picker.card0.plat', :cget, '-text')

      picker.cleanup
      app.command(:destroy, '.game_picker') rescue nil
    end
  end

  def test_title_falls_back_to_rom_id_when_title_missing
    assert_tk_app("title falls back to rom_id when title key absent") do
      require "gemba/game_picker_frame"

      rom = { 'rom_id' => 'MY-ROM', 'platform' => 'gba', 'path' => '/games/x.gba' }
      lib = Struct.new(:roms) { def all = roms }.new([rom])
      picker = Gemba::GamePickerFrame.new(app: app, rom_library: lib)
      picker.show

      assert_equal 'MY-ROM', app.command('.game_picker.card0.title', :cget, '-text')

      picker.cleanup
      app.command(:destroy, '.game_picker') rescue nil
    end
  end

  def test_populated_card_background_differs_from_hollow
    assert_tk_app("populated card has different background color than hollow card") do
      require "gemba/game_picker_frame"

      rom = { 'title' => 'Test Game', 'platform' => 'gba', 'path' => '/games/test.gba' }
      lib = Struct.new(:roms) { def all = roms }.new([rom])
      picker = Gemba::GamePickerFrame.new(app: app, rom_library: lib)
      picker.show

      pop_bg    = app.command('.game_picker.card0', :cget, '-bg')
      hollow_bg = app.command('.game_picker.card1', :cget, '-bg')

      assert_equal '#2a2a2a', pop_bg,    "Populated card background"
      assert_equal '#1a1a1a', hollow_bg, "Hollow card background"

      picker.cleanup
      app.command(:destroy, '.game_picker') rescue nil
    end
  end

  def test_multiple_roms_populate_correct_cards_in_order
    assert_tk_app("multiple ROMs fill cards in order; remainder are hollow") do
      require "gemba/game_picker_frame"

      roms = [
        { 'title' => 'Alpha', 'platform' => 'gba', 'path' => '/a.gba' },
        { 'title' => 'Beta',  'platform' => 'gbc', 'path' => '/b.gbc' },
      ]
      lib = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::GamePickerFrame.new(app: app, rom_library: lib)
      picker.show

      assert_equal 'Alpha', app.command('.game_picker.card0.title', :cget, '-text')
      assert_equal 'GBA',   app.command('.game_picker.card0.plat',  :cget, '-text')
      assert_equal 'Beta',  app.command('.game_picker.card1.title', :cget, '-text')
      assert_equal 'GBC',   app.command('.game_picker.card1.plat',  :cget, '-text')
      assert_equal '',      app.command('.game_picker.card2.title', :cget, '-text')

      picker.cleanup
      app.command(:destroy, '.game_picker') rescue nil
    end
  end

  def test_pre_cached_boxart_shown_immediately_without_network
    assert_tk_app("pre-cached boxart image is set on the card without any network fetch") do
      require "gemba/game_picker_frame"
      require "gemba/boxart_fetcher"
      require "tmpdir"
      require "fileutils"

      game_code = 'AGB-AXVE'
      tmpdir    = Dir.mktmpdir('picker_test')
      cache_dir = File.join(tmpdir, game_code)
      FileUtils.mkdir_p(cache_dir)
      # Re-use the placeholder PNG — it's a real PNG Tk already loads successfully
      FileUtils.cp(Gemba::GamePickerFrame::PLACEHOLDER_PNG, File.join(cache_dir, 'boxart.png'))

      # Backend that would return a URL, but the cache hit means it's never called
      backend = Struct.new(:url) { def url_for(_) = url }.new('https://example.com/fake.png')
      fetcher = Gemba::BoxartFetcher.new(app: app, cache_dir: tmpdir, backend: backend)

      rom = { 'title' => 'Pokemon Ruby', 'platform' => 'gba',
              'game_code' => game_code, 'path' => '/fake.gba' }
      lib = Struct.new(:roms) { def all = roms }.new([rom])
      picker = Gemba::GamePickerFrame.new(app: app, rom_library: lib, boxart_fetcher: fetcher)
      picker.show

      img_name = app.command('.game_picker.card0.img', :cget, '-image')
      assert_equal "boxart_#{game_code}", img_name,
        "Card should display cached boxart image, not the placeholder"

      FileUtils.rm_rf(tmpdir)
      picker.cleanup
      app.command(:destroy, '.game_picker') rescue nil
    end
  end

  def test_no_fetcher_leaves_placeholder_on_card
    assert_tk_app("card with game_code but no fetcher stays on placeholder") do
      require "gemba/game_picker_frame"

      rom = { 'title' => 'Some Game', 'platform' => 'gba',
              'game_code' => 'AGB-TEST', 'path' => '/games/some.gba' }
      lib = Struct.new(:roms) { def all = roms }.new([rom])
      # No boxart_fetcher passed
      picker = Gemba::GamePickerFrame.new(app: app, rom_library: lib)
      picker.show

      img_name = app.command('.game_picker.card0.img', :cget, '-image')
      assert_equal 'boxart_placeholder', img_name

      picker.cleanup
      app.command(:destroy, '.game_picker') rescue nil
    end
  end
end
