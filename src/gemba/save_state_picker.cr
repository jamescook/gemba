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
      @blank_thumb = "#{path}_blank_thumb"
      @app.tcl_eval("image create photo #{@blank_thumb} -width #{THUMB_W} -height #{THUMB_H}")

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
      # window afterward) must never trigger a save/load.
      {cell, thumb, info, time_lbl}.each do |widget|
        @app.bind(widget, :double_click) { |_v, _s| on_slot_click(slot) }
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
        png = SaveStateManager.screenshot_path(state_dir, slot)
        populated = File.exists?(ss)
        mtime = populated ? File.info(ss).modification_time.to_local.to_s("%b %d %H:%M") : ""
        SlotInfo.new(populated, populated && File.exists?(png), mtime)
      end
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

    # Returns nil (leaving the blank placeholder up) if the PNG is
    # missing or unreadable, rather than raising - a corrupt/half-written
    # thumbnail shouldn't take the whole picker down.
    private def load_thumbnail(slot : Int32) : Tryst::Photo?
      cell = @cells[slot - 1]
      png_path = SaveStateManager.screenshot_path(@state_dir, slot)

      source = Tryst::Photo.new(@app, file: png_path)
      thumb = Tryst::Photo.new(@app, width: THUMB_W, height: THUMB_H)
      thumb.command(:copy, source.name, subsample: 2)
      source.delete

      @app.command(cell.thumb, :configure, image: thumb.name, compound: :none, text: "")
      thumb
    rescue Tryst::TclError
      nil
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
