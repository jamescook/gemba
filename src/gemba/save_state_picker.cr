require "tryst"
require "tryst/ui"
require "./save_state_manager"
require "./locale"

module Gemba
  # 10-slot grid picker for save states. A DOUBLE-click on a populated
  # slot loads it, a double-click on an empty one saves to it - a single
  # click, or just closing the window, never triggers either. Raw App
  # calls for its content - a concrete Tryst::App/Photo is needed to
  # load per-slot thumbnails, not just the DSL's narrow AppContract (see
  # SettingsWindow's own class comment).
  #
  # Built once (see MainWindow) and #refresh-ed on every #show.
  class SaveStatePicker
    SLOTS   =  10
    COLS    =   5
    THUMB_W = 120
    THUMB_H =  80

    private record Cell, frame : String, thumb : String, info : String, time : String
    private record SlotInfo, populated : Bool, has_thumbnail : Bool, mtime : String

    getter handle : Tryst::UI::Handle

    # The shared placeholder image's Tk name - what an empty/previewless
    # cell shows. Public so specs can tell "still the placeholder" from
    # "a real thumbnail arrived".
    getter blank_thumb : String

    # Seam for specs: the delete confirmation is a WM-modal
    # tk_messageBox, undriveable headless - same seam shape (and
    # reason) as PatcherWindow#overwrite_prompt. Takes the slot, returns
    # whether to go ahead.
    setter delete_prompt : (Int32 -> Bool)? = nil

    @on_save : (Int32 -> Nil)? = nil
    @on_load : (Int32 -> Nil)? = nil
    @on_close : (-> Nil)? = nil
    @state_dir : String = ""
    @quick_slot : Int32 = 1
    @slots : Array(SlotInfo)
    @thumbnails : Array(Tryst::Photo?)

    def initialize(@app : Tryst::App, @handle : Tryst::UI::Handle)
      @slots = Array.new(SLOTS) { SlotInfo.new(false, false, "") }
      @thumbnails = Array(Tryst::Photo?).new(SLOTS, nil)

      path = @handle.path
      @blank_photo = Tryst::Photo.new(@app, width: THUMB_W, height: THUMB_H)
      @blank_thumb = @blank_photo.name

      grid = "#{path}.grid"
      @app.command("ttk::frame", grid, padding: 8)
      @app.command(:pack, grid, fill: :x)

      @cells = Array(Cell).new(SLOTS) { |i| build_cell(grid, i + 1) }
      COLS.times { |col| @app.command(:grid, :columnconfigure, grid, col, weight: 1) }

      close_row = "#{path}.close_row"
      @app.command("ttk::frame", close_row)
      @app.command(:pack, close_row, fill: :x, pady: [0, 8])
      close_button = "#{close_row}.close"
      @app.command("ttk::button", close_button, text: Locale.translate("picker.close"),
        command: ->(_v : Array(String), _s : Tryst::CallbackSignal) { @on_close.try(&.call); nil })
      @app.command(:pack, close_button)
    end

    private def build_cell(grid : String, slot : Int32) : Cell
      row = (slot - 1) // COLS
      col = (slot - 1) % COLS

      cell = "#{grid}.slot#{slot}"
      @app.command("ttk::frame", cell, relief: :groove, borderwidth: 2, padding: 4)
      @app.command(:grid, cell, row: row, column: col, padx: 4, pady: 4, sticky: "new")

      thumb = "#{cell}.thumb"
      @app.command(:label, thumb, image: @blank_thumb, compound: :center,
        background: "#1a1a2e", foreground: "#666666",
        text: Locale.translate("picker.empty"), anchor: :center)
      @app.command(:pack, thumb, pady: [0, 4])

      info = "#{cell}.info"
      @app.command("ttk::label", info, text: Locale.translate("picker.slot", n: slot), anchor: :center)
      @app.command(:pack, info, fill: :x)

      time_lbl = "#{cell}.time"
      @app.command("ttk::label", time_lbl, text: "", anchor: :center)
      @app.command(:pack, time_lbl, fill: :x)

      # Double-click, not single - a single click (or just closing the
      # window afterward) must never trigger a save/load. Right-click
      # opens the per-slot menu, the explicit route to every action
      # double-click can't express (overwrite, delete).
      {cell, thumb, info, time_lbl}.each do |widget|
        @app.bind(widget, :double_click) { |_v, _s| on_slot_click(slot) }
        @app.bind(widget, :right_click) { |_v, _s| popup_slot_menu(slot) }
      end

      Cell.new(cell, thumb, info, time_lbl)
    end

    def on_save(&block : Int32 -> Nil) : Nil
      @on_save = block
    end

    def on_load(&block : Int32 -> Nil) : Nil
      @on_load = block
    end

    # Fires when the Close button is clicked - wire this to
    # ModalStack#pop, same reason (and same shape) as RomInfoWindow's
    # own #on_close.
    def on_close(&block : -> Nil) : Nil
      @on_close = block
    end

    # Re-scans state_dir for every slot's .ss/.png and redraws all ten
    # cells - call before showing. quick_slot highlights that cell's
    # border, matching the current Config#quick_save_slot.
    def refresh(state_dir : String, quick_slot : Int32) : Nil
      @state_dir = state_dir
      @quick_slot = quick_slot

      # File.exists?/File.info are blocking calls that don't belong on
      # Tk's own thread (see App#off_thread's own doc comment) - this
      # runs from a live menu click/hotkey, well after @app exists, same
      # as MainWindow#take_screenshot's own Dir.mkdir_p/Time.local.
      @slots = @app.off_thread { scan(state_dir) }
      @slots.each_with_index { |info, i| update_cell(i + 1, info) }
    end

    private def scan(state_dir : String) : Array(SlotInfo)
      (1..SLOTS).map do |slot|
        ss = SaveStateManager.state_path(state_dir, slot)
        populated = File.exists?(ss)
        mtime = populated ? File.info(ss).modification_time.to_local.to_s("%b %d %H:%M") : ""
        has_thumb = populated &&
                    (png_file?(ss) || File.exists?(SaveStateManager.screenshot_path(state_dir, slot)))
        SlotInfo.new(populated, has_thumb, mtime)
      end
    end

    PNG_MAGIC = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    # mgba (built with USE_PNG, as the vendored build is) writes states
    # saved with the Screenshot flag as real PNG files - the screenshot
    # is the visible image, the emulator state rides in private
    # gbAs/gbAx chunks Tk's PNG codec ignores. So the state file IS its
    # own thumbnail (see Core#save_state_to_file). Blocking I/O - runs
    # inside #scan's off_thread hop, same as its File.exists? calls.
    private def png_file?(path : String) : Bool
      header = Bytes.new(PNG_MAGIC.size)
      read = File.open(path, &.read(header))
      read == PNG_MAGIC.size && header == PNG_MAGIC
    rescue IO::Error
      false
    end

    private def update_cell(slot : Int32, info : SlotInfo) : Nil
      cell = @cells[slot - 1]

      @thumbnails[slot - 1].try(&.delete)
      @thumbnails[slot - 1] = info.has_thumbnail ? load_thumbnail(slot) : nil

      unless @thumbnails[slot - 1]
        no_preview = info.populated ? Locale.translate("picker.no_preview") : Locale.translate("picker.empty")
        @app.command(cell.thumb, :configure, image: @blank_thumb, compound: :center, text: no_preview)
      end

      @app.command(cell.time, :configure, text: info.mtime)

      highlighted = slot == @quick_slot
      @app.command(cell.frame, :configure,
        relief: highlighted ? "solid" : "groove", borderwidth: highlighted ? 3 : 2)
    end

    # The state file itself first (it's a PNG with the screenshot as its
    # visible image - see #png_file?), then the legacy separate
    # state<slot>.png older sessions wrote. Returns nil (leaving the
    # blank placeholder up) if neither loads.
    private def load_thumbnail(slot : Int32) : Tryst::Photo?
      thumb = photo_thumb(SaveStateManager.state_path(@state_dir, slot)) ||
              photo_thumb(SaveStateManager.screenshot_path(@state_dir, slot))
      return unless thumb

      cell = @cells[slot - 1]
      @app.command(cell.thumb, :configure, image: thumb.name, compound: :none, text: "")
      thumb
    end

    # Returns nil if the file is missing or Tk can't decode it, rather
    # than raising - a corrupt/half-written file shouldn't take the
    # whole picker down.
    private def photo_thumb(path : String) : Tryst::Photo?
      source = Tryst::Photo.new(@app, file: path)
      thumb = Tryst::Photo.new(@app, width: THUMB_W, height: THUMB_H)
      thumb.command(:copy, source.name, subsample: 2)
      source.delete
      thumb
    rescue Tryst::TclError
      nil
    end

    # Populated slot: Load / Overwrite / Delete…; empty slot: Save.
    # Overwrite is the piece double-click can't express - its populated
    # gesture is always load - so without this a slot could only ever
    # be saved to once. Same menu pattern as PickerRowActions'
    # popup_rom_menu.
    private def popup_slot_menu(slot : Int32) : Nil
      menu_path = "#{@cells[slot - 1].frame}.ctx"
      @app.menu(menu_path)
      @app.command(menu_path, :delete, 0, :end)

      if @slots[slot - 1].populated
        @app.command(menu_path, :add, :command, label: Locale.translate("picker.menu.load"),
          command: @app.callback { @on_load.try(&.call(slot)) })
        @app.command(menu_path, :add, :command, label: Locale.translate("picker.menu.overwrite"),
          command: @app.callback { @on_save.try(&.call(slot)) })
        @app.command(menu_path, :add, :separator)
        @app.command(menu_path, :add, :command, label: Locale.translate("picker.menu.delete"),
          command: @app.callback { delete_slot(slot) })
      else
        @app.command(menu_path, :add, :command, label: Locale.translate("picker.menu.save"),
          command: @app.callback { @on_save.try(&.call(slot)) })
      end

      @app.popup_menu(menu_path, @app.winfo.pointerx, @app.winfo.pointery)
    end

    # Deletes slot's state after confirmation (see #delete_prompt) -
    # the .ss itself, its backup rotation, and any legacy thumbnail
    # PNG - then redraws in place. Public so specs can drive it without
    # a WM-modal menu/messageBox round-trip; the context menu is the
    # production caller.
    def delete_slot(slot : Int32) : Nil
      return unless @slots[slot - 1].populated

      confirmed = if prompt = @delete_prompt
                    prompt.call(slot)
                  else
                    @app.message_box(Locale.translate("picker.delete_msg", n: slot),
                      title: Locale.translate("picker.delete_title"),
                      icon: :warning, type: :yesno, default: :no) == :yes
                  end
      return unless confirmed

      ss = SaveStateManager.state_path(@state_dir, slot)
      png = SaveStateManager.screenshot_path(@state_dir, slot)
      @app.off_thread do
        File.delete?(ss)
        File.delete?("#{ss}.bak")
        File.delete?(png)
      end
      refresh(@state_dir, @quick_slot)
    end

    private def on_slot_click(slot : Int32) : Nil
      if @slots[slot - 1].populated
        @on_load.try(&.call(slot))
      else
        @on_save.try(&.call(slot))
      end
    end
  end
end
