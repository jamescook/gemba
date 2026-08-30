require "tryst"
require "tryst/ui"
require "../button"
require "../locale"
require "../events"

module Gemba
  module Settings
    # Deliberately holds no reference to KeyboardMap/GamepadMap - it
    # keeps its own @gp_labels purely for display, and only emits events
    # (mirroring every other SettingsWindow tab's Events-based wiring);
    # MainWindow applies them to the real maps and persists. #refresh
    # pushes real map state back in (initial load, after Undo, after a
    # mode switch).
    #
    # Built through the Tryst::UI DSL (Session#add against SettingsWindow's
    # shared notebook Handle) rather than raw @app.command("ttk::...")
    # calls - see SettingsWindow's own class comment. The whole tab is
    # declared inside its own ui.component, so its widget names are
    # local to it: AchievementsTab has a :reset of its own, and neither
    # can see (or collide with) the other's. #add's block builds the
    # whole subtree before anything realizes, so every Handle it hands
    # back is captured into a local first and only read
    # (#path/#configure) once #add itself returns.
    class GamepadTab
      LISTEN_TIMEOUT_MS = 10_000

      ORDER = [
        Button::A, Button::B, Button::L, Button::R,
        Button::Up, Button::Down, Button::Left, Button::Right,
        Button::Start, Button::Select,
      ]

      # Duplicated from KeyboardMap::DEFAULT_MAP/GamepadMap::DEFAULT_MAP
      # (inverted) rather than derived from them - matches ruby's own
      # GamepadTab, which keeps its display defaults separate from the
      # real map classes' own.
      DEFAULT_KB_LABELS = {
        Button::A => "z", Button::B => "x", Button::L => "a", Button::R => "s",
        Button::Up => "Up", Button::Down => "Down", Button::Left => "Left", Button::Right => "Right",
        Button::Start => "Return", Button::Select => "BackSpace",
      }

      DEFAULT_GP_LABELS = {
        Button::A => "a", Button::B => "b", Button::L => "left_shoulder", Button::R => "right_shoulder",
        Button::Up => "dpad_up", Button::Down => "dpad_down", Button::Left => "dpad_left", Button::Right => "dpad_right",
        Button::Start => "start", Button::Select => "back",
      }

      KEY_DISPLAY_LOCALE = {
        "Up" => "settings.key_up", "Down" => "settings.key_down",
        "Left" => "settings.key_left", "Right" => "settings.key_right",
      }

      getter? keyboard_mode : Bool
      getter listening_for : Button?

      # The device-select combobox's own real Tk path - a spec needs
      # this to simulate <<ComboboxSelected>> on it directly (see
      # main_window_gamepad_spec.cr); no other public method reaches
      # this specific widget.
      getter gp_combo : String

      @listen_timer : Tryst::AfterHandle?

      @frame : String
      @dz_scale : String
      @dz_label : String
      @undo_btn : String
      @reset_btn : String
      @btn_widgets : Hash(Button, String)

      # notebook: SettingsWindow's shared notebook - this tab adds itself
      # to it via its own Session#add call rather than being inlined into
      # SettingsWindow's. toplevel_path: the settings window's own
      # toplevel, not this tab's frame - keyboard capture binds <Key>
      # there (same as ruby's Paths::TOP) so it fires regardless of which
      # child widget has focus. validate_keyboard_mapping: an optional
      # hotkey-conflict check (MainWindow's own HotkeyMap#action_for) -
      # nil skips it.
      def initialize(@app : Tryst::App, @session : Tryst::UI::Session, notebook : Tryst::UI::Handle,
                     @toplevel_path : String, @events : Events,
                     @validate_keyboard_mapping : Proc(String, String?)? = nil)
        @gp_var = "::gemba_gamepad_device"
        @dz_var = "::gemba_deadzone"
        @keyboard_mode = true
        @gp_labels = DEFAULT_KB_LABELS.dup
        @btn_widgets = {} of Button => String
        @listening_for = nil
        @listen_timer = nil

        frame_handle = nil
        gp_combo_handle = nil
        dz_scale_handle = nil
        dz_label_handle = nil
        undo_btn_handle = nil
        reset_btn_handle = nil
        btn_widget_handles = {} of Button => Tryst::UI::Handle

        @session.add(notebook) do |session|
          session.component(:gamepad) do |scope|
            frame_handle = scope.tab(Locale.translate("settings.gamepad"), :tab) do |tab|
              tab.row(:device_row, gap: 4, pad: 8) do |row|
                row.label(text: "#{Locale.translate("settings.gamepad")}:")
                gp_combo_handle = row.dropdown(:device, textvariable: @gp_var, state: :readonly, width: 20)
              end

              ORDER.each do |btn|
                suffix = btn.to_s.downcase
                tab.row(gap: 2, pad: 2) do |row|
                  row.label(text: Locale.translate("settings.gp_#{suffix}"), width: 14, anchor: :w)
                  btn_widget_handles[btn] = row.button(width: 12,
                    text: btn_display(btn), style: gp_customized?(btn) ? "Bold.TButton" : "TButton",
                    command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { start_listening(btn); nil })
                end
              end

              tab.row(:actions_row, gap: 0, pad: 8) do |row|
                undo_btn_handle = row.button(:undo, text: Locale.translate("settings.undo"), state: :disabled,
                  command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { do_undo; nil })
                reset_btn_handle = row.button(:reset, text: Locale.translate("settings.reset_defaults"),
                  command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { confirm_reset; nil })
              end

              tab.row(:dead_zone_row, gap: 4, pad: 8) do |row|
                row.label(text: Locale.translate("settings.dead_zone"))
                dz_label_handle = row.label(:dead_zone_value, text: "25%", width: 5)
                dz_scale_handle = row.slider(:dead_zone, orient: :horizontal, from: 0, to: 50, length: 150,
                  variable: @dz_var,
                  command: ->(values : Array(String), _signal : Tryst::CallbackSignal) {
                    pct = values[0].to_f.round.to_i
                    @app.command(realized!(dz_label_handle).path, "configure", text: "#{pct}%")
                    threshold = (pct / 100.0 * 32767).round.to_i
                    @events.gamepad_dead_zone_changed.emit(threshold)
                    nil
                  })
              end
            end
          end
        end

        @frame = realized!(frame_handle).path
        @gp_combo = realized!(gp_combo_handle).path
        @dz_scale = realized!(dz_scale_handle).path
        @dz_label = realized!(dz_label_handle).path
        @undo_btn = realized!(undo_btn_handle).path
        @reset_btn = realized!(reset_btn_handle).path
        @btn_widgets = btn_widget_handles.transform_values(&.path)

        keyboard_only = Locale.translate("settings.keyboard_only")
        @app.set_variable(@gp_var, keyboard_only)
        @app.command(@gp_combo, "configure", values: @app.make_list(keyboard_only))
        @app.bind(@gp_combo, :combobox_selected) { |_values, _signal| switch_input_mode }
        @app.set_variable(@dz_var, "25")

        set_deadzone_enabled(false)
      end

      def path : String
        @frame
      end

      # Refreshes the tab's displayed labels/dead-zone from real map
      # state - call after the initial config load, after Undo, and
      # after a mode switch (see MainWindow's Events wiring).
      def refresh(labels : Hash(Button, String), dead_zone_pct : Int32) : Nil
        @gp_labels = labels.dup
        ORDER.each { |btn| style_btn(@btn_widgets[btn], btn_display(btn), gp_customized?(btn)) }
        @app.command(@dz_scale, :set, dead_zone_pct)
      end

      # Populates the device combo - MainWindow#refresh_gamepads calls
      # this on every hot-plug. Keeps the current selection if it's
      # still valid, otherwise falls back to Keyboard Only.
      def update_gamepad_list(names : Array(String)) : Nil
        keyboard_only = Locale.translate("settings.keyboard_only")
        choices = [keyboard_only] + names
        @app.command(@gp_combo, "configure", values: @app.make_list(choices))
        current = @app.get_variable(@gp_var)
        @app.set_variable(@gp_var, keyboard_only) unless choices.includes?(current)
      end

      # Called while #listening_for is set - a captured keysym (keyboard
      # mode, from the <Key> binding below) or gamepad button name
      # (gamepad mode, from MainWindow#gamepad_probe_tick's own live
      # polling). Rejects a keyboard mapping that conflicts with a
      # hotkey rather than silently shadowing it.
      def capture_mapping(button : String) : Nil
        gba_btn = @listening_for
        return unless gba_btn

        if @keyboard_mode
          if validator = @validate_keyboard_mapping
            if error = validator.call(button)
              show_key_conflict(error)
              cancel_listening
              return
            end
          end
        end

        if timer = @listen_timer
          @app.after_cancel(timer)
          @listen_timer = nil
        end
        unbind_keyboard_listen

        @gp_labels[gba_btn] = button
        style_btn(@btn_widgets[gba_btn], btn_display(gba_btn), gp_customized?(gba_btn))
        @listening_for = nil

        if @keyboard_mode
          @events.keyboard_mapping_changed.emit(gba_btn, button)
        else
          @events.gamepad_mapping_changed.emit(gba_btn, button)
        end
        @app.command(@undo_btn, "configure", state: :normal)
      end

      def start_listening(gba_btn : Button) : Nil
        cancel_listening
        @listening_for = gba_btn
        @app.command(@btn_widgets[gba_btn], "configure", text: Locale.translate("settings.press"))
        @listen_timer = @app.after(LISTEN_TIMEOUT_MS) { cancel_listening }

        if @keyboard_mode
          @app.bind(@toplevel_path, :key, subs: "%K") { |values, _signal| capture_mapping(values[0]) }
        end
      end

      def cancel_listening : Nil
        if timer = @listen_timer
          @app.after_cancel(timer)
          @listen_timer = nil
        end
        if gba_btn = @listening_for
          unbind_keyboard_listen
          style_btn(@btn_widgets[gba_btn], btn_display(gba_btn), gp_customized?(gba_btn))
          @listening_for = nil
        end
      end

      private def unbind_keyboard_listen : Nil
        @app.unbind(@toplevel_path, :key)
      end

      private def btn_display(gba_btn : Button) : String
        label = @gp_labels[gba_btn]? || "?"
        locale_key = KEY_DISPLAY_LOCALE[label]?
        locale_key ? Locale.translate(locale_key) : label
      end

      private def gp_customized?(gba_btn : Button) : Bool
        defaults = @keyboard_mode ? DEFAULT_KB_LABELS : DEFAULT_GP_LABELS
        @gp_labels[gba_btn]? != defaults[gba_btn]?
      end

      private def style_btn(widget : String, text : String, bold : Bool) : Nil
        @app.command(widget, "configure", text: text, style: bold ? "Bold.TButton" : "TButton")
      end

      private def show_key_conflict(message : String) : Nil
        @app.message_box(message, title: Locale.translate("dialog.key_conflict_title"), type: :ok, icon: :warning)
      end

      private def switch_input_mode : Nil
        cancel_listening
        selected = @app.get_variable(@gp_var)
        @keyboard_mode = selected == Locale.translate("settings.keyboard_only")
        @gp_labels = (@keyboard_mode ? DEFAULT_KB_LABELS : DEFAULT_GP_LABELS).dup
        set_deadzone_enabled(!@keyboard_mode)

        ORDER.each { |btn| style_btn(@btn_widgets[btn], btn_display(btn), false) }
        @app.command(@undo_btn, "configure", state: :disabled)
        @events.input_mode_changed.emit(@keyboard_mode)
      end

      private def set_deadzone_enabled(enabled : Bool) : Nil
        @app.command(@dz_scale, "configure", state: enabled ? :normal : :disabled)
      end

      private def confirm_reset : Nil
        cancel_listening
        confirmed = @app.message_box(Locale.translate("dialog.reset_gamepad_msg"),
          title: Locale.translate("dialog.reset_gamepad_title"), type: :yesno, icon: :question) == :yes
        reset_defaults if confirmed
      end

      private def reset_defaults : Nil
        @gp_labels = (@keyboard_mode ? DEFAULT_KB_LABELS : DEFAULT_GP_LABELS).dup
        ORDER.each { |btn| style_btn(@btn_widgets[btn], btn_display(btn), false) }
        @app.command(@dz_scale, :set, 25) unless @keyboard_mode
        @app.command(@undo_btn, "configure", state: :disabled)

        if @keyboard_mode
          @events.keyboard_reset.emit
        else
          @events.gamepad_reset.emit
        end
      end

      private def do_undo : Nil
        @events.undo_input_mappings.emit(@keyboard_mode)
        @app.command(@undo_btn, "configure", state: :disabled)
      end

      # #add's block builds the whole subtree before anything realizes
      # (see #initialize's own comment on this), so every Handle it
      # hands back is genuinely always assigned by the time this runs -
      # a raise here means a bug in that build block, not a legitimate
      # nil case.
      private def realized!(handle : Tryst::UI::Handle?) : Tryst::UI::Handle
        handle || raise "GamepadTab widget handle wasn't realized by Session#add - this is a bug in its own build block"
      end
    end
  end
end
