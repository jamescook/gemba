require "./rom_info"
require "./save_state_manager"
require "./paths"
require "./locale"

module Gemba
  # Right-click row/card menu + actions shared between GamePickerFrame
  # (the box-art grid) and ListPickerFrame (the sortable table) - ruby
  # duplicates this near-verbatim between its own two picker classes
  # (game_picker_frame.rb/list_picker_frame.rb); shared here instead,
  # since - unlike the independently-distributed widget shards, where
  # duplication is deliberate - both consumers live in the same app.
  #
  # An including class must provide @app : Tryst::App, @library :
  # RomLibrary, @overrides : RomOverrides?, @config : Config, and
  # @on_view_changed : String -> Nil, plus a #refresh method (called
  # after a remove).
  module PickerRowActions
    private def quick_save_slot : Int32
      @config.quick_save_slot
    end

    # Real File I/O (called from a <Button-3> bind, on the main thread) -
    # #off_thread like every other blocking call in this app.
    private def quick_save_exists?(rom_info : RomInfo, slot : Int32) : Bool
      return false if rom_info.rom_id.empty?

      state_dir = File.join(Paths.states_dir, rom_info.rom_id)
      @app.off_thread { File.exists?(SaveStateManager.state_path(state_dir, slot)) }
    end

    private def remove_rom(rom_info : RomInfo) : Nil
      @app.off_thread { @library.remove(rom_info.path) }
      refresh
    end

    # A no-op if @overrides isn't configured - the menu item still
    # exists, but does nothing. #boxart_picked (a no-op by default) is
    # the hook for updating a visible card image afterward -
    # ListPickerFrame shows no boxart at all, so it never needs to
    # override it; GamePickerFrame does.
    private def pick_custom_boxart(rom_info : RomInfo) : Nil
      overrides = @overrides
      return unless overrides
      return if rom_info.rom_id.empty?

      chosen = @app.choose_open_file(filetypes: [{"PNG Images", ".png"}])
      return unless chosen

      dest = @app.off_thread { overrides.set_custom_boxart(rom_info.rom_id, chosen.as(String)) }
      boxart_picked(rom_info, dest)
    end

    private def boxart_picked(rom_info : RomInfo, dest : String) : Nil
    end

    # Shared between both views: Play / Quick Load (disabled if that
    # slot has no save) / Set Boxart / Remove.
    private def popup_rom_menu(menu_path : String, rom_info : RomInfo,
                               on_select : String -> Nil, on_quick_load : Proc(String, Int32, Nil)) : Nil
      @app.menu(menu_path)
      @app.command(menu_path, :delete, 0, :end)

      @app.command(menu_path, :add, :command, label: Locale.translate("game_picker.menu.play"),
        command: @app.callback { on_select.call(rom_info.path) })

      slot = quick_save_slot
      @app.command(menu_path, :add, :command, label: Locale.translate("game_picker.menu.quick_load"),
        state: quick_save_exists?(rom_info, slot) ? :normal : :disabled,
        command: @app.callback { on_quick_load.call(rom_info.path, slot) })

      @app.command(menu_path, :add, :command, label: Locale.translate("game_picker.menu.set_boxart"),
        command: @app.callback { pick_custom_boxart(rom_info) })

      @app.command(menu_path, :add, :separator)
      @app.command(menu_path, :add, :command, label: Locale.translate("game_picker.menu.remove"),
        command: @app.callback { remove_rom(rom_info) })

      @app.popup_menu(menu_path, @app.winfo.pointerx, @app.winfo.pointery)
    end

    # Identical between both picker views (see Config#picker_view).
    private def popup_view_menu(menu_path : String, btn_path : String) : Nil
      @app.menu(menu_path)
      @app.command(menu_path, :delete, 0, :end)
      current = @config.picker_view

      @app.command(menu_path, :add, :command,
        label: "#{current == "grid" ? "✓ " : "  "}#{Locale.translate("picker.toolbar.boxart_view")}",
        command: @app.callback { @on_view_changed.call("grid") })
      @app.command(menu_path, :add, :command,
        label: "#{current == "list" ? "✓ " : "  "}#{Locale.translate("picker.toolbar.list_view")}",
        command: @app.callback { @on_view_changed.call("list") })

      x = @app.winfo.rootx(btn_path)
      y = @app.winfo.rooty(btn_path)
      h = @app.winfo.height(btn_path)
      @app.popup_menu(menu_path, x, y + h)
    end

    # Builds the ⚙ toolbar (a separator + a frame holding the gear
    # button) both picker views place identically - returned rather than
    # placed, since ListPickerFrame's own children use grid and
    # GamePickerFrame's use pack: whichever geometry manager the caller
    # already uses for parent's OTHER children, it grids/packs these
    # two into it. The gear button's own child (nothing else lives in
    # toolbar) is always packed - that's toolbar's own separate scope,
    # not parent's, so it never conflicts either way.
    private def build_gear_toolbar(parent : String) : {Tryst::Widget, Tryst::Widget}
      sep = @app.create_widget("ttk::separator", path: "#{parent}.sep", parent: parent, orient: :horizontal)
      toolbar = @app.create_widget("ttk::frame", path: "#{parent}.toolbar", parent: parent, padding: [4, 2])

      gear_btn = @app.create_widget("ttk::button", path: "#{toolbar.path}.gear",
        parent: toolbar.path, text: "⚙", width: 1)
      gear_menu = "#{toolbar.path}.gearmenu"
      gear_btn.command(:configure, command: @app.callback { popup_view_menu(gear_menu, gear_btn.path) })
      gear_btn.pack(side: :right)

      {sep, toolbar}
    end
  end
end
