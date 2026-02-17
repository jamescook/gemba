# frozen_string_literal: true

require_relative "paths"

module Gemba
  module Settings
    class GamepadTab
      include Locale::Translatable

      FRAME          = "#{Paths::NB}.gamepad"
      GAMEPAD_COMBO  = "#{FRAME}.gp_row.gp_combo"
      DEADZONE_SCALE = "#{FRAME}.dz_row.dz_scale"
      RESET_BTN      = "#{FRAME}.btn_bar.reset_btn"
      UNDO_BTN       = "#{FRAME}.btn_bar.undo_btn"

      # GBA button widget paths (for remapping)
      BTN_A      = "#{FRAME}.row_a.btn"
      BTN_B      = "#{FRAME}.row_b.btn"
      BTN_L      = "#{FRAME}.row_l.btn"
      BTN_R      = "#{FRAME}.row_r.btn"
      BTN_UP     = "#{FRAME}.row_up.btn"
      BTN_DOWN   = "#{FRAME}.row_down.btn"
      BTN_LEFT   = "#{FRAME}.row_left.btn"
      BTN_RIGHT  = "#{FRAME}.row_right.btn"
      BTN_START  = "#{FRAME}.row_start.btn"
      BTN_SELECT = "#{FRAME}.row_select.btn"

      VAR_GAMEPAD  = '::mgba_gamepad'
      VAR_DEADZONE = '::mgba_deadzone'

      # GBA button → widget path mapping
      GBA_BUTTONS = {
        a: BTN_A, b: BTN_B,
        l: BTN_L, r: BTN_R,
        up: BTN_UP, down: BTN_DOWN,
        left: BTN_LEFT, right: BTN_RIGHT,
        start: BTN_START, select: BTN_SELECT,
      }.freeze

      # GBA button → locale key mapping
      LOCALE_KEYS = {
        a: 'settings.gp_a', b: 'settings.gp_b',
        l: 'settings.gp_l', r: 'settings.gp_r',
        up: 'settings.gp_up', down: 'settings.gp_down',
        left: 'settings.gp_left', right: 'settings.gp_right',
        start: 'settings.gp_start', select: 'settings.gp_select',
      }.freeze

      # Default GBA → SDL gamepad mappings (display names)
      DEFAULT_GP_LABELS = {
        a: 'a', b: 'b',
        l: 'left_shoulder', r: 'right_shoulder',
        up: 'dpad_up', down: 'dpad_down',
        left: 'dpad_left', right: 'dpad_right',
        start: 'start', select: 'back',
      }.freeze

      # Default GBA → Tk keysym mappings (keyboard mode display names)
      DEFAULT_KB_LABELS = {
        a: 'z', b: 'x',
        l: 'a', r: 's',
        up: 'Up', down: 'Down',
        left: 'Left', right: 'Right',
        start: 'Return', select: 'BackSpace',
      }.freeze

      KEY_DISPLAY_LOCALE = {
        'Up' => 'settings.key_up', 'Down' => 'settings.key_down',
        'Left' => 'settings.key_left', 'Right' => 'settings.key_right',
      }.freeze

      LISTEN_TIMEOUT_MS = 10_000

      def initialize(app, callbacks:, tips:, mark_dirty:, do_save:, show_key_conflict:)
        @app = app
        @callbacks = callbacks
        @tips = tips
        @mark_dirty = mark_dirty
        @do_save = do_save
        @show_key_conflict = show_key_conflict
        @listening_for = nil
        @listen_timer = nil
        @keyboard_mode = true
        @gp_labels = DEFAULT_KB_LABELS.dup
      end

      # @return [Symbol, nil] the GBA button currently listening for remap, or nil
      attr_reader :listening_for

      # @return [Boolean] true when editing keyboard bindings, false for gamepad
      def keyboard_mode?
        @keyboard_mode
      end

      def build
        @app.command('ttk::frame', FRAME)
        @app.command(Paths::NB, 'add', FRAME, text: translate('settings.gamepad'))

        build_gamepad_selector
        build_button_rows
        build_bottom_bar
        build_deadzone_slider

        # Start in keyboard mode — dead zone disabled
        set_deadzone_enabled(false)
      end

      def update_gamepad_list(names)
        @app.command(GAMEPAD_COMBO, 'configure',
          values: Teek.make_list(*names))
        current = @app.get_variable(VAR_GAMEPAD)
        unless names.include?(current)
          @app.set_variable(VAR_GAMEPAD, names.first)
        end
      end

      # Refresh the gamepad tab widgets from external state (e.g. after undo).
      # @param labels [Hash{Symbol => String}] GBA button → gamepad button name
      # @param dead_zone [Integer] dead zone percentage (0-50)
      def refresh_gamepad(labels, dead_zone)
        @gp_labels = labels.dup
        GBA_BUTTONS.each do |gba_btn, widget|
          style_btn(widget, btn_display(gba_btn), gp_customized?(gba_btn))
        end
        @app.command(DEADZONE_SCALE, 'set', dead_zone)
      end

      def capture_mapping(button)
        return unless @listening_for

        # In keyboard mode, reject keys that conflict with hotkeys
        if @keyboard_mode
          error = @callbacks[:on_validate_kb_mapping].call(button.to_s)
          if error
            @show_key_conflict.call(error)
            cancel_listening
            return
          end
        end

        if @listen_timer
          @app.command(:after, :cancel, @listen_timer)
          @listen_timer = nil
        end
        unbind_keyboard_listen

        gba_btn = @listening_for
        @gp_labels[gba_btn] = button.to_s
        widget = GBA_BUTTONS[gba_btn]
        style_btn(widget, btn_display(gba_btn), gp_customized?(gba_btn))
        @listening_for = nil

        if @keyboard_mode
          @callbacks[:on_keyboard_map_change]&.call(gba_btn, button)
        else
          @callbacks[:on_gamepad_map_change]&.call(gba_btn, button)
        end
        @app.command(UNDO_BTN, 'configure', state: :normal)
        @mark_dirty.call
      end

      private

      def build_gamepad_selector
        gp_row = "#{FRAME}.gp_row"
        @app.command('ttk::frame', gp_row)
        @app.command(:pack, gp_row, fill: :x, padx: 10, pady: [8, 4])

        @app.command('ttk::label', "#{gp_row}.lbl", text: translate('settings.gamepad') + ':')
        @app.command(:pack, "#{gp_row}.lbl", side: :left)

        @app.set_variable(VAR_GAMEPAD, translate('settings.keyboard_only'))
        @app.command('ttk::combobox', GAMEPAD_COMBO,
          textvariable: VAR_GAMEPAD, state: :readonly, width: 20)
        @app.command(:pack, GAMEPAD_COMBO, side: :left, padx: 4)
        @app.command(GAMEPAD_COMBO, 'configure',
          values: Teek.make_list(translate('settings.keyboard_only')))

        @app.command(:bind, GAMEPAD_COMBO, '<<ComboboxSelected>>',
          proc { |*| switch_input_mode })
      end

      def build_button_rows
        GBA_BUTTONS.each do |gba_btn, btn_path|
          row = "#{FRAME}.row_#{gba_btn}"
          @app.command('ttk::frame', row)
          @app.command(:pack, row, fill: :x, padx: 10, pady: 2)

          lbl_path = "#{row}.lbl"
          @app.command('ttk::label', lbl_path, text: translate(LOCALE_KEYS[gba_btn]), width: 14, anchor: :w)
          @app.command(:pack, lbl_path, side: :left)

          @app.command('ttk::button', btn_path, text: btn_display(gba_btn), width: 12,
            style: gp_customized?(gba_btn) ? 'Bold.TButton' : 'TButton',
            command: proc { start_listening(gba_btn) })
          @app.command(:pack, btn_path, side: :right)
        end
      end

      def build_bottom_bar
        btn_bar = "#{FRAME}.btn_bar"
        @app.command('ttk::frame', btn_bar)
        @app.command(:pack, btn_bar, fill: :x, side: :bottom, padx: 10, pady: [4, 8])

        @app.command('ttk::button', UNDO_BTN, text: translate('settings.undo'),
          state: :disabled, command: proc { do_undo_gamepad })
        @app.command(:pack, UNDO_BTN, side: :left)

        @app.command('ttk::button', RESET_BTN, text: translate('settings.reset_defaults'),
          command: proc { confirm_reset_gamepad })
        @app.command(:pack, RESET_BTN, side: :right)
      end

      def build_deadzone_slider
        dz_row = "#{FRAME}.dz_row"
        @app.command('ttk::frame', dz_row)
        @app.command(:pack, dz_row, fill: :x, padx: 10, pady: [4, 8], side: :bottom)

        @app.command('ttk::label', "#{dz_row}.lbl", text: translate('settings.dead_zone'))
        @app.command(:pack, "#{dz_row}.lbl", side: :left)
        @tips.register("#{dz_row}.lbl", translate('settings.tip_dead_zone'))

        @dz_val_label = "#{dz_row}.dz_label"
        @app.command('ttk::label', @dz_val_label, text: '25%', width: 5)
        @app.command(:pack, @dz_val_label, side: :right)

        @app.set_variable(VAR_DEADZONE, '25')
        @app.command('ttk::scale', DEADZONE_SCALE,
          orient: :horizontal, from: 0, to: 50, length: 150,
          variable: VAR_DEADZONE,
          command: proc { |v, *|
            pct = v.to_f.round
            @app.command(@dz_val_label, 'configure', text: "#{pct}%")
            threshold = (pct / 100.0 * 32767).round
            @callbacks[:on_deadzone_change]&.call(threshold)
            @mark_dirty.call
          })
        @app.command(:pack, DEADZONE_SCALE, side: :right, padx: [5, 5])
      end

      def btn_display(gba_btn)
        label = @gp_labels[gba_btn] || '?'
        locale_key = KEY_DISPLAY_LOCALE[label]
        locale_key ? translate(locale_key) : label
      end

      def gp_customized?(gba_btn)
        defaults = @keyboard_mode ? DEFAULT_KB_LABELS : DEFAULT_GP_LABELS
        @gp_labels[gba_btn] != defaults[gba_btn]
      end

      def style_btn(widget, text, bold)
        @app.command(widget, 'configure', text: text, style: bold ? 'Bold.TButton' : 'TButton')
      end

      def start_listening(gba_btn)
        cancel_listening
        @listening_for = gba_btn
        widget = GBA_BUTTONS[gba_btn]
        @app.command(widget, 'configure', text: translate('settings.press'))
        @listen_timer = @app.after(LISTEN_TIMEOUT_MS) { cancel_listening }

        if @keyboard_mode
          cb_id = @app.interp.register_callback(
            proc { |keysym, *| capture_mapping(keysym) })
          @app.tcl_eval("bind #{Paths::TOP} <Key> {ruby_callback #{cb_id} %K}")
        end
      end

      def cancel_listening
        if @listen_timer
          @app.command(:after, :cancel, @listen_timer)
          @listen_timer = nil
        end
        if @listening_for
          unbind_keyboard_listen
          widget = GBA_BUTTONS[@listening_for]
          style_btn(widget, btn_display(@listening_for), gp_customized?(@listening_for))
          @listening_for = nil
        end
      end

      def unbind_keyboard_listen
        @app.tcl_eval("bind #{Paths::TOP} <Key> {}")
      end

      def switch_input_mode
        cancel_listening
        selected = @app.get_variable(VAR_GAMEPAD)
        @keyboard_mode = (selected == translate('settings.keyboard_only'))

        if @keyboard_mode
          @gp_labels = DEFAULT_KB_LABELS.dup
          set_deadzone_enabled(false)
        else
          @gp_labels = DEFAULT_GP_LABELS.dup
          set_deadzone_enabled(true)
        end

        GBA_BUTTONS.each do |gba_btn, widget|
          style_btn(widget, btn_display(gba_btn), false)
        end

        @app.command(UNDO_BTN, 'configure', state: :disabled)
        @callbacks[:on_input_mode_change]&.call(@keyboard_mode, selected)
      end

      def set_deadzone_enabled(enabled)
        state = enabled ? :normal : :disabled
        @app.command(DEADZONE_SCALE, 'configure', state: state)
      end

      def confirm_reset_gamepad
        cancel_listening
        confirmed = if @callbacks[:on_confirm_reset_gamepad]
          @callbacks[:on_confirm_reset_gamepad].call
        else
          @app.command('tk_messageBox',
            parent: Paths::TOP,
            title: translate('dialog.reset_gamepad_title'),
            message: translate('dialog.reset_gamepad_msg'),
            type: :yesno,
            icon: :question) == 'yes'
        end
        if confirmed
          reset_gamepad_defaults
          @do_save.call
        end
      end

      def reset_gamepad_defaults
        @gp_labels = (@keyboard_mode ? DEFAULT_KB_LABELS : DEFAULT_GP_LABELS).dup
        GBA_BUTTONS.each do |gba_btn, widget|
          style_btn(widget, btn_display(gba_btn), false)
        end
        @app.command(DEADZONE_SCALE, 'set', 25) unless @keyboard_mode
        @app.command(UNDO_BTN, 'configure', state: :disabled)
        if @keyboard_mode
          @callbacks[:on_keyboard_reset]&.call
        else
          @callbacks[:on_gamepad_reset]&.call
        end
      end

      def do_undo_gamepad
        @callbacks[:on_undo_gamepad]&.call
        @app.command(UNDO_BTN, 'configure', state: :disabled)
      end
    end
  end
end
