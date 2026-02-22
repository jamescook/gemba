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
    PICKER_DEFAULT_W = 768
    PICKER_DEFAULT_H = 1024  # 768 * 4/3
    PICKER_MIN_W     = 576
    PICKER_MIN_H     = 768

    def default_geometry = [PICKER_DEFAULT_W, PICKER_DEFAULT_H]
    def min_geometry     = [PICKER_MIN_W,     PICKER_MIN_H]

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
      @app.command(:pack, @outer, fill: :both, expand: 1)
    end

    def hide
      @app.command(:pack, :forget, @outer) rescue nil
    end

    def cleanup
      @photos&.each_value { |name| @app.command(:image, :delete, name) rescue nil }
      @photos&.clear
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
      @outer = '.game_picker'
      @app.command('ttk::frame', @outer, padding: 0)

      @cards_frame = "#{@outer}.cards"
      @app.command('ttk::frame', @cards_frame, padding: 16)
      @app.command(:pack, @cards_frame, fill: :both, expand: 1)

      # Capture the system window background color so hollow cards blend in
      # rather than appearing as stark black rectangles.
      @empty_bg = @app.tcl_eval(". cget -background")

      # Load a transparent 128×128 placeholder once — gives all image labels
      # a fixed pixel size whether or not box art has been fetched yet.
      @app.command(:image, :create, :photo, 'boxart_placeholder', file: PLACEHOLDER_PNG)

      SLOTS.times do |i|
        row = i / COLS
        col = i % COLS

        cell = "#{@cards_frame}.card#{i}"
        @app.command(:frame, cell, relief: :groove, borderwidth: 1,
          padx: 4, pady: 4, bg: '#2a2a2a')
        @app.command(:grid, cell, row: row, column: col, padx: 6, pady: 6, sticky: :nsew)

        img_lbl = "#{cell}.img"
        @app.command(:label, img_lbl, bg: '#2a2a2a', anchor: :center, image: 'boxart_placeholder')
        @app.command(:pack, img_lbl, fill: :x)

        title_lbl = "#{cell}.title"
        @app.command(:label, title_lbl, text: '', anchor: :center,
          bg: '#2a2a2a', fg: '#cccccc',
          font: '{TkDefaultFont} 10',
          justify: :center, wraplength: IMG_SIZE)
        @app.command(:bind, title_lbl, '<Configure>', proc {
          w = @app.tcl_eval("winfo width #{title_lbl}").to_i
          @app.command(title_lbl, :configure, wraplength: w - 8) if w > 8
        })
        @app.command(:pack, title_lbl, fill: :x, pady: [4, 2])

        plat_lbl = "#{cell}.plat"
        @app.command(:label, plat_lbl, text: '', anchor: :center,
          bg: '#2a2a2a', fg: '#888888',
          font: '{TkDefaultFont} 8')
        @app.command(:pack, plat_lbl, fill: :x, pady: [0, 4])

        @cards[i] = { frame: cell, image: img_lbl, title: title_lbl, platform: plat_lbl }
      end

      # Make columns and rows expand evenly
      COLS.times { |c| @app.command(:grid, :columnconfigure, @cards_frame, c, weight: 1) }
      ROWS.times { |r| @app.command(:grid, :rowconfigure, @cards_frame, r, weight: 1) }

      build_toolbar

      @built = true
    end

    def build_toolbar
      sep = "#{@outer}.sep"
      @app.command('ttk::separator', sep, orient: :horizontal)
      @app.command(:pack, sep, fill: :x)

      toolbar = "#{@outer}.toolbar"
      @app.command('ttk::frame', toolbar, padding: [4, 2])
      @app.command(:pack, toolbar, fill: :x)

      gear_btn = "#{toolbar}.gear"
      gear_menu = "#{toolbar}.gearmenu"
      @app.command('ttk::button', gear_btn, text: "\u2699", width: 1,
        command: proc { post_view_menu(gear_menu, gear_btn) })
      @app.command(:pack, gear_btn, side: :right)
    end

    def post_view_menu(menu, btn)
      @app.command(:menu, menu, tearoff: 0) unless @app.tcl_eval("winfo exists #{menu}") == '1'
      @app.command(menu, :delete, 0, :end)
      current = Gemba.user_config.picker_view
      @app.command(menu, :add, :command,
        label: "#{current == 'grid' ? "\u2713 " : '  '}#{translate('picker.toolbar.boxart_view')}",
        command: proc { emit(:picker_view_changed, view: 'grid') })
      @app.command(menu, :add, :command,
        label: "#{current == 'list' ? "\u2713 " : '  '}#{translate('picker.toolbar.list_view')}",
        command: proc { emit(:picker_view_changed, view: 'list') })
      x = @app.tcl_eval("winfo rootx #{btn}").to_i
      y = @app.tcl_eval("winfo rooty #{btn}").to_i
      h = @app.tcl_eval("winfo height #{btn}").to_i
      @app.tcl_eval("tk_popup #{menu} #{x} #{y + h}")
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
      qs_slot = quick_save_slot
      qs_state = quick_save_exists?(rom_info, qs_slot)
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.quick_load'),
        state: qs_state ? :normal : :disabled,
        command: proc { emit(:rom_quick_load, path: rom_info.path, slot: qs_slot) })
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.set_boxart'),
        command: proc { pick_custom_boxart(card, rom_info) })
      @app.command(menu, :add, :separator)
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.remove'),
        command: proc { remove_rom(rom_info) })
      @app.tcl_eval("tk_popup #{menu} [winfo pointerx .] [winfo pointery .]")
    end

    def quick_save_slot
      Gemba.user_config.quick_save_slot
    end

    def quick_save_exists?(rom_info, slot)
      return false unless rom_info.rom_id
      state_file = File.join(Gemba.user_config.states_dir, rom_info.rom_id, "state#{slot}.ss")
      File.exist?(state_file)
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
