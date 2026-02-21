# frozen_string_literal: true

require "minitest/autorun"
require_relative "../shared/tk_test_helper"

# Tests for AchievementsWindow treeview rendering — achievement rows, earned/
# unearned column display, and status bar earned count.
class TestAchievementsWindowTreeRendering < Minitest::Test
  include TeekTestHelper

  def test_tree_shows_achievement_titles
    assert_tk_app("treeview rows show achievement titles from the backend") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'a1', title: 'First Act',  description: '', points: 5)  { false }
        backend.add_achievement(id: 'a2', title: 'Second Act', description: '', points: 10) { false }

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
        assert_equal 2, items.size
        assert_includes titles, 'First Act'
        assert_includes titles, 'Second Act'
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_unearned_achievements_have_empty_earned_column
    assert_tk_app("unearned achievements show empty earned column") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'a1', title: 'Unearned', description: '', points: 5) { false }

        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        win.refresh(backend)
        app.update

        tree = "#{Gemba::AchievementsWindow::TOP}.tf.tree"
        item = app.tcl_eval("#{tree} children {}").split.first
        assert_equal '', app.tcl_eval("#{tree} set #{item} earned")
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_earned_achievements_show_date
    assert_tk_app("earned achievements show a YYYY-MM-DD date in the earned column") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "support/fake_core"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'a1', title: 'Earned One', description: '', points: 5) { |_| true }
        backend.do_frame(FakeCore.new)

        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        win.refresh(backend)
        app.update

        tree   = "#{Gemba::AchievementsWindow::TOP}.tf.tree"
        item   = app.tcl_eval("#{tree} children {}").split.first
        earned = app.tcl_eval("#{tree} set #{item} earned")
        assert_match(/\d{4}-\d{2}-\d{2}/, earned)
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_status_bar_shows_earned_count
    assert_tk_app("status bar shows 'X / Y earned'") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "support/fake_core"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.add_achievement(id: 'a1', title: 'Alpha', description: '', points: 5) { |_| true }
        backend.add_achievement(id: 'a2', title: 'Beta',  description: '', points: 5) { false }
        backend.do_frame(FakeCore.new)

        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        win.refresh(backend)
        app.update

        top    = Gemba::AchievementsWindow::TOP
        status = app.command("#{top}.status_bar.status", :cget, '-text').to_s
        assert_includes status, '1'
        assert_includes status, '2'
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end
end
