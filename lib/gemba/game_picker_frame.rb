# frozen_string_literal: true

require_relative 'event_bus'
require_relative 'locale'

module Gemba
  # Startup frame showing a 4×4 grid of ROM cards.
  #
  # Each card displays the ROM title and platform. Clicking a populated card
  # emits :rom_selected on the bus. Empty slots show hollow placeholder cards.
  # Pure Tk — no SDL2.
  class GamePickerFrame
    include BusEmitter
    include Locale::Translatable

    COLS  = 4
    ROWS  = 4
    SLOTS = COLS * ROWS

    def initialize(app:, rom_library:)
      @app = app
      @rom_library = rom_library
      @built = false
      @cards = {}  # index => { frame:, title:, platform: }
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
      # No SDL2 resources to clean up
    end

    def receive(event, **args)
      case event
      when :refresh then refresh
      end
    end

    def rom_loaded? = false
    def sdl2_ready? = false
    def paused? = false

    private

    def build_ui
      @grid = '.game_picker'
      @app.command('ttk::frame', @grid, padding: 16)

      SLOTS.times do |i|
        row = i / COLS
        col = i % COLS

        cell = "#{@grid}.card#{i}"
        @app.command(:frame, cell, relief: :groove, borderwidth: 2,
          padx: 4, pady: 4, bg: '#2a2a2a')
        @app.command(:grid, cell, row: row, column: col, padx: 6, pady: 6, sticky: :nsew)

        title_lbl = "#{cell}.title"
        @app.command(:label, title_lbl, text: '', anchor: :center,
          bg: '#2a2a2a', fg: '#cccccc',
          font: '{TkDefaultFont} 10')
        @app.command(:pack, title_lbl, fill: :x, pady: [8, 2])

        plat_lbl = "#{cell}.plat"
        @app.command(:label, plat_lbl, text: '', anchor: :center,
          bg: '#2a2a2a', fg: '#888888',
          font: '{TkDefaultFont} 8')
        @app.command(:pack, plat_lbl, fill: :x)

        @cards[i] = { frame: cell, title: title_lbl, platform: plat_lbl }
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
        rom = roms[i]

        if rom
          populate_card(card, rom)
        else
          hollow_card(card)
        end
      end
    end

    def populate_card(card, rom)
      title = rom['title'] || rom['rom_id'] || '???'
      platform = (rom['platform'] || 'gba').upcase

      @app.command(card[:title], :configure, text: title, fg: '#cccccc')
      @app.command(card[:platform], :configure, text: platform, fg: '#888888')
      @app.command(card[:frame], :configure, relief: :groove, bg: '#2a2a2a')

      path = rom['path']
      click = proc { emit(:rom_selected, path) }
      @app.command(:bind, card[:frame], '<Button-1>', click)
      @app.command(:bind, card[:title], '<Button-1>', click)
      @app.command(:bind, card[:platform], '<Button-1>', click)
    end

    def hollow_card(card)
      @app.command(card[:title], :configure, text: '', fg: '#555555')
      @app.command(card[:platform], :configure, text: '')
      @app.command(card[:frame], :configure, relief: :ridge, bg: '#1a1a1a')

      # Unbind clicks
      @app.command(:bind, card[:frame], '<Button-1>', '')
      @app.command(:bind, card[:title], '<Button-1>', '')
      @app.command(:bind, card[:platform], '<Button-1>', '')
    end
  end
end
