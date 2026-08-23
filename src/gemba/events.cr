require "tryst/ui"

module Gemba
  # One Tryst::UI::Signal per event, not a generic Symbol-keyed bus - a
  # typo'd Signal name is a compile error, a typo'd Symbol key on a bus
  # is a silent no-op. Gemba::Events is the holder class Signal's own
  # doc comment recommends for an app with several.
  class Events
    getter scale_changed = Tryst::UI::Signal(Int32).new
    getter volume_changed = Tryst::UI::Signal(Float64).new
    getter mute_changed = Tryst::UI::Signal(Bool).new
    getter filter_changed = Tryst::UI::Signal(Symbol).new
    getter integer_scale_changed = Tryst::UI::Signal(Bool).new
    getter color_correction_changed = Tryst::UI::Signal(Bool).new
    getter frame_blending_changed = Tryst::UI::Signal(Bool).new
    getter aspect_ratio_changed = Tryst::UI::Signal(Bool).new

    # Fired once the settings window is about to show, so it can
    # populate its controls from the current Config without every
    # control needing its own separate "initial value" plumbing.
    getter config_loaded = Tryst::UI::Signal(Config).new

    # rom_title: the display title (e.g. "Pokemon FireRed"), for the
    # window title bar and ROM Info panel to react to independently.
    getter rom_loaded = Tryst::UI::Signal(String).new
  end
end
