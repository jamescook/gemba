require "tryst"
require "./rom_library"
require "./rom_info"
require "./boxart_fetcher"
require "./rom_overrides"
require "./config"
require "./frame_stack"
require "./picker_row_actions"
require "./locale"

module Gemba
  # Startup frame showing a 4x4 grid of ROM cards - box art (if
  # available), title, platform. Ported from ruby's game_picker_frame.rb.
  # Left-click a populated card to play; right-click for the same
  # Play/Quick Load/Set Boxart/Remove menu ListPickerFrame offers (see
  # PickerRowActions); the gear menu toggles to ListPickerFrame's table.
  class GamePickerFrame
    include Frame
    include PickerRowActions

    COLS  = 4
    ROWS  = 4
    SLOTS = COLS * ROWS

    IMG_SIZE = 128 # height/width of the scaled card image, in pixels

    PLACEHOLDER_PNG = File.expand_path("../../assets/placeholder_boxart.png", __DIR__)

    CARD_BG  = "#2a2a2a"
    TITLE_FG = "#cccccc"
    PLAT_FG  = "#888888"

    record Card, frame : Tryst::Widget, image : Tryst::Widget, title : Tryst::Widget, platform : Tryst::Widget

    # Real public getters, not spec reflection - see ListPickerFrame's
    # own comment on this same pattern.
    getter path : String
    getter open_button : Tryst::Widget
    getter cards : Hash(Int32, Card)

    @photos = {} of String => Tryst::Photo
    @cards = {} of Int32 => Card

    def initialize(@app : Tryst::App, parent : String, @library : RomLibrary, @config : Config,
                   @fetcher : BoxartFetcher?, @overrides : RomOverrides?,
                   @on_open_rom : -> Nil, @on_select : String -> Nil,
                   @on_quick_load : Proc(String, Int32, Nil), @on_view_changed : String -> Nil)
      base = parent == "." ? "" : parent
      @path = "#{base}.gemba_game_picker"
      @app.command(:frame, @path)

      # A transparent placeholder gives every card a fixed pixel size
      # whether or not box art has been fetched yet - loaded once, here,
      # shared by every hollow/unresolved card slot.
      @app.command(:image, :create, :photo, "gemba_boxart_placeholder", file: PLACEHOLDER_PNG)

      @cards_frame = @app.create_widget("ttk::frame", parent: @path, padding: 16)
      @cards_frame.pack(fill: :both, expand: 1)
      build_cards

      @open_button = @app.create_widget("ttk::button", parent: @path,
        text: Locale.translate("menu.open_rom"), command: @app.callback { @on_open_rom.call })
      @open_button.pack(side: :bottom, pady: 12)

      sep, toolbar = build_gear_toolbar(@path)
      sep.pack(fill: :x)
      toolbar.pack(fill: :x)

      refresh
    end

    # Re-reads the library (in memory - RomLibrary#all does no I/O) and
    # populates every card's title/platform/click-bindings immediately -
    # call after a new ROM is opened so it shows up next time the picker
    # is shown. Box art resolution (a real #off_thread round trip -
    # BoxartFetcher/RomOverrides cache checks are File I/O) is kicked
    # off separately, right after: bundling both into one pass adds
    # visible startup lag the list view, which has no art to resolve,
    # never has.
    def refresh : Nil
      roms = @library.all.first(SLOTS)

      SLOTS.times do |i|
        entry = roms[i]?
        card = @cards[i]
        entry ? populate_card(card, RomInfo.from_rom(entry)) : hollow_card(card)
      end

      load_boxart(roms) if @fetcher || @overrides
    end

    def show : Nil
      @app.command(:pack, @path, fill: :both, expand: 1)
      refresh
    end

    def hide : Nil
      @app.command(:pack, :forget, @path)
    end

    def cleanup : Nil
      @photos.each_value(&.delete)
      @photos.clear
    end

    private def build_cards : Nil
      SLOTS.times do |i|
        row = i // COLS
        col = i % COLS

        cell_path = "#{@cards_frame.path}.card#{i}"
        cell = @app.create_widget(:frame, path: cell_path, parent: @cards_frame.path,
          relief: :groove, borderwidth: 1, padx: 4, pady: 4, bg: CARD_BG)
        cell.grid(row: row, column: col, padx: 6, pady: 6, sticky: "nsew")

        image = @app.create_widget(:label, path: "#{cell_path}.image", parent: cell_path, bg: CARD_BG,
          anchor: :center, image: "gemba_boxart_placeholder")
        image.pack(fill: :x)

        title = @app.create_widget(:label, path: "#{cell_path}.title", parent: cell_path, text: "", anchor: :center,
          bg: CARD_BG, fg: TITLE_FG, font: "{TkDefaultFont} 10", justify: :center, wraplength: IMG_SIZE)
        title.pack(fill: :x, pady: [4, 2])

        platform = @app.create_widget(:label, path: "#{cell_path}.platform", parent: cell_path, text: "",
          anchor: :center, bg: CARD_BG, fg: PLAT_FG, font: "{TkDefaultFont} 8")
        platform.pack(fill: :x, pady: [0, 4])

        @cards[i] = Card.new(cell, image, title, platform)
      end

      COLS.times { |col| @app.command(:grid, :columnconfigure, @cards_frame.path, col, weight: 1) }
      ROWS.times { |row| @app.command(:grid, :rowconfigure, @cards_frame.path, row, weight: 1) }
    end

    # Title/platform/styling/click-bindings only - none of this needs
    # box art resolved first (rom_info here was built without a fetcher/
    # overrides, so #boxart_path is always nil regardless - see #refresh).
    # The image starts at the placeholder; #load_boxart swaps it in
    # later if there's real art to show.
    private def populate_card(card : Card, rom_info : RomInfo) : Nil
      card.image.command(:configure, bg: CARD_BG, image: "gemba_boxart_placeholder")
      card.title.command(:configure, text: rom_info.title, fg: TITLE_FG, bg: CARD_BG)
      card.platform.command(:configure, text: rom_info.platform, fg: PLAT_FG, bg: CARD_BG)
      card.frame.command(:configure, relief: :groove, bg: CARD_BG)

      {card.frame, card.image, card.title, card.platform}.each do |widget|
        widget.bind(:click) { |_v, _s| @on_select.call(rom_info.path) }
        widget.bind(:right_click) { |_v, _s| popup_rom_menu("#{card.frame.path}.ctx", rom_info, @on_select, @on_quick_load) }
      end
    end

    # Resolves and applies real box art without blocking mainloop -
    # spawn, not just #off_thread alone, is what actually achieves that:
    # #off_thread blocks whichever fiber calls it until the result comes
    # back, and calling it directly from a callback Tcl's own event
    # dispatch invokes (a bind, a button -command, an #after callback -
    # all of them) makes THAT block mainloop's own event processing for
    # the round trip, timers included. spawn is what BoxartFetcher#fetch
    # already relies on for the identical reason (see its own comment) -
    # the spawned fiber is what off_thread suspends, not mainloop's own.
    private def load_boxart(roms : Array(RomLibrary::Entry)) : Nil
      spawn do
        resolved = @app.off_thread do
          roms.map do |entry|
            info = RomInfo.from_rom(entry, fetcher: @fetcher, overrides: @overrides)
            {info, info.boxart_path}
          end
        end

        resolved.each_with_index do |(rom_info, boxart_path), i|
          apply_boxart(@cards[i], rom_info, boxart_path)
        end
      end
    end

    private def apply_boxart(card : Card, rom_info : RomInfo, boxart_path : String?) : Nil
      key = photo_key(rom_info)

      if boxart_path
        if photo = @photos[key]?
          card.image.command(:configure, image: photo.name)
        else
          set_card_image(card, key, boxart_path)
        end
      elsif rom_info.has_official_entry && (fetcher = @fetcher) && !rom_info.game_code.empty?
        fetcher.fetch(rom_info.game_code) { |path| set_card_image(card, key, path) }
      end
    end

    private def hollow_card(card : Card) : Nil
      card.image.command(:configure, image: "gemba_boxart_placeholder", bg: CARD_BG)
      card.title.command(:configure, text: "", fg: CARD_BG, bg: CARD_BG)
      card.platform.command(:configure, text: "", bg: CARD_BG)
      card.frame.command(:configure, relief: :ridge, bg: CARD_BG)

      {card.frame, card.image, card.title, card.platform}.each do |widget|
        widget.unbind(:click)
        widget.unbind(:right_click)
      end
    end

    # Cache key for @photos - rom_id once known, falling back to
    # game_code, falling back to the ROM's own path (always unique) so
    # two not-yet-identified entries never collide on the same "" key.
    private def photo_key(rom_info : RomInfo) : String
      return rom_info.rom_id unless rom_info.rom_id.empty?
      return rom_info.game_code unless rom_info.game_code.empty?
      rom_info.path
    end

    # Tk-native photo I/O (Photo.new/`image width/height`/subsample
    # copy) goes through the interpreter's FFI, not Crystal's File.*
    # syscall path, so this is safe to call directly on the main thread
    # without #off_thread.
    private def set_card_image(card : Card, key : String, path : String) : Nil
      full = Tryst::Photo.new(@app, file: path)
      w = @app.command(:image, :width, full.name).to_i
      h = @app.command(:image, :height, full.name).to_i
      factor = {(w / IMG_SIZE.to_f).ceil.to_i, (h / IMG_SIZE.to_f).ceil.to_i, 1}.max

      small = Tryst::Photo.new(@app)
      small.command(:copy, full.name, subsample: factor)
      full.delete

      old = @photos[key]?
      @photos[key] = small
      card.image.command(:configure, image: small.name)
      old.try(&.delete)
    rescue ex : Exception
      STDERR.puts "[Gemba] GamePickerFrame: boxart load failed for #{key}: #{ex.message}"
    end
  end
end
