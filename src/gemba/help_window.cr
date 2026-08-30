require "tryst/ui"
require "./hotkey_map"
require "./locale"

module Gemba
  # Floating hotkey reference panel, toggled with '?' - a read-only
  # cheat-sheet of whatever HotkeyMap currently binds, not an editor.
  # Ports ruby gemba's HelpWindow. Non-modal: no grab, no focus steal;
  # Handle#show places it just clear of the main window. MainWindow
  # owns the toggle and the auto-pause around it (see
  # MainWindow#toggle_help).
  #
  # Built purely through the Tryst::UI DSL, the same way RomInfoWindow
  # is - declared before Session#run_async, so it takes no App. One
  # Var-bound label per action: #show re-reads the live HotkeyMap into
  # those Vars every time, so a rebind shows up on the next open
  # without this class knowing anything about how rebinding works.
  class HelpWindow
    # Same order as ruby's own HotkeysTab::LOCALE_KEYS, which is
    # HotkeyMap::ACTIONS' order.
    ROWS = HotkeyMap::ACTIONS.map { |action| {action, "settings.hk_#{action}"} }

    # Shown for an action HotkeyMap has no binding for.
    UNBOUND = "—"

    getter handle : Tryst::UI::Handle

    @keys : Hash(Symbol, Tryst::UI::Var)
    @on_close : (-> Nil)? = nil

    def initialize(session : Tryst::UI::Session, @hotkeys : HotkeyMap)
      @keys = {} of Symbol => Tryst::UI::Var

      # Nothing here references @handle (see RomInfoWindow's note on
      # why that can't compile inside this expression); the close
      # handler is wired below, once it's assigned.
      @handle = session.window(:gemba_help, title: Locale.translate("settings.hotkeys"),
        resizable: false, modal: false, pad: 10, gap: 6, align: :stretch) do |window|
        window.label(:title, text: Locale.translate("settings.hotkeys"), font: window.font(size: 11, bold: true))
        window.divider
        window.grid(:rows, gap: 2) do |grid|
          ROWS.each_with_index do |(action, locale_key), i|
            grid.cell(row: i, col: 0, sticky: :w) { grid.label(text: Locale.translate(locale_key)) }
            var = grid.var("")
            @keys[action] = var
            grid.cell(row: i, col: 1, sticky: :e, padx: 12) { grid.label(bind: var, font: "TkFixedFont") }
          end
        end
      end

      @handle.on_close { |_values, _signal| @on_close.try(&.call) || @handle.hide }
    end

    # Fires when the window manager's own close button is used - wire
    # it to the same toggle '?' runs, so closing that way releases the
    # auto-pause too. Falls back to a plain hide when nothing is wired.
    def on_close(&block : -> Nil) : Nil
      @on_close = block
    end

    # Re-reads every binding from the HotkeyMap, then reveals the panel.
    def show : Nil
      ROWS.each do |action, _key|
        hotkey = @hotkeys.key_for(action)
        @keys[action].value = hotkey ? HotkeyMap.display_name(hotkey) : UNBOUND
      end
      @handle.show
    end

    def hide : Nil
      @handle.hide
    end

    def visible? : Bool
      @handle.app.command(:wm, "state", @handle.path) == "normal"
    end

    # The key text currently displayed for action - what a user reads
    # off the panel, for a spec to check against a HotkeyMap.
    def key_text(action : Symbol) : String
      @keys[action].value.as(String)
    end
  end
end
