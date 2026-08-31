require "../spec_helper"

private record Built, app : Tryst::App, window : Gemba::HelpWindow, hotkeys : Gemba::HotkeyMap

private def with_window(title : String, &)
  hotkeys = Gemba::HotkeyMap.new
  session = Tryst::UI::Session.new(title: title)
  window = Gemba::HelpWindow.new(session, hotkeys)
  app = session.run_async.app
  begin
    yield Built.new(app, window, hotkeys)
  ensure
    app.destroy
  end
end

describe Gemba::HelpWindow do
  it "lists every action with the HotkeyMap's current binding, re-read on each show" do
    with_window("help_window_spec_1") do |built|
      built.window.show

      built.window.key_text(:quick_save).should eq "F5"
      built.window.key_text(:rewind).should eq "Shift+Tab"
      built.window.key_text(:open_rom).should eq "Ctrl+O"
      Gemba::HotkeyMap::ACTIONS.each { |action| built.window.key_text(action).should_not be_empty }

      # A rebind (however it happens) is picked up on the next open,
      # with no notification from the map.
      # (HotkeyMap.display_name leaves a bare key as-is and only
      # capitalises the key of a combo.)
      built.hotkeys.set(:pause, ["Control", "Shift", "p"])
      built.window.key_text(:pause).should eq "p"
      built.window.hide
      built.window.show
      built.window.key_text(:pause).should eq "Ctrl+Shift+P"
      built.window.key_text(:quit).should eq "q"
    end
  end

  it "starts hidden, shows and hides, and the WM close button reaches #on_close" do
    with_window("help_window_spec_2") do |built|
      closed = 0
      built.window.on_close { closed += 1 }
      built.window.visible?.should be_false

      # A non-modal window's deiconify only settles into `wm state
      # normal` once the event loop has run - under Xvfb (no window
      # manager) it read "withdrawn" straight after #show. A modal's
      # grab/focus forces the map synchronously, which is why
      # RomInfoWindow's spec gets away without this.
      built.window.show
      built.app.update
      built.window.visible?.should be_true
      # Non-modal: nothing grabbed.
      built.app.tcl_invoke("grab", "current").should eq ""

      built.window.hide
      built.window.visible?.should be_false

      built.window.show
      built.app.tcl_eval("eval [wm protocol #{built.window.handle.path} WM_DELETE_WINDOW]")
      closed.should eq 1
    end
  end
end
