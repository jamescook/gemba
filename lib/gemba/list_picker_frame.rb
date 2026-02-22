# frozen_string_literal: true

module Gemba
  # Startup frame showing all library ROMs as a sortable treeview list.
  #
  # Alternative to GamePickerFrame (no boxart). Columns: Title, Last Played.
  # Clicking a column header sorts; the active column shows a ▲/▼ indicator.
  # Double-clicking a row emits :rom_selected. Right-clicking shows a context
  # menu identical to the GamePickerFrame card menu.
  # Pure Tk — no SDL2.
  class ListPickerFrame
    include BusEmitter
    include Locale::Translatable

    LIST_DEFAULT_W = 480
    LIST_DEFAULT_H = 600
    LIST_MIN_W     = 320
    LIST_MIN_H     = 400

    SORT_ASC  = ' ▲'
    SORT_DESC = ' ▼'

    def default_geometry = [LIST_DEFAULT_W, LIST_DEFAULT_H]
    def min_geometry     = [LIST_MIN_W,     LIST_MIN_H]

    def initialize(app:, rom_library:, rom_overrides: nil)
      @app         = app
      @rom_library = rom_library
      @overrides   = rom_overrides
      @built       = false
      @sort_col    = 'last_played'
      @sort_asc    = false   # most-recent first by default
      @row_data    = {}      # treeview item id => RomInfo
    end

    def show
      build_ui unless @built
      refresh
      @app.command(:pack, @outer, fill: :both, expand: 1)
    end

    def hide
      @app.command(:pack, :forget, @outer) rescue nil
    end

    def cleanup; end

    def receive(event, **_args)
      case event
      when :refresh then refresh
      end
    end

    def aspect_ratio = nil
    def rom_loaded?  = false
    def sdl2_ready?  = false
    def paused?      = false

    private

    def build_ui
      @outer = '.list_picker'
      @app.command('ttk::frame', @outer, padding: 8)

      # Treeview + scrollbar
      @tree = "#{@outer}.tree"
      @scrollbar = "#{@outer}.scroll"

      @app.command('ttk::treeview', @tree,
        columns: Teek.make_list('title', 'last_played'),
        show: :headings,
        selectmode: :browse)

      @app.command('ttk::scrollbar', @scrollbar, orient: :vertical,
        command: "#{@tree} yview")
      @app.command(@tree, :configure, yscrollcommand: "#{@scrollbar} set")

      build_columns
      bind_events

      @app.command(:grid, @tree,      row: 0, column: 0, sticky: :nsew)
      @app.command(:grid, @scrollbar, row: 0, column: 1, sticky: :ns)
      @app.command(:grid, :columnconfigure, @outer, 0, weight: 1)
      @app.command(:grid, :rowconfigure,    @outer, 0, weight: 1)

      build_toolbar

      @built = true
    end

    def build_columns
      @app.command(@tree, :heading, 'title',
        text: translate('list_picker.columns.title') + (@sort_col == 'title' ? sort_indicator : ''),
        anchor: :w,
        command: proc { sort_by('title') })
      @app.command(@tree, :heading, 'last_played',
        text: translate('list_picker.columns.last_played') + (@sort_col == 'last_played' ? sort_indicator : ''),
        anchor: :w,
        command: proc { sort_by('last_played') })
      @app.command(@tree, :column, 'title',       width: 280, stretch: 1)
      @app.command(@tree, :column, 'last_played', width: 120, stretch: 0)
    end

    def bind_events
      # Physical double-click fires virtual event so tests can trigger it
      # directly without needing event generate <Double-Button-1> (forbidden in Tk 9).
      @app.command(:bind, @tree, '<Double-Button-1>', proc {
        @app.tcl_eval("event generate #{@tree} <<DoubleClick>>")
      })
      @app.command(:bind, @tree, '<<DoubleClick>>', proc {
        iid = @app.tcl_eval("#{@tree} focus")
        next if iid.to_s.empty?
        rom_info = @row_data[iid]
        emit(:rom_selected, rom_info.path) if rom_info
      })

      # Physical right-click: use %x/%y (widget-relative event coords) to
      # identify the row, select and focus it, then fire the virtual event so
      # tests can trigger the same code path without real pointer coordinates.
      @app.tcl_eval(<<~TCL)
        bind #{@tree} <Button-3> {+
          set _iid [#{@tree} identify row %x %y]
          if {$_iid ne {}} {
            #{@tree} selection set $_iid
            #{@tree} focus $_iid
            event generate #{@tree} <<RightClick>>
          }
        }
      TCL

      # Virtual event reads the currently focused item. Decoupled from pointer
      # position so tests can trigger it directly after setting focus.
      @app.command(:bind, @tree, '<<RightClick>>', proc {
        iid = @app.tcl_eval("#{@tree} focus")
        rom_info = @row_data[iid.to_s]
        post_row_menu(rom_info) if rom_info
      })
    end

    def build_toolbar
      sep = "#{@outer}.sep"
      @app.command('ttk::separator', sep, orient: :horizontal)
      @app.command(:grid, sep, row: 1, column: 0, columnspan: 2, sticky: :ew, pady: [4, 0])

      toolbar = "#{@outer}.toolbar"
      @app.command('ttk::frame', toolbar, padding: [4, 2])
      @app.command(:grid, toolbar, row: 2, column: 0, columnspan: 2, sticky: :ew)

      gear_btn  = "#{toolbar}.gear"
      gear_menu = "#{toolbar}.gearmenu"
      @app.command('ttk::button', gear_btn, text: "\u2699", width: 1,
        command: proc { post_view_menu(gear_menu, gear_btn) })
      @app.command(:pack, gear_btn, side: :right)
    end

    def refresh
      @app.tcl_eval("#{@tree} delete [#{@tree} children {}]")
      @row_data.clear

      roms = sorted(@rom_library.all)
      roms.each do |rom|
        rom_info = RomInfo.from_rom(rom, overrides: @overrides)
        lp       = format_last_played(rom['last_played'])
        iid = @app.tcl_eval(
          "#{@tree} insert {} end -values [list #{Teek.make_list(rom_info.title, lp)}]"
        )
        @row_data[iid] = rom_info
      end
    end

    def sorted(roms)
      sorted = roms.sort_by do |r|
        case @sort_col
        when 'title'       then r['title'].to_s.downcase
        when 'last_played' then r['last_played'] || r['added_at'] || ''
        end
      end
      @sort_asc ? sorted : sorted.reverse
    end

    def sort_by(col)
      if @sort_col == col
        @sort_asc = !@sort_asc
      else
        @sort_col = col
        @sort_asc = (col == 'title')  # title: asc first; date: newest first
      end
      update_headings
      refresh
    end

    def update_headings
      ['title', 'last_played'].each do |col|
        label_key = col == 'title' ? 'list_picker.columns.title' : 'list_picker.columns.last_played'
        indicator = @sort_col == col ? sort_indicator : ''
        @app.command(@tree, :heading, col, text: translate(label_key) + indicator)
      end
    end

    def sort_indicator
      @sort_asc ? SORT_ASC : SORT_DESC
    end

    def format_last_played(iso)
      return translate('list_picker.never_played') if iso.to_s.empty?
      require 'time'
      Time.parse(iso).localtime.strftime('%b %-d, %Y')
    rescue
      iso.to_s
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

    def post_row_menu(rom_info)
      menu = "#{@tree}.ctx"
      @app.command(:menu, menu, tearoff: 0) unless @app.tcl_eval("winfo exists #{menu}") == '1'
      @app.command(menu, :delete, 0, :end)
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.play'),
        command: proc { emit(:rom_selected, rom_info.path) })
      qs_slot  = Gemba.user_config.quick_save_slot
      qs_state = quick_save_exists?(rom_info, qs_slot)
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.quick_load'),
        state: qs_state ? :normal : :disabled,
        command: proc { emit(:rom_quick_load, path: rom_info.path, slot: qs_slot) })
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.set_boxart'),
        command: proc { pick_custom_boxart(rom_info) })
      @app.command(menu, :add, :separator)
      @app.command(menu, :add, :command,
        label: translate('game_picker.menu.remove'),
        command: proc { remove_rom(rom_info) })
      @app.tcl_eval("tk_popup #{menu} [winfo pointerx .] [winfo pointery .]")
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

    def pick_custom_boxart(rom_info)
      return unless @overrides
      filetypes = '{{PNG Images} {.png}}'
      path = @app.tcl_eval("tk_getOpenFile -filetypes {#{filetypes}}")
      return if path.to_s.strip.empty?
      @overrides.set_custom_boxart(rom_info.rom_id, path)
    end
  end
end
