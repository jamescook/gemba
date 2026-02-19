# frozen_string_literal: true


module Gemba
  # Startup frame showing a 4×4 grid of ROM cards.
  #
  # Each card displays box art (if available), ROM title, and platform.
  # Clicking a populated card emits :rom_selected on the bus.
  # Right-clicking a populated card shows a context menu (Play / Set Boxart).
  # Pure Tk — no SDL2.
  class GamePickerFrame
    include BusEmitter
    include Locale::Translatable

    COLS          = 4
    ROWS          = 4
    SLOTS         = COLS * ROWS
    IMG_SUBSAMPLE    = 4   # 512px ÷ 4 = 128px per card
    IMG_SIZE         = 128 # height/width of the scaled image in pixels
    PLACEHOLDER_PNG  = File.expand_path("../../assets/placeholder_boxart.png", __dir__)

    # Aspect ratio for wm aspect lock when picker is visible (width:height).
    # 3:4 gives enough vertical room for image + title + platform label.
    PICKER_ASPECT_W = 3
    PICKER_ASPECT_H = 4

    # Default and minimum picker window dimensions (must satisfy PICKER_ASPECT ratio)
    PICKER_DEFAULT_W = 640
    PICKER_DEFAULT_H = 854   # 640 * 4/3, rounded up
    PICKER_MIN_W     = 480
    PICKER_MIN_H     = 640

    def initialize(app:, rom_library:, boxart_fetcher: nil, rom_overrides: nil)
      @app      = app
      @rom_library = rom_library
      @fetcher  = boxart_fetcher
      @overrides = rom_overrides
      @built    = false
      @cards    = {}   # index => { frame:, image:, title:, platform:, photo: }
      @photos   = {}   # key => Tk image name (kept alive to prevent GC)
    end

    def show
      build_ui unless @built
      refresh
      @app.command(:pack, @grid, fill: :both, expand: 1)
    end

    def hide
      @app.command(:pack, :forget, @grid) rescue nil
    end

    def cleanup
      @photos.each_value { |name| @app.command(:image, :delete, name) rescue nil }
      @photos.clear
    end

    def receive(event, **args)
      case event
      when :refresh then refresh
      end
    end

    def aspect_ratio = [PICKER_ASPECT_W, PICKER_ASPECT_H]
    def rom_loaded? = false
    def sdl2_ready? = false
    def paused? = false

    private

    def build_ui
      @grid = '.game_picker'
      @app.command('ttk::frame', @grid, padding: 16)

      # Capture the system window background color so hollow cards blend in
      # rather than appearing as stark black rectangles.
      @empty_bg = @app.tcl_eval(". cget -background")

      # Load a transparent 128×128 placeholder once — gives all image labels
      # a fixed pixel size whether or not box art has been fetched yet.
      @app.command(:image, :create, :photo, 'boxart_placeholder', file: PLACEHOLDER_PNG)

      SLOTS.times do |i|
        row = i / COLS
        col = i % COLS

        cell = "#{@grid}.card#{i}"
        @app.command(:frame, cell, relief: :groove, borderwidth: 2,
          padx: 4, pady: 4, bg: '#2a2a2a')
        @app.command(:grid, cell, row: row, column: col, padx: 6, pady: 6, sticky: :nsew)

        img_lbl = "#{cell}.img"
        @app.command(:label, img_lbl, bg: '#2a2a2a', anchor: :center, image: 'boxart_placeholder')
        @app.command(:pack, img_lbl, fill: :x)

        title_lbl = "#{cell}.title"
        @app.command(:label, title_lbl, text: '', anchor: :center,
          bg: '#2a2a2a', fg: '#cccccc',
          font: '{TkDefaultFont} 10')
        @app.command(:pack, title_lbl, fill: :x, pady: [4, 2])

        plat_lbl = "#{cell}.plat"
        @app.command(:label, plat_lbl, text: '', anchor: :center,
          bg: '#2a2a2a', fg: '#888888',
          font: '{TkDefaultFont} 8')
        @app.command(:pack, plat_lbl, fill: :x, pady: [0, 4])

        @cards[i] = { frame: cell, image: img_lbl, title: title_lbl, platform: plat_lbl }
      end

      # Make columns and rows expand evenly
      COLS.times { |c| @app.command(:grid, :columnconfigure, @grid, c, weight: 1) }
      ROWS.times { |r| @app.command(:grid, :rowconfigure, @grid, r, weight: 1) }

      @built = true
    end

    def refresh
      roms = @rom_library.all.first(SLOTS)

      SLOTS.times do |i|
        card = @cards[i]
        rom  = roms[i]

        if rom
          rom_info = RomInfo.from_rom(rom, fetcher: @fetcher, overrides: @overrides)
          populate_card(card, rom_info)
        else
          hollow_card(card)
        end
      end
    end

    def populate_card(card, rom_info)
      @app.command(card[:image],    :configure, bg: '#2a2a2a')
      @app.command(card[:title],    :configure, text: rom_info.title,    fg: '#cccccc', bg: '#2a2a2a')
      @app.command(card[:platform], :configure, text: rom_info.platform, fg: '#888888', bg: '#2a2a2a')
      @app.command(card[:frame],    :configure, relief: :groove, bg: '#2a2a2a')

      # Determine which image to show
      key = rom_info.rom_id || rom_info.game_code

      if rom_info.boxart_path
        # Custom override or cached art — load immediately
        if @photos.key?(key)
          @app.command(card[:image], :configure, image: @photos[key])
        else
          set_card_image(card, key, rom_info.boxart_path)
        end
      elsif rom_info.has_official_entry && @fetcher && rom_info.game_code
        # No art yet but libretro has an entry — kick off async fetch
        @app.command(card[:image], :configure, image: 'boxart_placeholder')
        @fetcher.fetch(rom_info.game_code) { |path| set_card_image(card, key, path) }
      else
        @app.command(card[:image], :configure, image: 'boxart_placeholder')
      end

      # Left-click → play
      click = proc { emit(:rom_selected, rom_info.path) }
      @app.command(:bind, card[:frame],    '<Button-1>', click)
      @app.command(:bind, card[:image],    '<Button-1>', click)
      @app.command(:bind, card[:title],    '<Button-1>', click)
      @app.command(:bind, card[:platform], '<Button-1>', click)

      # Right-click → context menu
      bind_context_menu(card, rom_info)
    end

    def hollow_card(card)
      @app.command(card[:image],    :configure, image: 'boxart_placeholder', bg: @empty_bg)
      @app.command(card[:title],    :configure, text: '', fg: @empty_bg,     bg: @empty_bg)
      @app.command(card[:platform], :configure, text: '',                    bg: @empty_bg)
      @app.command(card[:frame],    :configure, relief: :ridge,              bg: @empty_bg)

      [:frame, :image, :title, :platform].each do |k|
        @app.command(:bind, card[k], '<Button-1>', '')
        @app.command(:bind, card[k], '<Button-3>', '')
      end
    end

    def bind_context_menu(card, rom_info)
      handler = proc { post_card_menu(card, rom_info) }
      @app.command(:bind, card[:frame],    '<Button-3>', handler)
      @app.command(:bind, card[:image],    '<Button-3>', handler)
      @app.command(:bind, card[:title],    '<Button-3>', handler)
      @app.command(:bind, card[:platform], '<Button-3>', handler)
    end

    def post_card_menu(card, rom_info)
      menu = "#{card[:frame]}.ctx"
      exists = @app.tcl_eval("winfo exists #{menu}") == '1'
      @app.command(:menu, menu, tearoff: 0) unless exists
      @app.command(menu, :delete, 0, :end)
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.play'),
        command: proc { emit(:rom_selected, rom_info.path) })
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.set_boxart'),
        command: proc { pick_custom_boxart(card, rom_info) })
      @app.command(menu, :add, :separator)
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.remove'),
        command: proc { remove_rom(rom_info) })
      @app.tcl_eval("tk_popup #{menu} [winfo pointerx .] [winfo pointery .]")
    end

    def remove_rom(rom_info)
      @rom_library.remove(rom_info.rom_id)
      @rom_library.save!
      refresh
    end

    def pick_custom_boxart(card, rom_info)
      return unless @overrides
      filetypes = '{{PNG Images} {.png}}'
      path = @app.tcl_eval("tk_getOpenFile -filetypes {#{filetypes}}")
      return if path.to_s.strip.empty?
      dest = @overrides.set_custom_boxart(rom_info.rom_id, path)
      key  = rom_info.rom_id || rom_info.game_code
      set_card_image(card, key, dest)
    end

    def set_card_image(card, key, path)
      # Load full-size photo, scale to fit within IMG_SIZE, delete the original.
      # Subsample factor is computed from actual dimensions so arbitrary-sized
      # user images (e.g. custom boxart) don't break the card layout.
      full_name  = "boxart_full_#{key}"
      small_name = "boxart_#{key}"

      @app.command(:image, :create, :photo, full_name, file: path)
      w = @app.tcl_eval("image width #{full_name}").to_i
      h = @app.tcl_eval("image height #{full_name}").to_i
      factor = [[(w.to_f / IMG_SIZE).ceil, (h.to_f / IMG_SIZE).ceil].max, 1].max

      @app.command(:image, :create, :photo, small_name)
      @app.command(small_name, :copy, full_name, subsample: factor)
      @app.command(:image, :delete, full_name)

      old = @photos[key]
      @photos[key] = small_name
      @app.command(card[:image], :configure, image: small_name)
      @app.command(:image, :delete, old) if old && old != small_name
    rescue => e
      Gemba.log(:warn) { "BoxArt image load failed for #{key}: #{e.message}" }
    end
  end
end
