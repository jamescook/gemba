# frozen_string_literal: true

require "minitest/autorun"
require_relative "../shared/tk_test_helper"

# Tests for AchievementsWindow treeview column sorting — default order,
# heading click indicators, and indicator cleanup when switching columns.
class TestAchievementsWindowSorting < Minitest::Test
  include TeekTestHelper

  def test_default_sort_earned_first_then_alphabetical
    assert_tk_app("default sort: earned first, then unearned A→Z") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "support/fake_core"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'z', title: 'Zebra',    description: '', points: 5) { false }
        backend.add_achievement(id: 'a', title: 'Aardvark', description: '', points: 5) { |_| true }
        backend.add_achievement(id: 'm', title: 'Monkey',   description: '', points: 5) { false }
        backend.do_frame(FakeCore.new)

        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        win.refresh(backend)
        app.update

        tree   = "#{Gemba::AchievementsWindow::TOP}.tf.tree"
        items  = app.tcl_eval("#{tree} children {}").split
        titles = items.map { |id| app.tcl_eval("#{tree} set #{id} name") }
        assert_equal 'Aardvark', titles[0], "earned should be first"
        assert_equal 'Monkey',   titles[1], "Monkey before Zebra alphabetically"
        assert_equal 'Zebra',    titles[2]
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_click_name_heading_sorts_asc_with_indicator
    assert_tk_app("clicking name heading sorts A→Z and shows ▲") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'z', title: 'Zebra',    description: '', points: 5) { false }
        backend.add_achievement(id: 'a', title: 'Aardvark', description: '', points: 5) { false }
        backend.add_achievement(id: 'm', title: 'Monkey',   description: '', points: 5) { false }

        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        win.refresh(backend)
        app.update

        tree = "#{Gemba::AchievementsWindow::TOP}.tf.tree"
        cmd  = app.tcl_eval("#{tree} heading name -command")
        app.tcl_eval("uplevel #0 {#{cmd}}")
        app.update

        items  = app.tcl_eval("#{tree} children {}").split
        titles = items.map { |id| app.tcl_eval("#{tree} set #{id} name") }
        assert_equal %w[Aardvark Monkey Zebra], titles

        assert_includes app.tcl_eval("#{tree} heading name -text"), '▲'
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_click_name_heading_twice_reverses_to_desc
    assert_tk_app("clicking name heading twice reverses to Z→A and shows ▼") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'z', title: 'Zebra',    description: '', points: 5) { false }
        backend.add_achievement(id: 'a', title: 'Aardvark', description: '', points: 5) { false }

        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        win.refresh(backend)
        app.update

        tree = "#{Gemba::AchievementsWindow::TOP}.tf.tree"
        cmd  = app.tcl_eval("#{tree} heading name -command")
        app.tcl_eval("uplevel #0 {#{cmd}}")  # asc
        app.tcl_eval("uplevel #0 {#{cmd}}")  # desc
        app.update

        items  = app.tcl_eval("#{tree} children {}").split
        titles = items.map { |id| app.tcl_eval("#{tree} set #{id} name") }
        assert_equal %w[Zebra Aardvark], titles
        assert_includes app.tcl_eval("#{tree} heading name -text"), '▼'
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_click_points_heading_sorts_low_to_high
    assert_tk_app("clicking points heading sorts by points low→high") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'a', title: 'High', description: '', points: 50) { false }
        backend.add_achievement(id: 'b', title: 'Low',  description: '', points: 5)  { false }
        backend.add_achievement(id: 'c', title: 'Mid',  description: '', points: 25) { false }

        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        win.refresh(backend)
        app.update

        tree = "#{Gemba::AchievementsWindow::TOP}.tf.tree"
        cmd  = app.tcl_eval("#{tree} heading points -command")
        app.tcl_eval("uplevel #0 {#{cmd}}")
        app.update

        items = app.tcl_eval("#{tree} children {}").split
        pts   = items.map { |id| app.tcl_eval("#{tree} set #{id} points").to_i }
        assert_equal [5, 25, 50], pts
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_click_earned_heading_puts_unearned_last
    assert_tk_app("clicking earned heading keeps unearned rows at the bottom") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "support/fake_core"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'e', title: 'Earned',   description: '', points: 5) { |_| true }
        backend.add_achievement(id: 'u', title: 'Unearned', description: '', points: 5) { false }
        backend.do_frame(FakeCore.new)

        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        win.refresh(backend)
        app.update

        tree = "#{Gemba::AchievementsWindow::TOP}.tf.tree"
        cmd  = app.tcl_eval("#{tree} heading earned -command")
        app.tcl_eval("uplevel #0 {#{cmd}}")
        app.update

        items  = app.tcl_eval("#{tree} children {}").split
        earned = items.map { |id| app.tcl_eval("#{tree} set #{id} earned") }
        assert_equal '',  earned.last,  "unearned must be last"
        refute_equal '', earned.first,  "earned must be first"
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_switching_sort_column_clears_old_indicator
    assert_tk_app("switching sort column removes indicator from previously sorted column") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'a', title: 'Alpha', description: '', points: 5) { false }

        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        win.refresh(backend)
        app.update

        tree     = "#{Gemba::AchievementsWindow::TOP}.tf.tree"
        name_cmd = app.tcl_eval("#{tree} heading name   -command")
        pts_cmd  = app.tcl_eval("#{tree} heading points -command")
        app.tcl_eval("uplevel #0 {#{name_cmd}}")   # sort by name
        app.tcl_eval("uplevel #0 {#{pts_cmd}}")    # switch to points
        app.update

        name_text = app.tcl_eval("#{tree} heading name -text")
        pts_text  = app.tcl_eval("#{tree} heading points -text")
        refute_includes name_text, '▲', "name heading must lose indicator after switching"
        refute_includes name_text, '▼', "name heading must lose indicator after switching"
        assert_includes pts_text,  '▲', "points heading should show ▲"
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end
end
