# frozen_string_literal: true

require_relative "paths"

module Gemba
  module Settings
    class HotkeysTab
      include Locale::Translatable
      include BusEmitter

      FRAME     = "#{Paths::NB}.hotkeys"
      UNDO_BTN  = "#{FRAME}.btn_bar.undo_btn"
      RESET_BTN = "#{FRAME}.btn_bar.reset_btn"

      # Action → widget path mapping for hotkey buttons
      ACTIONS = {
        quit:        "#{FRAME}.row_quit.btn",
        pause:       "#{FRAME}.row_pause.btn",
        fast_forward: "#{FRAME}.row_fast_forward.btn",
        fullscreen:  "#{FRAME}.row_fullscreen.btn",
        show_fps:    "#{FRAME}.row_show_fps.btn",
        quick_save:  "#{FRAME}.row_quick_save.btn",
        quick_load:  "#{FRAME}.row_quick_load.btn",
        save_states: "#{FRAME}.row_save_states.btn",
        screenshot:  "#{FRAME}.row_screenshot.btn",
        rewind:      "#{FRAME}.row_rewind.btn",
        record:       "#{FRAME}.row_record.btn",
        input_record: "#{FRAME}.row_input_record.btn",
        open_rom:     "#{FRAME}.row_open_rom.btn",
      }.freeze

      # Action → locale key mapping
      LOCALE_KEYS = {
        quit: 'settings.hk_quit', pause: 'settings.hk_pause',
        fast_forward: 'settings.hk_fast_forward', fullscreen: 'settings.hk_fullscreen',
        show_fps: 'settings.hk_show_fps', quick_save: 'settings.hk_quick_save',
        quick_load: 'settings.hk_quick_load', save_states: 'settings.hk_save_states',
        screenshot: 'settings.hk_screenshot',
        rewind: 'settings.hk_rewind',
        record: 'settings.hk_record',
        input_record: 'settings.hk_input_record',
        open_rom: 'settings.hk_open_rom',
      }.freeze

      LISTEN_TIMEOUT_MS  = 10_000
      MODIFIER_SETTLE_MS = 600

      def initialize(app, callbacks:, mark_dirty:, do_save:, show_key_conflict:)
        @app = app
        @callbacks = callbacks
        @mark_dirty = mark_dirty
        @do_save = do_save
        @show_key_conflict = show_key_conflict
        @hk_listening_for = nil
        @hk_listen_timer = nil
        @hk_labels = HotkeyMap::DEFAULTS.dup
        @hk_pending_modifiers = Set.new
        @hk_mod_timer = nil
      end

      # @return [Symbol, nil] the hotkey action currently listening for remap
      attr_reader :hk_listening_for

      def build
        @app.command('ttk::frame', FRAME)
        @app.command(Paths::NB, 'add', FRAME, text: translate('settings.hotkeys'))

        build_action_rows
        build_bottom_bar
      end

      # Refresh the hotkeys tab widgets from external state (e.g. after undo).
      # @param labels [Hash{Symbol => String}] action → keysym
      def refresh_hotkeys(labels)
        @hk_labels = labels.dup
        ACTIONS.each do |action, widget|
          style_btn(widget, hk_display(action), hk_customized?(action))
        end
      end

      # Capture a hotkey during listen mode. Called by the Tk <Key>
      # bind script, or directly by tests.
      def capture_hk_mapping(keysym)
        return unless @hk_listening_for

        mod = HotkeyMap.normalize_modifier(keysym)
        if mod
          @hk_pending_modifiers << mod
          cancel_mod_timer
          @hk_mod_timer = @app.after(MODIFIER_SETTLE_MS) { finalize_hk(keysym) }
          return
        end

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

      # Finalize a captured hotkey (plain key or combo).
      def finalize_hk(hotkey)
        return unless @hk_listening_for
        cancel_mod_timer
        @hk_pending_modifiers.clear

        hotkey = HotkeyMap.normalize(hotkey)

        unless hotkey.is_a?(Array)
          error = @callbacks[:on_validate_hotkey].call(hotkey.to_s)
          if error
            @show_key_conflict.call(error)
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
        widget = ACTIONS[action]
        style_btn(widget, hk_display(action), hk_customized?(action))
        @hk_listening_for = nil

        emit(:hotkey_changed, action, hotkey)
        @app.command(UNDO_BTN, 'configure', state: :normal)
        @mark_dirty.call
      end

      private

      def build_action_rows
        ACTIONS.each do |action, btn_path|
          row = "#{FRAME}.row_#{action}"
          @app.command('ttk::frame', row)
          @app.command(:pack, row, fill: :x, padx: 10, pady: 2)

          lbl_path = "#{row}.lbl"
          @app.command('ttk::label', lbl_path, text: translate(LOCALE_KEYS[action]), width: 14, anchor: :w)
          @app.command(:pack, lbl_path, side: :left)

          display = hk_display(action)
          @app.command('ttk::button', btn_path, text: display, width: 12,
            style: hk_customized?(action) ? 'Bold.TButton' : 'TButton',
            command: proc { start_hk_listening(action) })
          @app.command(:pack, btn_path, side: :right)
        end
      end

      def build_bottom_bar
        btn_bar = "#{FRAME}.btn_bar"
        @app.command('ttk::frame', btn_bar)
        @app.command(:pack, btn_bar, fill: :x, side: :bottom, padx: 10, pady: [4, 8])

        @app.command('ttk::button', UNDO_BTN, text: translate('settings.undo'),
          state: :disabled, command: proc { do_undo_hotkeys })
        @app.command(:pack, UNDO_BTN, side: :left)

        @app.command('ttk::button', RESET_BTN, text: translate('settings.hk_reset_defaults'),
          command: proc { confirm_reset_hotkeys })
        @app.command(:pack, RESET_BTN, side: :right)
      end

      def hk_customized?(action)
        @hk_labels[action] != HotkeyMap::DEFAULTS[action]
      end

      def hk_display(action)
        val = @hk_labels[action]
        return '?' unless val
        HotkeyMap.display_name(val)
      end

      def style_btn(widget, text, bold)
        @app.command(widget, 'configure', text: text, style: bold ? 'Bold.TButton' : 'TButton')
      end

      def start_hk_listening(action)
        cancel_hk_listening
        @hk_listening_for = action
        widget = ACTIONS[action]
        @app.command(widget, 'configure', text: translate('settings.press'))
        @hk_listen_timer = @app.after(LISTEN_TIMEOUT_MS) { cancel_hk_listening }

        cb_id = @app.interp.register_callback(
          proc { |keysym, *| capture_hk_mapping(keysym) })
        @app.tcl_eval("bind #{Paths::TOP} <Key> {ruby_callback #{cb_id} %K}")
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
          widget = ACTIONS[@hk_listening_for]
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

      def unbind_keyboard_listen
        @app.tcl_eval("bind #{Paths::TOP} <Key> {}")
      end

      def do_undo_hotkeys
        emit(:undo_hotkeys)
        @app.command(UNDO_BTN, 'configure', state: :disabled)
      end

      def confirm_reset_hotkeys
        cancel_hk_listening
        confirmed = if @callbacks[:on_confirm_reset_hotkeys]
          @callbacks[:on_confirm_reset_hotkeys].call
        else
          @app.command('tk_messageBox',
            parent: Paths::TOP,
            title: translate('dialog.reset_hotkeys_title'),
            message: translate('dialog.reset_hotkeys_msg'),
            type: :yesno,
            icon: :question) == 'yes'
        end
        if confirmed
          reset_hotkey_defaults
          @do_save.call
        end
      end

      def reset_hotkey_defaults
        cancel_hk_listening
        @hk_labels = HotkeyMap::DEFAULTS.dup
        ACTIONS.each do |action, widget|
          style_btn(widget, hk_display(action), false)
        end
        @app.command(UNDO_BTN, 'configure', state: :disabled)
        emit(:hotkey_reset)
      end
    end
  end
end
