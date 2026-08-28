require "../spec_helper"

private def build(title : String) : {Tryst::App, Gemba::SettingsWindow, Gemba::Events}
  session = Tryst::UI::Session.new(title: title)
  handle = session.window(:gemba_settings, title: "Settings", modal: true)
  app = session.run_async.app
  events = Gemba::Events.new
  hotkeys = Gemba::HotkeyMap.new
  window = Gemba::SettingsWindow.new(app, handle, events, hotkeys)
  {app, window, events}
end

describe Gemba::SettingsWindow do
  it "#load_from_config pushes every setting into its control" do
    app, window, _events = build("settings_window_spec_1")
    config = Gemba::Config.new(File.tempname("settings_window_spec", ".json"))
    config.scale = 2
    config.pixel_filter = "linear"
    config.keep_aspect_ratio = false
    config.integer_scale = true
    config.color_correction = true
    config.frame_blending = true
    config.volume = 42
    config.muted = true

    window.load_from_config(config)

    window.scale_control.selected.should eq "2x"
    window.filter_control.selected.should eq "Bilinear"
    window.aspect_switch.value.should be_false
    window.integer_scale_switch.value.should be_true
    window.color_correction_switch.value.should be_true
    window.frame_blending_switch.value.should be_true
    window.volume_slider.value.should eq 42.0
    window.mute_switch.value.should be_true

    app.destroy
  end

  it "moving the scale control emits Events#scale_changed" do
    app, window, events = build("settings_window_spec_2")
    seen = [] of Int32
    events.scale_changed.connect { |scale| seen << scale }

    app.interp.simulate_event(window.scale_control.path, "<Left>") # 3x -> 2x

    seen.should eq [2]
    app.destroy
  end

  it "moving the filter control emits Events#filter_changed" do
    app, window, events = build("settings_window_spec_3")
    seen = [] of Symbol
    events.filter_changed.connect { |mode| seen << mode }

    app.interp.simulate_event(window.filter_control.path, "<Right>") # Nearest -> Linear

    seen.should eq [:linear]
    app.destroy
  end

  it "toggling the mute switch emits Events#mute_changed" do
    app, window, events = build("settings_window_spec_4")
    seen = [] of Bool
    events.mute_changed.connect { |muted| seen << muted }

    # ttk::notebook only maps the current tab's children, and the Mute
    # switch isn't on it by default - an unmapped widget can't take focus.
    window.select_audio_tab
    app.interp.simulate_event(window.mute_switch.path, "<space>")

    seen.should eq [true]
    app.destroy
  end

  it "adjusting the volume slider emits Events#volume_changed as a 0.0..1.0 fraction" do
    app, window, events = build("settings_window_spec_5")
    seen = [] of Float64
    events.volume_changed.connect { |volume| seen << volume }

    window.select_audio_tab
    app.interp.simulate_event(window.volume_slider.path, "<Left>") # 100 -> 99

    seen.should eq [0.99]
    app.destroy
  end

  it "the Gamepad tab defaults to keyboard mode" do
    app, window, _events = build("settings_window_spec_6")
    window.gamepad_tab.keyboard_mode?.should be_true
    app.destroy
  end

  it "rebinding a GBA button via keyboard emits Events#keyboard_mapping_changed and clears #listening_for" do
    app, window, events = build("settings_window_spec_7")
    seen = [] of {Gemba::Button, String}
    events.keyboard_mapping_changed.connect { |btn, keysym| seen << {btn, keysym} }

    window.select_gamepad_tab
    window.gamepad_tab.start_listening(Gemba::Button::A)
    app.interp.simulate_event(window.gamepad_tab.path, "<KeyPress-z>", keysym: "z")

    seen.should eq [{Gemba::Button::A, "z"}]
    window.gamepad_tab.listening_for.should be_nil
    app.destroy
  end
end
