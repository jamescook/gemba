# frozen_string_literal: true

require "minitest/autorun"
require_relative "../shared/tk_test_helper"

# Tests for AchievementsWindow event bus subscriptions — sync started/done
# disables/enables the sync button and auth-result logout disables it.
class TestAchievementsWindowBusEvents < Minitest::Test
  include TeekTestHelper

  def test_ra_sync_started_disables_sync_button
    assert_tk_app(":ra_sync_started disables the sync button") do
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

        Gemba.bus.emit(:ra_sync_started)
        app.update

        top = Gemba::AchievementsWindow::TOP
        assert_equal 'disabled',
          app.command("#{top}.toolbar.sync", :cget, '-state').to_s
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_ra_sync_done_ok_re_enables_sync_button
    assert_tk_app(":ra_sync_done(ok: true) re-enables the sync button") do
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

        Gemba.bus.emit(:ra_sync_started)
        app.update
        Gemba.bus.emit(:ra_sync_done, ok: true)
        app.update

        top = Gemba::AchievementsWindow::TOP
        assert_equal 'normal',
          app.command("#{top}.toolbar.sync", :cget, '-state').to_s
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_ra_sync_done_fail_shows_error_status
    assert_tk_app(":ra_sync_done(ok: false) shows sync_failed in status bar") do
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

        Gemba.bus.emit(:ra_sync_done, ok: false)
        app.update

        top    = Gemba::AchievementsWindow::TOP
        status = app.command("#{top}.status", :cget, '-text').to_s
        assert_equal Gemba::Locale.translate('achievements.sync_failed'), status
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_ra_auth_result_logout_disables_sync_button
    assert_tk_app(":ra_auth_result after logout disables sync button") do
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

        backend.logout
        Gemba.bus.emit(:ra_auth_result, status: :logout)
        app.update

        top = Gemba::AchievementsWindow::TOP
        assert_equal 'disabled',
          app.command("#{top}.toolbar.sync", :cget, '-state').to_s
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end
end
