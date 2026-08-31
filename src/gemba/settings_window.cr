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
require "./settings/achievements_tab"

module Gemba
  # A settings modal, live-wired to Gemba::Events and persisted via
  # Gemba::Config - deliberately reaches past plain ttk: Tryst::Switch
  # for every boolean, Tryst::SegmentedControl for the small
  # mutually-exclusive choices (scale, filter mode), and
  # Tryst::ValueSlider for volume.
  #
  # The notebook/tab/row/label scaffolding is built through the
  # Tryst::UI DSL (Session#add, targeting the :gemba_settings window
  # MainWindow already declared) rather than raw @app.command("ttk::...")
  # calls. Switch/SegmentedControl/ValueSlider still can't be DSL nodes
  # themselves - they have no registered Tryst::UI::WidgetType, and need
  # a concrete Tryst::App rather than the DSL's own AppContract - so
  # they're constructed directly against @app once the DSL block
  # realizes, parented at whichever row's Handle#path it just produced.
  #
  # General, Video, Audio, Gameplay, Gamepad, and Achievements tabs
  # exist - the subset of ruby's own SettingsWindow this port has a live
  # feature behind; add a tab once the feature it configures exists.
  # (Ruby has no General tab and files its pause-on-focus-loss switch
  # under Video instead; the setting isn't about video, so it moved.)
  #
  # Gamepad and Achievements are complex enough (rebind capture /
  # credential state) to warrant their own classes - Settings::GamepadTab
  # and Settings::AchievementsTab, each doing its OWN Session#add against
  # the shared notebook (see #initialize) rather than being inlined here.
  class SettingsWindow
    # Public getters onto the real controls - a caller (a spec included)
    # reads/drives the same widgets #load_from_config itself writes,
    # rather than reaching into private state.
    getter pause_on_focus_loss_switch : Tryst::Switch
    getter screenshot_scale_control : Tryst::SegmentedControl
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
    getter achievements_tab : Settings::AchievementsTab

    # Presets the Rewind Buffer segmented control offers - Config's own
    # #rewind_seconds allows anything in 5..30, but the control only
    # ever writes one of these back.
    REWIND_OPTIONS = [5, 10, 20, 30]

    @notebook : String
    @general_tab : String
    @video_tab : String
    @audio_tab : String
    @gameplay_tab : String

    def initialize(@app : Tryst::App, @handle : Tryst::UI::Handle, @events : Events, @hotkeys : HotkeyMap,
                   @session : Tryst::UI::Session)
      @path = @handle.path

      # Bold button style for a customized (non-default) rebind, shared
      # by GamepadTab's own button styling. `font actual` resolves the
      # default font's concrete -family/-size/... pairs; appending
      # -weight bold to that list is a complete font spec.
      default_font = @app.tcl_invoke("font", "actual", "TkDefaultFont")
      @app.style.configure("Bold.TButton", font: "#{default_font} -weight bold")

      # Session#add's block builds the WHOLE new subtree first (no Tk
      # calls yet - realize happens once the block returns), so a node's
      # Handle#path isn't valid until AFTER #add itself returns. These
      # locals capture each Handle #add hands back; reading their #path
      # right after #add (not inside the block) is what makes that safe.
      # Nilable rather than a single unconditional assignment #add's
      # block is trusted to make, so a raised exception mid-build fails
      # with a catchable NilAssertionError below instead of undefined
      # behavior from reading an uninitialized reference.
      notebook_handle = nil
      general_tab_handle = nil
      screenshot_scale_row_handle = nil
      video_tab_handle = nil
      scale_row_handle = nil
      filter_row_handle = nil
      audio_tab_handle = nil
      gameplay_tab_handle = nil
      rewind_row_handle = nil

      @session.add(@handle) do |session|
        # The 12px margin around the notebook is the window's own pad:
        # (declared in MainWindow) - a notebook has no packed children to
        # space, so pad: on it is rejected at validation.
        notebook_handle = session.tabs do |notebook|
          general_tab_handle = notebook.tab(Locale.translate("settings.general"), :general_tab, pad: 12) do |tab|
            screenshot_scale_row_handle = tab.row(:screenshot_scale_row, gap: 8) do |row|
              row.label(text: Locale.translate("settings.screenshot_scale"))
            end
          end

          video_tab_handle = notebook.tab(Locale.translate("settings.video"), :video_tab, pad: 12) do |tab|
            scale_row_handle = tab.row(:scale_row, gap: 8) { |row| row.label(text: Locale.translate("settings.window_scale")) }
            filter_row_handle = tab.row(:filter_row, gap: 8) { |row| row.label(text: Locale.translate("settings.pixel_filter")) }
          end

          audio_tab_handle = notebook.tab(Locale.translate("settings.audio"), :audio_tab, pad: 12)

          gameplay_tab_handle = notebook.tab(Locale.translate("settings.gameplay"), :gameplay_tab, pad: 12) do |tab|
            rewind_row_handle = tab.row(:rewind_row, gap: 8) { |row| row.label(text: Locale.translate("settings.rewind_buffer")) }
          end
        end
      end

      notebook = realized!(notebook_handle, "notebook")
      @notebook = notebook.path
      general = @general_tab = realized!(general_tab_handle, "general_tab").path
      video = @video_tab = realized!(video_tab_handle, "video_tab").path
      audio = @audio_tab = realized!(audio_tab_handle, "audio_tab").path
      @gameplay_tab = realized!(gameplay_tab_handle, "gameplay_tab").path
      screenshot_scale_row_handle = realized!(screenshot_scale_row_handle, "screenshot_scale_row")
      scale_row_handle = realized!(scale_row_handle, "scale_row")
      filter_row_handle = realized!(filter_row_handle, "filter_row")
      rewind_row_handle = realized!(rewind_row_handle, "rewind_row")

      # -- General tab --
      # Packed after the DSL row above (already arranged as part of
      # #add's own realize) rather than before it, unlike the switch's
      # old raw-command position - a purely cosmetic reordering, nothing
      # here depends on which one visually sits on top.
      # animate_set: false on every switch/segmented control in this
      # window. #load_from_config pushes the saved config into all of
      # them during MainWindow#initialize, and each animated set arms a
      # 16ms tween - sliding controls in a window that isn't on screen
      # yet, before the event loop has even started. A user toggle still
      # animates; only the config-driven set jumps.
      @pause_on_focus_loss_switch = Tryst::Switch.new(@app, animate_set: false,
        text: Locale.translate("settings.pause_on_focus_loss"), parent: general)
      @pause_on_focus_loss_switch.pack(anchor: :w, pady: 8)
      @pause_on_focus_loss_switch.on_action { |v| @events.pause_on_focus_loss_changed.emit(v) }

      @screenshot_scale_control = Tryst::SegmentedControl.new(@app, options: ["1x", "2x", "3x", "4x"],
        selected: "2x", animate_set: false, parent: screenshot_scale_row_handle.path)
      @screenshot_scale_control.pack(side: :right)
      @screenshot_scale_control.on_action { |value| @events.screenshot_scale_changed.emit(value.rstrip('x').to_i) }

      # -- Video tab --
      @scale_control = Tryst::SegmentedControl.new(@app, options: ["1x", "2x", "3x", "4x"],
        selected: "3x", animate_set: false, parent: scale_row_handle.path)
      @scale_control.pack(side: :right)
      @scale_control.on_action { |value| @events.scale_changed.emit(value.rstrip('x').to_i) }

      nearest_label = Locale.translate("settings.filter_nearest")
      linear_label = Locale.translate("settings.filter_linear")
      @filter_control = Tryst::SegmentedControl.new(@app, options: [nearest_label, linear_label],
        animate_set: false, parent: filter_row_handle.path)
      @filter_control.pack(side: :right)
      @filter_control.on_action { |value| @events.filter_changed.emit(value == nearest_label ? :nearest : :linear) }

      @aspect_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.maintain_aspect"),
        animate_set: false, parent: video)
      @aspect_switch.pack(anchor: :w, pady: 8)
      @aspect_switch.on_action { |v| @events.aspect_ratio_changed.emit(v) }

      @integer_scale_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.integer_scale"),
        animate_set: false, parent: video)
      @integer_scale_switch.pack(anchor: :w, pady: 8)
      @integer_scale_switch.on_action { |v| @events.integer_scale_changed.emit(v) }

      @color_correction_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.color_correction"),
        animate_set: false, parent: video)
      @color_correction_switch.pack(anchor: :w, pady: 8)
      @color_correction_switch.on_action { |v| @events.color_correction_changed.emit(v) }

      @frame_blending_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.frame_blending"),
        animate_set: false, parent: video)
      @frame_blending_switch.pack(anchor: :w, pady: 8)
      @frame_blending_switch.on_action { |v| @events.frame_blending_changed.emit(v) }

      # -- Audio tab --
      @volume_slider = Tryst::ValueSlider.new(@app, min: 0.0, max: 100.0, step: 1.0,
        value: 100.0, parent: audio)
      @volume_slider.pack(fill: "x", pady: 8)
      @volume_slider.on_change { |v| @events.volume_changed.emit(v / 100.0) }

      @mute_switch = Tryst::Switch.new(@app, text: Locale.translate("settings.mute"),
        animate_set: false, parent: audio)
      @mute_switch.pack(anchor: :w, pady: 8)
      @mute_switch.on_action { |v| @events.mute_changed.emit(v) }

      # -- Gameplay tab --
      @rewind_buffer_control = Tryst::SegmentedControl.new(@app, options: REWIND_OPTIONS.map { |seconds| "#{seconds}s" },
        selected: "#{Config::DEFAULT_REWIND_SECONDS}s", animate_set: false, parent: rewind_row_handle.path)
      @rewind_buffer_control.pack(side: :right)
      @rewind_buffer_control.on_action { |value| @events.rewind_seconds_changed.emit(value.rstrip('s').to_i) }

      # -- Gamepad tab --
      @gamepad_tab = Settings::GamepadTab.new(@app, @session, notebook, @path, @events,
        validate_keyboard_mapping: ->(keysym : String) { validate_kb_mapping(keysym) })

      # -- Achievements tab --
      @achievements_tab = Settings::AchievementsTab.new(@app, @session, notebook, @path, @events)
    end

    def handle : Tryst::UI::Handle
      @handle
    end

    # The Settings menu has one item per tab rather than a single
    # "Settings…" - each opens this window already on the tab it names.
    # An unknown symbol leaves whichever tab is current selected.
    def select_tab(tab : Symbol) : Nil
      case tab
      when :general      then select_general_tab
      when :video        then select_video_tab
      when :audio        then select_audio_tab
      when :gameplay     then select_gameplay_tab
      when :gamepad      then select_gamepad_tab
      when :achievements then select_achievements_tab
      end
    end

    # The inverse of #select_tab - nil for a tab this doesn't know about.
    def selected_tab : Symbol?
      case @app.command(@notebook, :select)
      when @general_tab           then :general
      when @video_tab             then :video
      when @audio_tab             then :audio
      when @gameplay_tab          then :gameplay
      when @gamepad_tab.path      then :gamepad
      when @achievements_tab.path then :achievements
      end
    end

    # Unmapped tabs aren't viewable until selected (a Tk requirement),
    # so select first before accessing controls on them.
    def select_general_tab : Nil
      @app.command(@notebook, :select, @general_tab)
    end

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

    def select_achievements_tab : Nil
      @app.command(@notebook, :select, @achievements_tab.path)
    end

    # Pushes the current Config into every control - call before showing
    # the window (mirrors ruby's own :config_loaded bus event).
    def load_from_config(config : Config) : Nil
      @pause_on_focus_loss_switch.value = config.pause_on_focus_loss?
      @screenshot_scale_control.selected = "#{config.screenshot_scale}x"
      @scale_control.selected = "#{config.scale}x"
      @filter_control.selected = filter_label(config.pixel_filter)
      @aspect_switch.value = config.keep_aspect_ratio?
      @integer_scale_switch.value = config.integer_scale?
      @color_correction_switch.value = config.color_correction?
      @frame_blending_switch.value = config.frame_blending?
      @volume_slider.value = config.volume.to_f64
      @mute_switch.value = config.muted?
      @rewind_buffer_control.selected = "#{nearest_rewind_option(config.rewind_seconds)}s"
      @achievements_tab.load_from_config(config)
    end

    # Rejects a keyboard rebind that would shadow an existing hotkey -
    # nil means no conflict.
    private def validate_kb_mapping(keysym : String) : String?
      action = @hotkeys.action_for(keysym)
      return unless action

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

    # #add's block builds the whole subtree before anything realizes
    # (see #initialize's own comment on this), so every Handle it hands
    # back is genuinely always assigned by the time this runs - a raise
    # here means a bug in that build block, not a legitimate nil case.
    private def realized!(handle : Tryst::UI::Handle?, what : String) : Tryst::UI::Handle
      handle || raise "SettingsWindow's #{what} wasn't realized by Session#add - this is a bug in its own build block"
    end
  end
end
