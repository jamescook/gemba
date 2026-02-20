# frozen_string_literal: true

module Gemba
  # Floating hotkey reference panel toggled by pressing '?'.
  #
  # Non-modal — no grab, no focus steal. Positioned to the right of the
  # main window via ChildWindow#position_near_parent. AppController pauses
  # emulation while the panel is visible and restores play on close.
  class HelpWindow
    include ChildWindow
    include Locale::Translatable

    TOP = '.help_window'

    def initialize(app:, hotkeys:)
      @app     = app
      @hotkeys = hotkeys
      build_toplevel(translate('settings.hotkeys'), geometry: '220x400') { build_ui }
    end

    def show    = show_window(modal: false)
    def hide    = hide_window(modal: false)
    def visible? = @app.tcl_eval("wm state #{TOP}") == 'normal'

    private

    def build_ui
      f = "#{TOP}.f"
      @app.command('ttk::frame', f, padding: 8)
      @app.command(:pack, f, fill: :both, expand: 1)

      @app.command('ttk::label', "#{f}.title",
        text: translate('settings.hotkeys'),
        font: '{TkDefaultFont} 11 bold')
      @app.command(:pack, "#{f}.title", pady: [0, 4])

      @app.command('ttk::separator', "#{f}.sep", orient: :horizontal)
      @app.command(:pack, "#{f}.sep", fill: :x, pady: [0, 6])

      Settings::HotkeysTab::LOCALE_KEYS.each do |action, locale_key|
        row = "#{f}.row_#{action}"
        @app.command('ttk::frame', row)
        @app.command(:pack, row, fill: :x, pady: 1)

        act_lbl = "#{row}.act"
        key_lbl = "#{row}.key"

        key_text = HotkeyMap.display_name(@hotkeys.key_for(action))

        @app.command('ttk::label', act_lbl, text: translate(locale_key), anchor: :w)
        @app.command('ttk::label', key_lbl, text: key_text, anchor: :e,
          font: '{TkFixedFont} 9')

        @app.command(:grid, act_lbl, row: 0, column: 0, sticky: :w)
        @app.command(:grid, key_lbl, row: 0, column: 1, sticky: :e)
        @app.command(:grid, :columnconfigure, row, 0, weight: 1)
        @app.command(:grid, :columnconfigure, row, 1, weight: 0)
      end
    end
  end
end
