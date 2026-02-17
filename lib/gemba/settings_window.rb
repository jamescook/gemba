# frozen_string_literal: true

require_relative "child_window"
require_relative "hotkey_map"
require_relative "locale"
require_relative "tip_service"
require_relative "settings/paths"
require_relative "settings/audio_tab"
require_relative "settings/video_tab"
require_relative "settings/recording_tab"
require_relative "settings/save_states_tab"
require_relative "settings/gamepad_tab"

module Gemba
  # Settings window for the mGBA Player.
  #
  # Opens a Toplevel with a ttk::notebook containing Video, Audio, and
  # Gamepad tabs. Closing the window hides it (withdraw) rather than
  # destroying it.
  #
  # Widget paths and Tcl variable names are exposed as constants so tests
  # can interact with the UI the same way a user would (set variable,
  # generate event, assert result).
  class SettingsWindow
    include ChildWindow
    include Locale::Translatable

    TOP = Settings::Paths::TOP
    NB  = Settings::Paths::NB

    # Video tab widget paths (re-exported from Settings::VideoTab)
    SCALE_COMBO            = Settings::VideoTab::SCALE_COMBO
    TURBO_COMBO            = Settings::VideoTab::TURBO_COMBO
    ASPECT_CHECK           = Settings::VideoTab::ASPECT_CHECK
    SHOW_FPS_CHECK         = Settings::VideoTab::SHOW_FPS_CHECK
    TOAST_COMBO            = Settings::VideoTab::TOAST_COMBO
    FILTER_COMBO           = Settings::VideoTab::FILTER_COMBO
    INTEGER_SCALE_CHECK    = Settings::VideoTab::INTEGER_SCALE_CHECK
    COLOR_CORRECTION_CHECK = Settings::VideoTab::COLOR_CORRECTION_CHECK
    FRAME_BLENDING_CHECK   = Settings::VideoTab::FRAME_BLENDING_CHECK
    REWIND_CHECK           = Settings::VideoTab::REWIND_CHECK
    VOLUME_SCALE = Settings::AudioTab::VOLUME_SCALE
    MUTE_CHECK   = Settings::AudioTab::MUTE_CHECK

    # Gamepad tab widget paths (re-exported from Settings::GamepadTab)
    GAMEPAD_TAB    = Settings::GamepadTab::FRAME
    GAMEPAD_COMBO  = Settings::GamepadTab::GAMEPAD_COMBO
    DEADZONE_SCALE = Settings::GamepadTab::DEADZONE_SCALE
    GP_RESET_BTN   = Settings::GamepadTab::RESET_BTN
    GP_UNDO_BTN    = Settings::GamepadTab::UNDO_BTN

    GP_BTN_A      = Settings::GamepadTab::BTN_A
    GP_BTN_B      = Settings::GamepadTab::BTN_B
    GP_BTN_L      = Settings::GamepadTab::BTN_L
    GP_BTN_R      = Settings::GamepadTab::BTN_R
    GP_BTN_UP     = Settings::GamepadTab::BTN_UP
    GP_BTN_DOWN   = Settings::GamepadTab::BTN_DOWN
    GP_BTN_LEFT   = Settings::GamepadTab::BTN_LEFT
    GP_BTN_RIGHT  = Settings::GamepadTab::BTN_RIGHT
    GP_BTN_START  = Settings::GamepadTab::BTN_START
    GP_BTN_SELECT = Settings::GamepadTab::BTN_SELECT

    # Hotkeys tab widget paths
    HK_TAB         = "#{NB}.hotkeys"
    HK_UNDO_BTN    = "#{HK_TAB}.btn_bar.undo_btn"
    HK_RESET_BTN   = "#{HK_TAB}.btn_bar.reset_btn"

    # Action → widget path mapping for hotkey buttons
    HK_ACTIONS = {
      quit:        "#{HK_TAB}.row_quit.btn",
      pause:       "#{HK_TAB}.row_pause.btn",
      fast_forward: "#{HK_TAB}.row_fast_forward.btn",
      fullscreen:  "#{HK_TAB}.row_fullscreen.btn",
      show_fps:    "#{HK_TAB}.row_show_fps.btn",
      quick_save:  "#{HK_TAB}.row_quick_save.btn",
      quick_load:  "#{HK_TAB}.row_quick_load.btn",
      save_states: "#{HK_TAB}.row_save_states.btn",
      screenshot:  "#{HK_TAB}.row_screenshot.btn",
      rewind:      "#{HK_TAB}.row_rewind.btn",
      record:      "#{HK_TAB}.row_record.btn",
    }.freeze

    # Action → locale key mapping
    HK_LOCALE_KEYS = {
      quit: 'settings.hk_quit', pause: 'settings.hk_pause',
      fast_forward: 'settings.hk_fast_forward', fullscreen: 'settings.hk_fullscreen',
      show_fps: 'settings.hk_show_fps', quick_save: 'settings.hk_quick_save',
      quick_load: 'settings.hk_quick_load', save_states: 'settings.hk_save_states',
      screenshot: 'settings.hk_screenshot',
      rewind: 'settings.hk_rewind',
      record: 'settings.hk_record',
    }.freeze

    # GBA button → locale key mapping (re-exported from Settings::GamepadTab)
    GP_LOCALE_KEYS = Settings::GamepadTab::LOCALE_KEYS

    # Per-game settings bar (above notebook, shown/hidden based on active tab)
    PER_GAME_BAR   = "#{TOP}.per_game_bar"
    PER_GAME_CHECK = "#{PER_GAME_BAR}.check"

    # Recording tab widget paths (re-exported from Settings::RecordingTab)
    REC_TAB               = Settings::RecordingTab::FRAME
    REC_COMPRESSION_COMBO = Settings::RecordingTab::COMPRESSION_COMBO
    REC_OPEN_DIR_BTN      = Settings::RecordingTab::OPEN_DIR_BTN

    # Save States tab widget paths (re-exported from Settings::SaveStatesTab)
    SS_TAB          = Settings::SaveStatesTab::FRAME
    SS_SLOT_COMBO   = Settings::SaveStatesTab::SLOT_COMBO
    SS_BACKUP_CHECK = Settings::SaveStatesTab::BACKUP_CHECK
    SS_OPEN_DIR_BTN = Settings::SaveStatesTab::OPEN_DIR_BTN

    # Bottom bar
    SAVE_BTN = "#{TOP}.save_btn"

    # Tcl variable names
    VAR_PER_GAME = '::mgba_per_game'
    VAR_SCALE            = Settings::VideoTab::VAR_SCALE
    VAR_TURBO            = Settings::VideoTab::VAR_TURBO
    VAR_VOLUME           = Settings::AudioTab::VAR_VOLUME
    VAR_MUTE             = Settings::AudioTab::VAR_MUTE
    VAR_GAMEPAD          = Settings::GamepadTab::VAR_GAMEPAD
    VAR_DEADZONE         = Settings::GamepadTab::VAR_DEADZONE
    VAR_ASPECT_RATIO     = Settings::VideoTab::VAR_ASPECT_RATIO
    VAR_SHOW_FPS         = Settings::VideoTab::VAR_SHOW_FPS
    VAR_TOAST_DURATION   = Settings::VideoTab::VAR_TOAST_DURATION
    VAR_FILTER           = Settings::VideoTab::VAR_FILTER
    VAR_INTEGER_SCALE    = Settings::VideoTab::VAR_INTEGER_SCALE
    VAR_COLOR_CORRECTION = Settings::VideoTab::VAR_COLOR_CORRECTION
    VAR_FRAME_BLENDING   = Settings::VideoTab::VAR_FRAME_BLENDING
    VAR_REWIND_ENABLED   = Settings::VideoTab::VAR_REWIND_ENABLED
    VAR_QUICK_SLOT       = Settings::SaveStatesTab::VAR_QUICK_SLOT
    VAR_SS_BACKUP        = Settings::SaveStatesTab::VAR_BACKUP
    VAR_REC_COMPRESSION  = Settings::RecordingTab::VAR_COMPRESSION
    VAR_PAUSE_FOCUS      = Settings::VideoTab::VAR_PAUSE_FOCUS

    # GBA button → widget path mapping (re-exported from Settings::GamepadTab)
    GBA_BUTTONS       = Settings::GamepadTab::GBA_BUTTONS
    DEFAULT_GP_LABELS = Settings::GamepadTab::DEFAULT_GP_LABELS
    DEFAULT_KB_LABELS = Settings::GamepadTab::DEFAULT_KB_LABELS

    # @param app [Teek::App]
    # @param callbacks [Hash] :on_scale_change, :on_volume_change, :on_mute_change,
    #   :on_gamepad_map_change, :on_deadzone_change
    CALLBACK_DEFAULTS = {
      on_validate_hotkey:     ->(_) { nil },
      on_validate_kb_mapping: ->(_) { nil },
    }.freeze

    def initialize(app, callbacks: {}, tip_dismiss_ms: TipService::DEFAULT_DISMISS_MS)
      @app = app
      @callbacks = CALLBACK_DEFAULTS.merge(callbacks)
      @tip_dismiss_ms = tip_dismiss_ms
      @per_game_enabled = false
      @hk_listening_for = nil
      @hk_listen_timer = nil
      @hk_labels = HotkeyMap::DEFAULTS.dup
      @hk_pending_modifiers = Set.new
      @hk_mod_timer = nil

      build_toplevel(translate('menu.settings'), geometry: '700x560') { setup_ui }
    end

    # Delegates to GamepadTab
    def listening_for = @gamepad_tab.listening_for
    def keyboard_mode? = @gamepad_tab.keyboard_mode?
    def update_gamepad_list(names) = @gamepad_tab.update_gamepad_list(names)
    def refresh_gamepad(labels, dead_zone) = @gamepad_tab.refresh_gamepad(labels, dead_zone)
    def capture_mapping(button) = @gamepad_tab.capture_mapping(button)

    # @param tab [String, nil] widget path of the tab to select (e.g. SS_TAB)
    def show(tab: nil)
      @app.command(NB, 'select', tab) if tab
      show_window
    end

    # Tab widget paths keyed by locale key (caller uses translate to get display name)
    TABS = {
      'settings.video'       => "#{NB}.video",
      'settings.audio'       => "#{NB}.audio",
      'settings.gamepad'     => GAMEPAD_TAB,
      'settings.hotkeys'     => HK_TAB,
      'settings.recording'   => REC_TAB,
      'settings.save_states' => SS_TAB,
    }.freeze

    # Tabs that show the per-game settings checkbox
    PER_GAME_TABS = Set.new(["#{NB}.video", "#{NB}.audio", SS_TAB]).freeze

    def hide
      @tips&.hide
      hide_window
    end

    # Enable the Save button (called when any setting changes)
    def mark_dirty
      @app.command(SAVE_BTN, 'configure', state: :normal)
    end

    # Enable/disable the per-game checkbox (called when ROM loads/unloads).
    def set_per_game_available(enabled)
      @per_game_enabled = enabled
      current = @app.command(NB, 'select') rescue nil
      if enabled && PER_GAME_TABS.include?(current)
        @app.command(PER_GAME_CHECK, 'configure', state: :normal)
      else
        @app.command(PER_GAME_CHECK, 'configure', state: :disabled)
      end
    end

    # Sync the per-game checkbox to the current config state.
    def set_per_game_active(active)
      @app.set_variable(VAR_PER_GAME, active ? '1' : '0')
    end

    private

    def do_save
      @callbacks[:on_save]&.call
      @app.command(SAVE_BTN, 'configure', state: :disabled)
    end

    def update_per_game_bar
      current = @app.command(NB, 'select')
      if PER_GAME_TABS.include?(current)
        @app.command(PER_GAME_CHECK, 'configure', state: @per_game_enabled ? :normal : :disabled)
      else
        @app.command(PER_GAME_CHECK, 'configure', state: :disabled)
      end
    end

    def setup_ui
      # Bold button style for customized mappings
      @app.tcl_eval("ttk::style configure Bold.TButton -font [list {*}[font actual TkDefaultFont] -weight bold]")

      @tips = TipService.new(@app, parent: TOP, dismiss_ms: @tip_dismiss_ms)

      # Per-game settings bar (above notebook, initially hidden)
      @app.command('ttk::frame', PER_GAME_BAR)
      @app.set_variable(VAR_PER_GAME, '0')
      @app.command('ttk::checkbutton', PER_GAME_CHECK,
        text: translate('settings.per_game'),
        variable: VAR_PER_GAME,
        state: :disabled,
        command: proc { |*|
          enabled = @app.get_variable(VAR_PER_GAME) == '1'
          @callbacks[:on_per_game_toggle]&.call(enabled)
          mark_dirty
        })
      @app.command(:pack, PER_GAME_CHECK, side: :left, padx: 5)

      per_game_tip = "#{PER_GAME_BAR}.tip"
      @app.command('ttk::label', per_game_tip, text: '(?)')
      @app.command(:pack, per_game_tip, side: :left)
      @tips.register(per_game_tip, translate('settings.tip_per_game'))

      @app.command('ttk::notebook', NB)
      @app.command(:pack, NB, fill: :both, expand: 1, padx: 5, pady: [5, 0])

      @video_tab = Settings::VideoTab.new(@app, callbacks: @callbacks, tips: @tips, mark_dirty: method(:mark_dirty))
      @video_tab.build
      @audio_tab = Settings::AudioTab.new(@app, callbacks: @callbacks, tips: @tips, mark_dirty: method(:mark_dirty))
      @audio_tab.build
      @gamepad_tab = Settings::GamepadTab.new(@app, callbacks: @callbacks, tips: @tips,
        mark_dirty: method(:mark_dirty), do_save: method(:do_save),
        show_key_conflict: method(:show_key_conflict))
      @gamepad_tab.build
      setup_hotkeys_tab
      @recording_tab = Settings::RecordingTab.new(@app, callbacks: @callbacks, tips: @tips, mark_dirty: method(:mark_dirty))
      @recording_tab.build
      @save_states_tab = Settings::SaveStatesTab.new(@app, callbacks: @callbacks, tips: @tips, mark_dirty: method(:mark_dirty))
      @save_states_tab.build

      # Show/hide per-game bar based on active tab
      @app.command(:bind, NB, '<<NotebookTabChanged>>', proc { update_per_game_bar })
      # Show bar initially (video tab is default)
      @app.command(:pack, PER_GAME_BAR, fill: :x, padx: 5, pady: [5, 0], before: NB)

      # Save button — disabled until a setting changes
      @app.command('ttk::button', SAVE_BTN, text: translate('settings.save'), state: :disabled,
        command: proc { do_save })
      @app.command(:pack, SAVE_BTN, side: :bottom, pady: [0, 8])
    end


    def setup_hotkeys_tab
      frame = HK_TAB
      @app.command('ttk::frame', frame)
      @app.command(NB, 'add', frame, text: translate('settings.hotkeys'))

      # Scrollable list of action rows
      HK_ACTIONS.each do |action, btn_path|
        row = "#{frame}.row_#{action}"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, padx: 10, pady: 2)

        lbl_path = "#{row}.lbl"
        @app.command('ttk::label', lbl_path, text: translate(HK_LOCALE_KEYS[action]), width: 14, anchor: :w)
        @app.command(:pack, lbl_path, side: :left)

        display = hk_display(action)
        @app.command('ttk::button', btn_path, text: display, width: 12,
          style: hk_customized?(action) ? 'Bold.TButton' : 'TButton',
          command: proc { start_hk_listening(action) })
        @app.command(:pack, btn_path, side: :right)
      end

      # Bottom bar: Undo (left) | Reset to Defaults (right)
      btn_bar = "#{frame}.btn_bar"
      @app.command('ttk::frame', btn_bar)
      @app.command(:pack, btn_bar, fill: :x, side: :bottom, padx: 10, pady: [4, 8])

      @app.command('ttk::button', HK_UNDO_BTN, text: translate('settings.undo'),
        state: :disabled, command: proc { do_undo_hotkeys })
      @app.command(:pack, HK_UNDO_BTN, side: :left)

      @app.command('ttk::button', HK_RESET_BTN, text: translate('settings.hk_reset_defaults'),
        command: proc { confirm_reset_hotkeys })
      @app.command(:pack, HK_RESET_BTN, side: :right)
    end

    def hk_customized?(action)
      @hk_labels[action] != HotkeyMap::DEFAULTS[action]
    end

    # Display-friendly text for a hotkey button.
    def hk_display(action)
      val = @hk_labels[action]
      return '?' unless val
      HotkeyMap.display_name(val)
    end

    # Update a mapping button's text and bold style.
    def style_btn(widget, text, bold)
      @app.command(widget, 'configure', text: text, style: bold ? 'Bold.TButton' : 'TButton')
    end

    LISTEN_TIMEOUT_MS = 10_000
    MODIFIER_SETTLE_MS = 600

    # Refresh the hotkeys tab widgets from external state (e.g. after undo).
    # @param labels [Hash{Symbol => String}] action → keysym
    def refresh_hotkeys(labels)
      @hk_labels = labels.dup
      HK_ACTIONS.each do |action, widget|
        style_btn(widget, hk_display(action), hk_customized?(action))
      end
    end

    # @return [Symbol, nil] the hotkey action currently listening for remap
    attr_reader :hk_listening_for

    # Capture a hotkey during listen mode. Called by the Tk <Key>
    # bind script, or directly by tests.
    #
    # Modifier keys (Ctrl, Shift, Alt) start a pending combo — if a
    # non-modifier key follows within MODIFIER_SETTLE_MS, the combo is
    # captured. If the timer expires, the modifier alone is captured.
    #
    # @param keysym [String] Tk keysym (e.g. "Control_L", "k")
    def capture_hk_mapping(keysym)
      return unless @hk_listening_for

      mod = HotkeyMap.normalize_modifier(keysym)
      if mod
        # Modifier pressed — accumulate and wait for a non-modifier key
        @hk_pending_modifiers << mod
        cancel_mod_timer
        @hk_mod_timer = @app.after(MODIFIER_SETTLE_MS) { finalize_hk(keysym) }
        return
      end

      # Non-modifier key arrived — normalize variant keysyms
      # (e.g. Shift+Tab produces ISO_Left_Tab on many platforms)
      keysym = HotkeyMap.normalize_keysym(keysym)
      cancel_mod_timer
      if @hk_pending_modifiers.any?
        hotkey = [*@hk_pending_modifiers.sort_by { |m| HotkeyMap::MODIFIER_ORDER.index(m) || 99 }, keysym]
        @hk_pending_modifiers.clear
      else
        hotkey = keysym
      end

      finalize_hk(hotkey)
    end

    # Finalize a captured hotkey (plain key or combo). Also called by
    # tests that want to bypass the modifier settle timer.
    # @param hotkey [String, Array]
    def finalize_hk(hotkey)
      return unless @hk_listening_for
      cancel_mod_timer
      @hk_pending_modifiers.clear

      hotkey = HotkeyMap.normalize(hotkey)

      # Reject hotkeys that conflict with keyboard gamepad mappings
      # (only plain keys can conflict — combos with modifiers are fine)
      unless hotkey.is_a?(Array)
        error = @callbacks[:on_validate_hotkey].call(hotkey.to_s)
        if error
          show_key_conflict(error)
          cancel_hk_listening
          return
        end
      end

      if @hk_listen_timer
        @app.command(:after, :cancel, @hk_listen_timer)
        @hk_listen_timer = nil
      end
      unbind_keyboard_listen

      action = @hk_listening_for
      @hk_labels[action] = hotkey
      widget = HK_ACTIONS[action]
      style_btn(widget, hk_display(action), hk_customized?(action))
      @hk_listening_for = nil

      @callbacks[:on_hotkey_change]&.call(action, hotkey)
      @app.command(HK_UNDO_BTN, 'configure', state: :normal)
      mark_dirty
    end

    private

    def start_hk_listening(action)
      cancel_hk_listening
      @hk_listening_for = action
      widget = HK_ACTIONS[action]
      @app.command(widget, 'configure', text: translate('settings.press'))
      @hk_listen_timer = @app.after(LISTEN_TIMEOUT_MS) { cancel_hk_listening }

      cb_id = @app.interp.register_callback(
        proc { |keysym, *| capture_hk_mapping(keysym) })
      @app.tcl_eval("bind #{TOP} <Key> {ruby_callback #{cb_id} %K}")
    end

    def cancel_hk_listening
      cancel_mod_timer
      @hk_pending_modifiers.clear
      if @hk_listen_timer
        @app.command(:after, :cancel, @hk_listen_timer)
        @hk_listen_timer = nil
      end
      if @hk_listening_for
        unbind_keyboard_listen
        widget = HK_ACTIONS[@hk_listening_for]
        style_btn(widget, hk_display(@hk_listening_for), hk_customized?(@hk_listening_for))
        @hk_listening_for = nil
      end
    end

    def cancel_mod_timer
      if @hk_mod_timer
        @app.command(:after, :cancel, @hk_mod_timer)
        @hk_mod_timer = nil
      end
    end

    def show_key_conflict(message)
      if @callbacks[:on_key_conflict]
        @callbacks[:on_key_conflict].call(message)
      else
        @app.command('tk_messageBox',
          parent: TOP,
          title: translate('dialog.key_conflict_title'),
          message: message,
          type: :ok,
          icon: :warning)
      end
    end

    def do_undo_hotkeys
      @callbacks[:on_undo_hotkeys]&.call
      @app.command(HK_UNDO_BTN, 'configure', state: :disabled)
    end

    def confirm_reset_hotkeys
      cancel_hk_listening
      confirmed = if @callbacks[:on_confirm_reset_hotkeys]
        @callbacks[:on_confirm_reset_hotkeys].call
      else
        @app.command('tk_messageBox',
          parent: TOP,
          title: translate('dialog.reset_hotkeys_title'),
          message: translate('dialog.reset_hotkeys_msg'),
          type: :yesno,
          icon: :question) == 'yes'
      end
      if confirmed
        reset_hotkey_defaults
        do_save
      end
    end

    def reset_hotkey_defaults
      cancel_hk_listening
      @hk_labels = HotkeyMap::DEFAULTS.dup
      HK_ACTIONS.each do |action, widget|
        style_btn(widget, hk_display(action), false)
      end
      @app.command(HK_UNDO_BTN, 'configure', state: :disabled)
      @callbacks[:on_hotkey_reset]&.call
    end

  end
end
