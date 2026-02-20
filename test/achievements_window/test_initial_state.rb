# frozen_string_literal: true

require "minitest/autorun"
require_relative "../shared/tk_test_helper"

# Tests for AchievementsWindow initial widget state — sync button, unofficial
# checkbox, game combo filter, and status bar default text.
class TestAchievementsWindowInitialState < Minitest::Test
  include TeekTestHelper

  TOP = Gemba::AchievementsWindow::TOP rescue '.gemba_achievements'

  def test_sync_button_disabled_when_not_authenticated
    assert_tk_app("sync button disabled when not authenticated") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new  # NOT logged in
        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        app.update

        top = Gemba::AchievementsWindow::TOP
        assert_equal 'disabled',
          app.command("#{top}.toolbar.sync", :cget, '-state').to_s
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_sync_button_enabled_when_authenticated
    assert_tk_app("sync button enabled when authenticated") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        app.update

        top = Gemba::AchievementsWindow::TOP
        assert_equal 'normal',
          app.command("#{top}.toolbar.sync", :cget, '-state').to_s
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_unofficial_checkbox_reflects_config_false
    assert_tk_app("unofficial checkbox is unchecked when config is false") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        app.update

        assert_equal '0', app.get_variable(Gemba::AchievementsWindow::VAR_UNOFFICIAL)
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_unofficial_checkbox_reflects_config_true
    assert_tk_app("unofficial checkbox is checked when config is true") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(true)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        app.update

        assert_equal '1', app.get_variable(Gemba::AchievementsWindow::VAR_UNOFFICIAL)
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_combo_shows_only_gba_games
    assert_tk_app("combo lists GBA games only, not GB or GBC") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        roms = [
          make_rom_entry(id: 'gba1', title: 'GBA Game', platform: 'gba'),
          make_rom_entry(id: 'gb1',  title: 'GB Game',  platform: 'gb'),
          make_rom_entry(id: 'gbc1', title: 'GBC Game', platform: 'gbc'),
        ]
        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library(*roms), config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        app.update

        top    = Gemba::AchievementsWindow::TOP
        values = app.command("#{top}.toolbar.combo", :cget, '-values').to_s
        assert_includes values, 'GBA Game'
        refute_includes values, 'GB Game'
        refute_includes values, 'GBC Game'
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_status_shows_none_when_empty
    assert_tk_app("status shows 'no achievements' when backend has no achievements") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        app.update

        top    = Gemba::AchievementsWindow::TOP
        status = app.command("#{top}.status", :cget, '-text').to_s
        assert_equal Gemba::Locale.translate('achievements.none'), status
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end
end
