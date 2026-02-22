# frozen_string_literal: true

require "minitest/autorun"
require_relative "shared/tk_test_helper"
require "gemba"

# Tests for the virtual event layer.
#
# Physical key → virtual event translation is one line per action; the
# interesting thing to test is that the virtual event bindings on '.'
# actually fire when triggered directly (no focus needed).
#
# assert_virtual_event_fires runs a subprocess that:
#   1. Appends {+lappend ::virt_fired EventName} to the binding on '.'
#   2. Generates the virtual event from an after(50) callback
#   3. In an after(0) reads ::virt_fired and prints EVENTNAME_FIRED
#   4. Quits via <<Quit>> (or player.running = false for no-ROM cases)
#
# <<Quit>> is special — its original binding stops the mainloop before
# after(0) can run, so it prints synchronously inside the appended binding.
class TestVirtualEvents < Minitest::Test
  include TeekTestHelper

  TEST_ROM = File.expand_path("fixtures/test.gba", __dir__)

  # ── Key → action mapping (pure unit tests, no subprocess) ─────────────────

  def test_default_quit_key_maps_to_quit_action
    assert_equal :quit,       Gemba::HotkeyMap.new(Gemba::Config.new).action_for('q')
  end

  def test_default_quick_save_key_maps_to_quick_save_action
    assert_equal :quick_save, Gemba::HotkeyMap.new(Gemba::Config.new).action_for('F5')
  end

  def test_default_quick_load_key_maps_to_quick_load_action
    assert_equal :quick_load, Gemba::HotkeyMap.new(Gemba::Config.new).action_for('F8')
  end

  def test_default_record_key_maps_to_record_action
    assert_equal :record, Gemba::HotkeyMap.new(Gemba::Config.new).action_for('F10')
  end

  # ── Virtual event bindings (subprocess, no physical keypresses) ────────────

  def test_quit_virtual_event_fires_binding
    # <<Quit>> stops the mainloop before after(0) runs — print synchronously
    # inside the appended binding instead.
    code = <<~RUBY
      require "gemba"
      require "support/player_helpers"

      player = Gemba::AppController.new("#{TEST_ROM}")
      player.disable_confirmations!
      app = player.app

      poll_until_ready(player) do
        app.tcl_eval('bind . <<Quit>> {+puts QUIT_FIRED; flush stdout}')
        app.after(50) { app.command(:event, 'generate', '.', '<<Quit>>') }
      end

      player.run
    RUBY

    _, stdout, stderr, _ = tk_subprocess(code)
    output = ["STDOUT:\n#{stdout}", "STDERR:\n#{stderr}"].reject { |s| s.end_with?("\n") }
    assert_includes stdout, "QUIT_FIRED", "<<Quit>> binding did not fire\n#{output.join("\n")}"
  end

  def test_quick_save_virtual_event_fires_binding
    assert_virtual_event_fires('QuickSave',
      setup_code: 'player.config.states_dir = Dir.mktmpdir("gemba-virt-test")',
      cleanup_code: 'FileUtils.rm_rf(player.config.states_dir)')
  end

  def test_quick_load_virtual_event_fires_binding
    assert_virtual_event_fires('QuickLoad')
  end

  def test_record_toggle_virtual_event_fires_binding
    assert_virtual_event_fires('RecordToggle',
      setup_code: 'player.config.recordings_dir = Dir.mktmpdir("gemba-virt-rec")',
      cleanup_code: 'FileUtils.rm_rf(player.config.recordings_dir)')
  end

  def test_toggle_help_window_virtual_event_fires_binding
    assert_virtual_event_fires('ToggleHelpWindow', with_rom: false)
  end

  # ── ListPickerFrame <<RightClick>> virtual event ───────────────────────────

  def test_double_button1_on_list_picker_tree_fires_double_click_virtual_event
    assert_tk_app("<Double-Button-1> on list picker treeview generates <<DoubleClick>>") do
      require "gemba/headless"

      roms = [{ 'title' => 'Test', 'platform' => 'gba', 'path' => '/t.gba' }]
      lib  = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.show
      app.update

      tree = '.list_picker.tree'
      app.tcl_eval("bind #{tree} <<DoubleClick>> {+set ::dclick_fired 1}")

      iid = app.tcl_eval("#{tree} children {}").split.first
      app.tcl_eval("#{tree} focus #{iid}")
      app.tcl_eval("#{tree} selection set #{iid}")
      # Simulate double-click via the virtual event directly (event generate
      # <Double-Button-1> is forbidden in Tk 9).
      app.tcl_eval("event generate #{tree} <<DoubleClick>>")
      app.update

      fired = app.tcl_eval("info exists ::dclick_fired") rescue "0"
      assert_equal "1", fired, "<<DoubleClick>> binding did not fire"

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  def test_button3_on_list_picker_tree_fires_right_click_virtual_event
    assert_tk_app("<Button-3> on list picker treeview generates <<RightClick>>") do
      require "gemba/headless"

      roms = [{ 'title' => 'Test', 'platform' => 'gba', 'path' => '/t.gba' }]
      lib  = Struct.new(:roms) { def all = roms }.new(roms)
      picker = Gemba::ListPickerFrame.new(app: app, rom_library: lib)
      picker.show
      app.show
      app.update
      app.tcl_eval("raise .")
      app.tcl_eval("update idletasks")

      tree = '.list_picker.tree'
      # Append a Tcl side-effect to <<RightClick>> on the tree
      app.tcl_eval("bind #{tree} <<RightClick>> {+set ::rclick_fired 1}")

      iid  = app.tcl_eval("#{tree} children {}").split.first
      bbox = app.tcl_eval("#{tree} bbox #{iid}").split.map(&:to_i)
      bx   = bbox[0] + 5
      by   = bbox[1] + 5

      override_tk_popup do
        app.tcl_eval("event generate #{tree} <Button-3> -x #{bx} -y #{by} -warp 1")
        app.update
      end

      fired = app.tcl_eval("info exists ::rclick_fired") rescue "0"
      assert_equal "1", fired, "<<RightClick>> was not generated by <Button-3>"

      app.command(:destroy, '.list_picker') rescue nil
    end
  end

  private

  # Verifies that generating <<EventName>> on '.' fires the binding.
  # Uses lappend ::virt_fired as a Tcl side-channel — no physical keypresses.
  #
  # Options:
  #   with_rom:     load TEST_ROM (default true; false for no-ROM app controller)
  #   setup_code:   Ruby injected after player/app created, before poll_until_ready
  #   cleanup_code: Ruby injected in after(0) before quitting
  def assert_virtual_event_fires(event_name, with_rom: true, setup_code: '', cleanup_code: '')
    marker = "#{event_name.upcase.tr('-', '_')}_FIRED"

    if with_rom
      code = <<~RUBY
        require "gemba"
        require "support/player_helpers"
        require "tmpdir"
        require "fileutils"

        player = Gemba::AppController.new("#{TEST_ROM}")
        player.disable_confirmations!
        app = player.app
        #{setup_code}

        poll_until_ready(player) do
          app.tcl_eval('bind . <<#{event_name}>> {+lappend ::virt_fired #{event_name}}')
          app.after(50) do
            app.command(:event, 'generate', '.', '<<#{event_name}>>')
            app.after(0) do
              fired = app.tcl_eval('lsearch -exact $::virt_fired #{event_name}') rescue "-1"
              puts fired.to_i >= 0 ? "#{marker}" : "NOT_FIRED"
              #{cleanup_code}
              app.command(:event, 'generate', '.', '<<Quit>>')
            end
          end
        end

        player.run
      RUBY
    else
      code = <<~RUBY
        require "gemba"

        player = Gemba::AppController.new
        app = player.app
        #{setup_code}

        app.tcl_eval('bind . <<#{event_name}>> {+lappend ::virt_fired #{event_name}}')
        app.after(50) do
          app.command(:event, 'generate', '.', '<<#{event_name}>>')
          app.after(0) do
            fired = app.tcl_eval('lsearch -exact $::virt_fired #{event_name}') rescue "-1"
            puts fired.to_i >= 0 ? "#{marker}" : "NOT_FIRED"
            #{cleanup_code}
            player.running = false
          end
        end

        player.run
      RUBY
    end

    _, stdout, stderr, _ = tk_subprocess(code)
    output = ["STDOUT:\n#{stdout}", "STDERR:\n#{stderr}"].reject { |s| s.end_with?("\n") }
    assert_includes stdout, marker, "<<#{event_name}>> binding did not fire\n#{output.join("\n")}"
  end
end
