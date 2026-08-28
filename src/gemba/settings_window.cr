require "tryst"
require "tryst/ui"
require "tryst-switch"
require "tryst-segmented"
require "tryst-value-slider"
require "./config"
require "./events"
require "./locale"
require "./hotkey_map"
require "./settings/gamepad_tab"

module Gemba
  # A settings modal, live-wired to Gemba::Events and persisted via
  # Gemba::Config - deliberately reaches past plain ttk: Tryst::Switch
  # for every boolean, Tryst::SegmentedControl for the small
  # mutually-exclusive choices (scale, filter mode), and
  # Tryst::ValueSlider for volume.
  #
  # Its contents are built with raw App calls, not the Tryst::UI DSL's
  # grid/tabs builders: Switch/SegmentedControl/ValueSlider all require
  # a concrete Tryst::App, not the DSL's narrow AppContract.
  #
  # Video, Audio, Gameplay, and Gamepad tabs exist - the subset of
  # ruby's own SettingsWindow this port has a live feature behind; add a
  # tab once the feature it configures exists.
  #
  # Video/Audio/Gameplay are built directly in #initialize rather than
  # split into per-tab helper methods: each control ivar is only
  # assigned partway through, and Crystal bans any instance-method call
  # on self until every declared ivar has been assigned at least once
  # (see MainWindow's own comment on this exact constraint). Gamepad is
  # complex enough (rebind capture, mode toggle, dead zone) to warrant
  # its own class - Settings::GamepadTab, constructed only once its own
  # ivars are ready, same as ruby's own tab split.
  class SettingsWindow
    # Public getters onto the real controls - a caller (a spec included)
    # reads/drives the same widgets #load_from_config itself writes,
    # rather than reaching into private state.
    getter scale_control : Tryst::SegmentedControl
    getter filter_control : Tryst::SegmentedControl
    getter aspect_switch : Tryst::Switch
    getter integer_scale_switch : Tryst::Switch
    getter color_correction_switch : Tryst::Switch
    getter frame_blending_switch : Tryst::Switch
    getter volume_slider : Tryst::ValueSlider
    getter mute_switch : Tryst::Switch
    getter rewind_buffer_control : Tryst::SegmentedControl
    getter gamepad_tab : Settings::GamepadTab

    # Presets the Rewind Buffer segmented control offers - Config's own
    # #rewind_seconds allows anything in 5..30, but the control only
    # ever writes one of these back.
    REWIND_OPTIONS = [5, 10, 20, 30]

    @video_tab : String
    @audio_tab : String
    @gameplay_tab : String

    def initialize(@app : Tryst::App, @handle : Tryst::UI::Handle, @events : Events, @hotkeys : HotkeyMap)
      @path = @handle.path
      @notebook = "#{@path}.nb"
      @app.command("ttk::notebook", @notebook)
      @app.command(:pack, @notebook, fill: :both, expand: 1, padx: 12, pady: 12)

      # Bold button style for a customized (non-default) rebind, shared
      # by GamepadTab's own button styling.
      @app.tcl_eval("ttk::style configure Bold.TButton -font [list {*}[font actual TkDefaultFont] -weight bold]")

      # -- Video tab --
      video = @video_tab = "#{@notebook}.video"
      @app.command("ttk::frame", video, padding: 12)
      @app.command(@notebook, :add, video, text: Locale.translate("settings.video"))

      scale_row = "#{video}.scale_row"
      @app.command("ttk::frame", scale_row)
      @app.command(:pack, scale_row, fill: :x, pady: 8)
      @app.command("ttk::label", "#{scale_row}.lbl", text: Locale.translate("settings.window_scale"))
      @app.command(:pack, "#{scale_row}.lbl", side: :left)

      @scale_control = Tryst::SegmentedControl.new(@app, options: ["1x", "2x", "3x", "4x"],
        selected: "3x", parent: scale_row)
      @scale_control.pack(side: :right)
      @scale_control.on_action { |value| @events.scale_changed.emit(value.rstrip('x').to_i) }

      filter_row = "#{video}.filter_row"
      @app.command("ttk::frame", filter_row)
      @app.command(:pack, filter_row, fill: :x, pady: 8)
      @app.command("ttk::label", "#{filter_row}.lbl", text: Locale.translate("settings.pixel_filter"))
      @app.command(:pack, "#{filter_row}.lbl", side: :left)

      nearest_label = Locale.translate("settings.filter_nearest")
      linear_label = Locale.translate("settings.filter_linear")
      @filter_control = Tryst::SegmentedControl.new(@app, options: [nearest_label, linear_label], parent: filter_row)
      @filter_control.pack(side: :right)
      @filter_control.on_action { |value| @events.filter_changed.emit(value == nearest_label ? :nearest : :linear) }

      @aspect_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.maintain_aspect"), parent: video)
      @aspect_switch.pack(anchor: :w, pady: 8)
      @aspect_switch.on_action { |v| @events.aspect_ratio_changed.emit(v) }

      @integer_scale_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.integer_scale"), parent: video)
      @integer_scale_switch.pack(anchor: :w, pady: 8)
      @integer_scale_switch.on_action { |v| @events.integer_scale_changed.emit(v) }

      @color_correction_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.color_correction"), parent: video)
      @color_correction_switch.pack(anchor: :w, pady: 8)
      @color_correction_switch.on_action { |v| @events.color_correction_changed.emit(v) }

      @frame_blending_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.frame_blending"), parent: video)
      @frame_blending_switch.pack(anchor: :w, pady: 8)
      @frame_blending_switch.on_action { |v| @events.frame_blending_changed.emit(v) }

      # -- Audio tab --
      audio = @audio_tab = "#{@notebook}.audio"
      @app.command("ttk::frame", audio, padding: 12)
      @app.command(@notebook, :add, audio, text: Locale.translate("settings.audio"))

      @volume_slider = Tryst::ValueSlider.new(@app, min: 0.0, max: 100.0, step: 1.0,
        value: 100.0, parent: audio)
      @volume_slider.pack(fill: "x", pady: 8)
      @volume_slider.on_change { |v| @events.volume_changed.emit(v / 100.0) }

      @mute_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.mute"), parent: audio)
      @mute_switch.pack(anchor: :w, pady: 8)
      @mute_switch.on_action { |v| @events.mute_changed.emit(v) }

      # -- Gameplay tab --
      gameplay = @gameplay_tab = "#{@notebook}.gameplay"
      @app.command("ttk::frame", gameplay, padding: 12)
      @app.command(@notebook, :add, gameplay, text: Locale.translate("settings.gameplay"))

      rewind_row = "#{gameplay}.rewind_row"
      @app.command("ttk::frame", rewind_row)
      @app.command(:pack, rewind_row, fill: :x, pady: 8)
      @app.command("ttk::label", "#{rewind_row}.lbl", text: Locale.translate("settings.rewind_buffer"))
      @app.command(:pack, "#{rewind_row}.lbl", side: :left)

      @rewind_buffer_control = Tryst::SegmentedControl.new(@app, options: REWIND_OPTIONS.map { |seconds| "#{seconds}s" },
        selected: "#{Config::DEFAULT_REWIND_SECONDS}s", parent: rewind_row)
      @rewind_buffer_control.pack(side: :right)
      @rewind_buffer_control.on_action { |value| @events.rewind_seconds_changed.emit(value.rstrip('s').to_i) }

      # -- Gamepad tab --
      @gamepad_tab = Settings::GamepadTab.new(@app, @notebook, @path, @events,
        validate_keyboard_mapping: ->(keysym : String) { validate_kb_mapping(keysym) })
    end

    def handle : Tryst::UI::Handle
      @handle
    end

    # Unmapped tabs aren't viewable until selected (a Tk requirement),
    # so select first before accessing controls on them.
    def select_video_tab : Nil
      @app.command(@notebook, :select, @video_tab)
    end

    def select_audio_tab : Nil
      @app.command(@notebook, :select, @audio_tab)
    end

    def select_gameplay_tab : Nil
      @app.command(@notebook, :select, @gameplay_tab)
    end

    def select_gamepad_tab : Nil
      @app.command(@notebook, :select, @gamepad_tab.path)
    end

    # Pushes the current Config into every control - call before showing
    # the window (mirrors ruby's own :config_loaded bus event).
    def load_from_config(config : Config) : Nil
      @scale_control.selected = "#{config.scale}x"
      @filter_control.selected = filter_label(config.pixel_filter)
      @aspect_switch.value = config.keep_aspect_ratio?
      @integer_scale_switch.value = config.integer_scale?
      @color_correction_switch.value = config.color_correction?
      @frame_blending_switch.value = config.frame_blending?
      @volume_slider.value = config.volume.to_f64
      @mute_switch.value = config.muted?
      @rewind_buffer_control.selected = "#{nearest_rewind_option(config.rewind_seconds)}s"
    end

    # Rejects a keyboard rebind that would shadow an existing hotkey -
    # nil means no conflict.
    private def validate_kb_mapping(keysym : String) : String?
      action = @hotkeys.action_for(keysym)
      return nil unless action

      label = action.to_s.gsub('_', ' ').capitalize
      %("#{keysym}" is assigned to hotkey: #{label})
    end

    private def filter_label(filter : String) : String
      filter == "nearest" ? Locale.translate("settings.filter_nearest") : Locale.translate("settings.filter_linear")
    end

    # Snaps a saved Config#rewind_seconds (5..30, not necessarily one of
    # REWIND_OPTIONS - e.g. a settings.json hand-edited outside the UI)
    # to the closest preset the control can actually display.
    private def nearest_rewind_option(seconds : Int32) : Int32
      REWIND_OPTIONS.min_by { |option| (option - seconds).abs }
    end
  end
end
