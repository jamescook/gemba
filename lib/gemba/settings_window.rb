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
require_relative "settings/hotkeys_tab"

module Gemba
  # Settings window for the mGBA Player.
  #
  # Thin coordinator that builds a Toplevel with a ttk::notebook, delegates
  # each tab to its own class under Settings::*, and manages shared concerns
  # (per-game bar, save button, key-conflict dialog).
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

    # Hotkeys tab widget paths (re-exported from Settings::HotkeysTab)
    HK_TAB       = Settings::HotkeysTab::FRAME
    HK_UNDO_BTN  = Settings::HotkeysTab::UNDO_BTN
    HK_RESET_BTN = Settings::HotkeysTab::RESET_BTN
    HK_ACTIONS   = Settings::HotkeysTab::ACTIONS

    # Locale key mappings (re-exported)
    HK_LOCALE_KEYS = Settings::HotkeysTab::LOCALE_KEYS
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

    CALLBACK_DEFAULTS = {
      on_validate_hotkey:     ->(_) { nil },
      on_validate_kb_mapping: ->(_) { nil },
    }.freeze

    def initialize(app, callbacks: {}, tip_dismiss_ms: TipService::DEFAULT_DISMISS_MS)
      @app = app
      @callbacks = CALLBACK_DEFAULTS.merge(callbacks)
      @tip_dismiss_ms = tip_dismiss_ms
      @per_game_enabled = false

      build_toplevel(translate('menu.settings'), geometry: '700x560') { setup_ui }
    end

    # Delegates to GamepadTab
    def listening_for = @gamepad_tab.listening_for
    def keyboard_mode? = @gamepad_tab.keyboard_mode?
    def update_gamepad_list(names) = @gamepad_tab.update_gamepad_list(names)
    def refresh_gamepad(labels, dead_zone) = @gamepad_tab.refresh_gamepad(labels, dead_zone)
    def capture_mapping(button) = @gamepad_tab.capture_mapping(button)

    # Delegates to HotkeysTab
    def hk_listening_for = @hotkeys_tab.hk_listening_for
    def capture_hk_mapping(keysym) = @hotkeys_tab.capture_hk_mapping(keysym)
    def finalize_hk(hotkey) = @hotkeys_tab.finalize_hk(hotkey)
    def refresh_hotkeys(labels) = @hotkeys_tab.refresh_hotkeys(labels)

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
      @hotkeys_tab = Settings::HotkeysTab.new(@app, callbacks: @callbacks,
        mark_dirty: method(:mark_dirty), do_save: method(:do_save),
        show_key_conflict: method(:show_key_conflict))
      @hotkeys_tab.build
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

  end
end
