# frozen_string_literal: true

require "minitest/autorun"
require_relative "../shared/tk_test_helper"

# Tests for AchievementsWindow bulk sync — unofficial toggle fires bus event,
# UI locks/unlocks during sync, per-game status updates, and done count display.
class TestAchievementsWindowBulkSync < Minitest::Test
  include TeekTestHelper

  def test_unofficial_toggle_fires_bus_event
    assert_tk_app("toggling unofficial checkbox fires :ra_unofficial_changed on the bus") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "tmpdir"
        Gemba.bus = Gemba::EventBus.new

        received = nil
        Gemba.bus.on(:ra_unofficial_changed) { |value:, **| received = value }

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.stub_fetch_for_display([])

        Dir.mktmpdir("ach_win_test") do |tmpdir|
          ENV['GEMBA_CONFIG_DIR'] = tmpdir
          win = Gemba::AchievementsWindow.new(
            app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
          )
          win.update_game(rom_id: nil, backend: backend)
          win.show
          app.update

          top = Gemba::AchievementsWindow::TOP
          app.command("#{top}.toolbar.unofficial", 'invoke')
          app.update

          assert_equal true, received, ":ra_unofficial_changed should fire with true"
        ensure
          ENV.delete('GEMBA_CONFIG_DIR')
        end
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_unofficial_toggle_locks_ui_during_sync
    assert_tk_app("unofficial toggle disables both buttons while bulk sync runs") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "tmpdir"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')

        # Capture widget states from INSIDE the fetch callback — FakeBackend
        # calls synchronously so we're mid-sync right here.
        mid_sync_states = {}
        backend.stub_fetch_for_display do |_|
          top = Gemba::AchievementsWindow::TOP
          mid_sync_states[:sync]  = app.command("#{top}.toolbar.sync",      :cget, '-state').to_s
          mid_sync_states[:unoff] = app.command("#{top}.toolbar.unofficial", :cget, '-state').to_s
          nil
        end

        roms = [make_rom_entry(id: 'r1', title: 'Game')]
        Dir.mktmpdir("ach_win_test") do |tmpdir|
          ENV['GEMBA_CONFIG_DIR'] = tmpdir
          win = Gemba::AchievementsWindow.new(
            app: app, rom_library: make_rom_library(*roms), config: FakeConfig.new(false)
          )
          win.update_game(rom_id: nil, backend: backend)
          win.show
          app.update

          top = Gemba::AchievementsWindow::TOP
          app.command("#{top}.toolbar.unofficial", 'invoke')
          app.update

          assert_equal 'disabled', mid_sync_states[:sync],  "sync button locked during bulk sync"
          assert_equal 'disabled', mid_sync_states[:unoff], "unofficial button locked during bulk sync"
        ensure
          ENV.delete('GEMBA_CONFIG_DIR')
        end
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_bulk_sync_shows_per_game_status_updates
    assert_tk_app("bulk sync updates the status bar for each game in sequence") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "tmpdir"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')

        statuses = []
        backend.stub_fetch_for_display do |_|
          top = Gemba::AchievementsWindow::TOP
          statuses << app.command("#{top}.status_bar.status", :cget, '-text').to_s
          []
        end

        roms = [
          make_rom_entry(id: 'r1', title: 'Game One'),
          make_rom_entry(id: 'r2', title: 'Game Two'),
        ]
        Dir.mktmpdir("ach_win_test") do |tmpdir|
          ENV['GEMBA_CONFIG_DIR'] = tmpdir
          win = Gemba::AchievementsWindow.new(
            app: app, rom_library: make_rom_library(*roms), config: FakeConfig.new(false)
          )
          win.update_game(rom_id: nil, backend: backend)
          win.show
          app.update

          top = Gemba::AchievementsWindow::TOP
          app.command("#{top}.toolbar.unofficial", 'invoke')
          app.update

          assert_equal 2, statuses.size,           "one status update per game"
          assert_includes statuses[0], 'Game One', "first update names Game One"
          assert_includes statuses[1], 'Game Two', "second update names Game Two"
        ensure
          ENV.delete('GEMBA_CONFIG_DIR')
        end
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_bulk_sync_unlocks_ui_when_complete
    assert_tk_app("bulk sync re-enables buttons after all games are done") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "tmpdir"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.stub_fetch_for_display([])

        roms = [make_rom_entry(id: 'r1', title: 'Game')]
        Dir.mktmpdir("ach_win_test") do |tmpdir|
          ENV['GEMBA_CONFIG_DIR'] = tmpdir
          win = Gemba::AchievementsWindow.new(
            app: app, rom_library: make_rom_library(*roms), config: FakeConfig.new(false)
          )
          win.update_game(rom_id: nil, backend: backend)
          win.show
          app.update

          top = Gemba::AchievementsWindow::TOP
          app.command("#{top}.toolbar.unofficial", 'invoke')
          app.update

          assert_equal 'normal', app.command("#{top}.toolbar.sync",      :cget, '-state').to_s
          assert_equal 'normal', app.command("#{top}.toolbar.unofficial", :cget, '-state').to_s
        ensure
          ENV.delete('GEMBA_CONFIG_DIR')
        end
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_bulk_sync_done_status_shows_count
    assert_tk_app("status bar shows N-game count after bulk sync completes") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "tmpdir"
        Gemba.bus = Gemba::EventBus.new

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.stub_fetch_for_display([])

        roms = [
          make_rom_entry(id: 'r1', title: 'Game A'),
          make_rom_entry(id: 'r2', title: 'Game B'),
        ]
        Dir.mktmpdir("ach_win_test") do |tmpdir|
          ENV['GEMBA_CONFIG_DIR'] = tmpdir
          win = Gemba::AchievementsWindow.new(
            app: app, rom_library: make_rom_library(*roms), config: FakeConfig.new(false)
          )
          win.update_game(rom_id: nil, backend: backend)
          win.show
          app.update

          top = Gemba::AchievementsWindow::TOP
          app.command("#{top}.toolbar.unofficial", 'invoke')
          app.update

          status = app.command("#{top}.status_bar.status", :cget, '-text').to_s
          assert_includes status, '2', "done status should mention 2 games synced"
        ensure
          ENV.delete('GEMBA_CONFIG_DIR')
        end
      ensure
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end
end
