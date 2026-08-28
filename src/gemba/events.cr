require "tryst/ui"
require "./button"

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

    # General tab.
    getter pause_on_focus_loss_changed = Tryst::UI::Signal(Bool).new

    # Gameplay tab - MainWindow persists it, but it only reaches Core at
    # the NEXT rom load (see EmulationWorker's own doc comment).
    getter rewind_seconds_changed = Tryst::UI::Signal(Int32).new

    # Gamepad tab - gamepad_mapping_changed's input name arrives as a
    # String (same as keyboard_mapping_changed's keysym) rather than the
    # Symbol GamepadMap#set otherwise takes, so GamepadTab's own capture
    # path stays uniform regardless of which device mode is active; see
    # GamepadMap#set's String overload.
    getter keyboard_mapping_changed = Tryst::UI::Signal(Button, String).new
    getter gamepad_mapping_changed = Tryst::UI::Signal(Button, String).new
    getter gamepad_dead_zone_changed = Tryst::UI::Signal(Int32).new
    getter keyboard_reset = Tryst::UI::Signal().new
    getter gamepad_reset = Tryst::UI::Signal().new

    # true = keyboard mode, false = gamepad mode - which map Undo should
    # discard in-progress rebinds for.
    getter undo_input_mappings = Tryst::UI::Signal(Bool).new

    # Fired when the tab's keyboard/gamepad combo changes, so a listener
    # can refresh the tab's displayed labels from the newly-active map's
    # real saved state (GamepadTab has no reference to either map itself).
    getter input_mode_changed = Tryst::UI::Signal(Bool).new

    # Fired once the settings window is about to show, so it can
    # populate its controls from the current Config without every
    # control needing its own separate "initial value" plumbing.
    getter config_loaded = Tryst::UI::Signal(Config).new

    # rom_title: the display title (e.g. "Pokemon FireRed"), for the
    # window title bar and ROM Info panel to react to independently.
    getter rom_loaded = Tryst::UI::Signal(String).new

    # Achievements tab - persisted booleans go straight to Config like
    # every other tab; the login/verify/logout/reset actions have no
    # backend to reach yet (rcheevos isn't vendored), so a listener is
    # deferred to when that lands.
    getter ra_enabled_changed = Tryst::UI::Signal(Bool).new
    getter ra_rich_presence_changed = Tryst::UI::Signal(Bool).new
    getter ra_screenshot_on_unlock_changed = Tryst::UI::Signal(Bool).new
    getter ra_login_requested = Tryst::UI::Signal(String, String).new
    getter ra_verify_requested = Tryst::UI::Signal().new
    getter ra_logout_requested = Tryst::UI::Signal().new
    getter ra_reset_requested = Tryst::UI::Signal().new
  end
end
