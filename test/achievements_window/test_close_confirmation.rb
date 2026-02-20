# frozen_string_literal: true

require "minitest/autorun"
require_relative "../shared/tk_test_helper"

# Tests for AchievementsWindow close-during-bulk-sync confirmation dialog —
# no dialog when not syncing, dialog shown mid-sync, 'no' keeps window open,
# 'yes' stops sync and withdraws the window.
class TestAchievementsWindowCloseConfirmation < Minitest::Test
  include TeekTestHelper

  def test_hide_without_bulk_sync_does_not_show_dialog
    assert_tk_app("win.hide when not syncing closes without showing any dialog") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        Gemba.bus = Gemba::EventBus.new

        app.tcl_eval("set ::ach_dlg 0")
        app.tcl_eval("proc tk_messageBox {args} { incr ::ach_dlg; return yes }")

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        win = Gemba::AchievementsWindow.new(
          app: app, rom_library: make_rom_library, config: FakeConfig.new(false)
        )
        win.update_game(rom_id: nil, backend: backend)
        win.show
        app.update

        win.hide
        app.update

        assert_equal '0', app.tcl_eval("set ::ach_dlg").strip,
          "tk_messageBox must not be called when not in bulk sync"
      ensure
        app.tcl_eval("catch {rename tk_messageBox {}}") rescue nil
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_hide_during_bulk_sync_shows_dialog
    assert_tk_app("win.hide mid-sync triggers a tk_messageBox confirmation") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "tmpdir"
        Gemba.bus = Gemba::EventBus.new

        app.tcl_eval("set ::ach_dlg 0")
        app.tcl_eval("proc tk_messageBox {args} { incr ::ach_dlg; return no }")

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')

        win       = nil
        attempted = false
        backend.stub_fetch_for_display do |_|
          unless attempted
            attempted = true
            win.hide   # dialog returns "no" → stays open
            app.update
          end
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

          assert_equal '1', app.tcl_eval("set ::ach_dlg").strip,
            "tk_messageBox must be shown when hiding during bulk sync"
        ensure
          ENV.delete('GEMBA_CONFIG_DIR')
        end
      ensure
        app.tcl_eval("catch {rename tk_messageBox {}}") rescue nil
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_hide_confirm_no_keeps_window_visible
    assert_tk_app("answering 'no' to the cancel-sync dialog keeps the window open") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "tmpdir"
        Gemba.bus = Gemba::EventBus.new

        app.tcl_eval("proc tk_messageBox {args} { return no }")

        backend = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')

        win       = nil
        attempted = false
        backend.stub_fetch_for_display do |_|
          unless attempted
            attempted = true
            win.hide
            app.update
          end
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

          # wm state is unreliable in xvfb when the root is withdrawn; instead
          # verify the sync completed and UI was unlocked — only possible if
          # the window stayed open and the sync ran to completion.
          assert_equal 'normal', app.command("#{top}.toolbar.sync", :cget, '-state').to_s,
            "sync button must be re-enabled after sync completes (window stayed open)"
        ensure
          ENV.delete('GEMBA_CONFIG_DIR')
        end
      ensure
        app.tcl_eval("catch {rename tk_messageBox {}}") rescue nil
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end

  def test_hide_confirm_yes_stops_sync_and_withdraws_window
    assert_tk_app("answering 'yes' stops the bulk sync and withdraws the window") do
      begin
        require "gemba/headless"
        require "support/achievements_window_helpers"
        require "tmpdir"
        Gemba.bus = Gemba::EventBus.new

        app.tcl_eval("proc tk_messageBox {args} { return yes }")

        win         = nil
        fetch_count = 0
        hide_done   = false
        backend     = Gemba::Achievements::FakeBackend.new
        backend.login_with_token(username: 'u', token: 't')
        backend.stub_fetch_for_display do |_|
          fetch_count += 1
          unless hide_done
            hide_done = true
            win.hide   # dialog returns "yes" → cancel + withdraw
            app.update
          end
          nil
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

          assert_equal 1, fetch_count, "sync must stop after the first game when user says yes"
          assert_equal 'withdrawn', app.tcl_eval("wm state #{top}").strip,
            "window must be withdrawn after user confirms close"
        ensure
          ENV.delete('GEMBA_CONFIG_DIR')
        end
      ensure
        app.tcl_eval("catch {rename tk_messageBox {}}") rescue nil
        app.command(:destroy, Gemba::AchievementsWindow::TOP) rescue nil
      end
    end
  end
end
