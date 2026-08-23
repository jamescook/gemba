require "tryst"
require "tryst/ui"
require "tryst-switch"
require "tryst-segmented"
require "tryst-value-slider"
require "./config"
require "./events"
require "./locale"

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
  # Only two tabs (Video, Audio) exist - the subset of ruby's own
  # SettingsWindow this port has a live feature behind; add a tab once
  # the feature it configures exists.
  #
  # Every tab is built directly in #initialize rather than split into
  # per-tab helper methods: each control ivar is only assigned partway
  # through, and Crystal bans any instance-method call on self until
  # every declared ivar has been assigned at least once (see
  # MainWindow's own comment on this exact constraint).
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

    @video_tab : String
    @audio_tab : String

    def initialize(@app : Tryst::App, @handle : Tryst::UI::Handle, @events : Events)
      @path = @handle.path
      @notebook = "#{@path}.nb"
      @app.command("ttk::notebook", @notebook)
      @app.command(:pack, @notebook, fill: :both, expand: 1, padx: 12, pady: 12)

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
    end

    private def filter_label(filter : String) : String
      filter == "nearest" ? Locale.translate("settings.filter_nearest") : Locale.translate("settings.filter_linear")
    end
  end
end
