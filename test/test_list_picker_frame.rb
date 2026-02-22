# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"

class TestListPickerFrame < Minitest::Test
  include TeekTestHelper

  

  # ── Population ─────────────────────────────────────────────────────────────

  def test_empty_library_shows_no_rows
    assert_tk_app("empty library produces zero treeview rows") do
      require "gemba/headless"

      lib    = Struct.new(:roms) { def all = roms }.new([])
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      items = app.tcl_eval(".list_picker.tree children {}").split
      assert_empty items, "no rows expected for empty library"

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  def test_roms_populate_title_column
    assert_tk_app("ROM titles appear in the title column") do
      require "gemba/headless"

      roms = [
        { 'title' => 'Alpha', 'platform' => 'gba', 'path' => '/a.gba',
          'last_played' => '2026-02-20T10:00:00Z' },
        { 'title' => 'Beta',  'platform' => 'gbc', 'path' => '/b.gbc',
          'last_played' => '2026-02-19T10:00:00Z' },
      ]
      lib    = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      items  = app.tcl_eval(".list_picker.tree children {}").split
      titles = items.map { |id| app.tcl_eval(".list_picker.tree set #{id} title") }
      assert_equal 2, titles.size
      assert_includes titles, 'Alpha'
      assert_includes titles, 'Beta'

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  def test_last_played_formatted_as_month_day_year
    assert_tk_app("last_played ISO string is formatted for display") do
      require "gemba/headless"

      roms = [{ 'title' => 'Game', 'platform' => 'gba', 'path' => '/g.gba',
                'last_played' => '2026-02-22T15:30:00Z' }]
      lib    = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      iid = app.tcl_eval(".list_picker.tree children {}").split.first
      lp  = app.tcl_eval(".list_picker.tree set #{iid} last_played")
      assert_match(/Feb\s+22,\s+2026/, lp)

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  def test_nil_last_played_shows_never_placeholder
    assert_tk_app("ROM with no last_played shows never-played text, not a date") do
      require "gemba/headless"

      roms = [{ 'title' => 'New Game', 'platform' => 'gba', 'path' => '/n.gba' }]
      lib    = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      iid = app.tcl_eval(".list_picker.tree children {}").split.first
      lp  = app.tcl_eval(".list_picker.tree set #{iid} last_played")
      refute_empty lp
      refute_match(/\d{4}/, lp, "should not look like a date")

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  def test_all_roms_shown_without_cap
    assert_tk_app("all 20 library ROMs appear with no cap") do
      require "gemba/headless"

      roms = 20.times.map { |i| { 'title' => "Game #{i}", 'platform' => 'gba', 'path' => "/g#{i}.gba" } }
      lib    = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      count = app.tcl_eval(".list_picker.tree children {}").split.size
      assert_equal 20, count

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  # ── Default sort ────────────────────────────────────────────────────────────

  def test_default_sort_newest_last_played_first
    assert_tk_app("default sort shows most-recently-played ROM first") do
      require "gemba/headless"

      roms = [
        { 'title' => 'Old',    'platform' => 'gba', 'path' => '/o.gba',
          'last_played' => '2024-01-01T00:00:00Z' },
        { 'title' => 'Recent', 'platform' => 'gba', 'path' => '/r.gba',
          'last_played' => '2026-02-22T00:00:00Z' },
        { 'title' => 'Middle', 'platform' => 'gba', 'path' => '/m.gba',
          'last_played' => '2025-06-15T00:00:00Z' },
      ]
      lib    = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      items  = app.tcl_eval(".list_picker.tree children {}").split
      titles = items.map { |id| app.tcl_eval(".list_picker.tree set #{id} title") }
      assert_equal 'Recent', titles[0], "most recent should be first"
      assert_equal 'Middle', titles[1]
      assert_equal 'Old',    titles[2]

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  # ── Sorting ─────────────────────────────────────────────────────────────────

  def test_click_title_heading_sorts_a_to_z_with_indicator
    assert_tk_app("clicking title heading sorts A→Z and shows ▲") do
      require "gemba/headless"

      roms = [
        { 'title' => 'Zelda',       'platform' => 'gba', 'path' => '/z.gba' },
        { 'title' => 'Metroid',     'platform' => 'gba', 'path' => '/m.gba' },
        { 'title' => 'Castlevania', 'platform' => 'gba', 'path' => '/c.gba' },
      ]
      lib    = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      cmd = app.tcl_eval(".list_picker.tree heading title -command")
      app.tcl_eval("uplevel #0 {#{cmd}}")
      app.update

      items  = app.tcl_eval(".list_picker.tree children {}").split
      titles = items.map { |id| app.tcl_eval(".list_picker.tree set #{id} title") }
      assert_equal %w[Castlevania Metroid Zelda], titles
      assert_includes app.tcl_eval(".list_picker.tree heading title -text"), '▲'

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  def test_click_title_heading_twice_reverses_to_z_to_a
    assert_tk_app("clicking title heading twice reverses to Z→A and shows ▼") do
      require "gemba/headless"

      roms = [
        { 'title' => 'Zelda',   'platform' => 'gba', 'path' => '/z.gba' },
        { 'title' => 'Metroid', 'platform' => 'gba', 'path' => '/m.gba' },
      ]
      lib    = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      cmd = app.tcl_eval(".list_picker.tree heading title -command")
      app.tcl_eval("uplevel #0 {#{cmd}}")  # asc
      app.tcl_eval("uplevel #0 {#{cmd}}")  # desc
      app.update

      items  = app.tcl_eval(".list_picker.tree children {}").split
      titles = items.map { |id| app.tcl_eval(".list_picker.tree set #{id} title") }
      assert_equal %w[Zelda Metroid], titles
      assert_includes app.tcl_eval(".list_picker.tree heading title -text"), '▼'

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  def test_click_last_played_heading_sorts_oldest_first
    assert_tk_app("clicking last_played heading (toggle from default desc) shows oldest first") do
      require "gemba/headless"

      roms = [
        { 'title' => 'Old',    'platform' => 'gba', 'path' => '/o.gba',
          'last_played' => '2024-01-01T00:00:00Z' },
        { 'title' => 'Recent', 'platform' => 'gba', 'path' => '/r.gba',
          'last_played' => '2026-02-22T00:00:00Z' },
      ]
      lib    = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      # Default is last_played desc — clicking once switches to asc (oldest first)
      cmd = app.tcl_eval(".list_picker.tree heading last_played -command")
      app.tcl_eval("uplevel #0 {#{cmd}}")
      app.update

      items  = app.tcl_eval(".list_picker.tree children {}").split
      titles = items.map { |id| app.tcl_eval(".list_picker.tree set #{id} title") }
      assert_equal 'Old', titles[0], "ascending: oldest first"
      assert_includes app.tcl_eval(".list_picker.tree heading last_played -text"), '▲'

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  def test_switching_sort_column_clears_old_indicator
    assert_tk_app("switching sort column removes ▲/▼ from the old column") do
      require "gemba/headless"

      roms = [{ 'title' => 'Solo', 'platform' => 'gba', 'path' => '/s.gba' }]
      lib    = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      title_cmd = app.tcl_eval(".list_picker.tree heading title -command")
      lp_cmd    = app.tcl_eval(".list_picker.tree heading last_played -command")

      app.tcl_eval("uplevel #0 {#{title_cmd}}")  # sort by title (adds ▲)
      app.tcl_eval("uplevel #0 {#{lp_cmd}}")     # switch to last_played
      app.update

      title_text = app.tcl_eval(".list_picker.tree heading title -text")
      refute_includes title_text, '▲', "title heading should lose its indicator"
      refute_includes title_text, '▼', "title heading should lose its indicator"

      lp_text = app.tcl_eval(".list_picker.tree heading last_played -text")
      assert(lp_text.include?('▲') || lp_text.include?('▼'),
             "last_played heading should now show an indicator")

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  # ── Interaction ─────────────────────────────────────────────────────────────

  def test_double_click_row_emits_rom_selected
    assert_tk_app("double-clicking a row emits :rom_selected with the ROM path") do
      require "gemba/headless"

      rom_path = '/games/fire_red.gba'
      roms     = [{ 'title' => 'Fire Red', 'platform' => 'gba', 'path' => rom_path }]
      lib      = Struct.new(:roms) { def all = roms }.new(roms)
      picker   = Gemba::ListPickerFrame.new(app: app, rom_library: lib)

      received = nil
      Gemba.bus.on(:rom_selected) { |path| received = path }

      picker.show
      app.show
      app.update

      iid = app.tcl_eval(".list_picker.tree children {}").split.first
      app.tcl_eval(".list_picker.tree focus #{iid}")
      app.tcl_eval(".list_picker.tree selection set #{iid}")
      app.tcl_eval("event generate .list_picker.tree <<DoubleClick>>")
      app.update

      assert_equal rom_path, received

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  def test_right_click_quick_load_disabled_when_no_save_state
    assert_tk_app("<<RightClick>> quick load entry is disabled with no save file") do
      require "gemba/headless"
      require "tmpdir"

      Dir.mktmpdir("list_picker_qs_test") do |tmpdir|
        rom_id = "AGB-TEST-DEADBEEF"
        roms   = [{ 'title' => 'Test', 'platform' => 'gba',
                    'rom_id' => rom_id, 'game_code' => 'AGB-TEST',
                    'path' => '/games/test.gba', 'last_played' => '2026-01-01T00:00:00Z' }]

        Gemba.user_config.states_dir = tmpdir
        lib    = Struct.new(:roms) { def all = roms }.new(roms)
        picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
        picker.show
        app.show
        app.update

        iid = app.tcl_eval(".list_picker.tree children {}").split.first
        app.tcl_eval(".list_picker.tree focus #{iid}")
        app.tcl_eval(".list_picker.tree selection set #{iid}")

        override_tk_popup do
          app.tcl_eval("event generate .list_picker.tree <<RightClick>>")
          app.update
        end

        state = app.tcl_eval(".list_picker.tree.ctx entrycget 1 -state")
        assert_equal 'disabled', state

        app.command(:destroy, '.list_picker') rescue nil
      end
    end
  end

  def test_right_click_quick_load_enabled_when_save_state_exists
    assert_tk_app("<<RightClick>> quick load entry is enabled when save file exists") do
      require "gemba/headless"
      require "tmpdir"
      require "fileutils"

      fixture = File.expand_path("test/fixtures/test_quicksave.ss")

      Dir.mktmpdir("list_picker_qs_test") do |tmpdir|
        rom_id    = "AGB-TEST-DEADBEEF"
        slot      = Gemba.user_config.quick_save_slot
        state_dir = File.join(tmpdir, rom_id)
        FileUtils.mkdir_p(state_dir)
        FileUtils.cp(fixture, File.join(state_dir, "state#{slot}.ss"))

        roms = [{ 'title' => 'Test', 'platform' => 'gba',
                  'rom_id' => rom_id, 'game_code' => 'AGB-TEST',
                  'path' => '/games/test.gba', 'last_played' => '2026-01-01T00:00:00Z' }]

        Gemba.user_config.states_dir = tmpdir
        lib    = Struct.new(:roms) { def all = roms }.new(roms)
        picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
        picker.show
        app.show
        app.update

        iid = app.tcl_eval(".list_picker.tree children {}").split.first
        app.tcl_eval(".list_picker.tree focus #{iid}")
        app.tcl_eval(".list_picker.tree selection set #{iid}")

        override_tk_popup do
          app.tcl_eval("event generate .list_picker.tree <<RightClick>>")
          app.update
        end

        state = app.tcl_eval(".list_picker.tree.ctx entrycget 1 -state")
        assert_equal 'normal', state

        app.command(:destroy, '.list_picker') rescue nil
      end
    end
  end

  def test_refresh_repopulates_rows
    assert_tk_app("receive(:refresh) updates rows from the current library state") do
      require "gemba/headless"

      roms = [{ 'title' => 'Alpha', 'platform' => 'gba', 'path' => '/a.gba' }]
      lib  = Struct.new(:roms) { def all = roms }.new(roms)

      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.update

      items  = app.tcl_eval(".list_picker.tree children {}").split
      titles = items.map { |id| app.tcl_eval(".list_picker.tree set #{id} title") }
      assert_equal ['Alpha'], titles

      lib.roms = [
        { 'title' => 'Alpha', 'platform' => 'gba', 'path' => '/a.gba' },
        { 'title' => 'Beta',  'platform' => 'gbc', 'path' => '/b.gbc' },
      ]
      picker.receive(:refresh)
      app.update

      items  = app.tcl_eval(".list_picker.tree children {}").split
      titles = items.map { |id| app.tcl_eval(".list_picker.tree set #{id} title") }
      assert_equal 2, titles.size
      assert_includes titles, 'Alpha'
      assert_includes titles, 'Beta'

      app.command(:destroy, '.list_picker') rescue nil
    end
  end
end
