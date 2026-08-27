require "tryst"
require "./rom_library"
require "./rom_info"
require "./rom_overrides"
require "./config"
require "./frame_stack"
require "./picker_row_actions"
require "./locale"

module Gemba
  # A sortable 2-column (Title, Last Played) ttk::treeview, plus an "Open
  # ROM..." button for a new one, a gear-menu toggle to GamePickerFrame's
  # box-art grid, and a right-click menu (Play / Quick Load / Set Boxart
  # / Remove). Clicking a column header sorts by it (again to reverse
  # direction); the active column's heading shows a
  # #{SORT_ASC}/#{SORT_DESC} indicator.
  class ListPickerFrame
    include Frame
    include PickerRowActions

    SORT_ASC  = " ▲"
    SORT_DESC = " ▼"

    COLUMN_HEADINGS = {"title" => "list_picker.columns.title", "last_played" => "list_picker.columns.last_played"}

    # Public getters ensure specs exercise the same surface as other
    # callers.
    getter path : String
    getter tree : Tryst::Widget
    getter open_button : Tryst::Widget
    getter entries : Array(RomLibrary::Entry)

    @entries = [] of RomLibrary::Entry
    @row_entries = {} of String => RomLibrary::Entry
    @sort_column = "last_played"
    @sort_ascending = false

    def initialize(@app : Tryst::App, parent : String, @library : RomLibrary, @config : Config,
                   @overrides : RomOverrides?, @on_open_rom : -> Nil, @on_select : String -> Nil,
                   @on_quick_load : Proc(String, Int32, Nil), @on_view_changed : String -> Nil)
      # "." is already the root path's own separator - a child of root
      # is ".gemba_list_picker", not "..gemba_list_picker" (same special
      # case Tryst::SDL::Viewport's own #frame_path handles).
      base = parent == "." ? "" : parent
      @path = "#{base}.gemba_list_picker"
      @app.command(:frame, @path)

      @tree = @app.create_widget("ttk::treeview", parent: @path,
        columns: ["title", "last_played"], show: :headings, selectmode: :browse)
      @scrollbar = @app.create_widget("ttk::scrollbar", parent: @path,
        orient: :vertical, command: "#{@tree.path} yview")
      @tree.command(:configure, yscrollcommand: "#{@scrollbar.path} set")
      build_columns

      @open_button = @app.create_widget("ttk::button", parent: @path,
        text: Locale.translate("menu.open_rom"), command: @app.callback { @on_open_rom.call })

      sep, toolbar = build_gear_toolbar(@path)

      @tree.grid(row: 0, column: 0, sticky: "nsew", padx: [12, 0], pady: 12)
      @scrollbar.grid(row: 0, column: 1, sticky: "ns", pady: 12)
      @open_button.grid(row: 1, column: 0, columnspan: 2, pady: [0, 12])
      sep.grid(row: 2, column: 0, columnspan: 2, sticky: "ew")
      toolbar.grid(row: 3, column: 0, columnspan: 2, sticky: "ew")
      @app.command(:grid, :columnconfigure, @path, 0, weight: 1)
      @app.command(:grid, :rowconfigure, @path, 0, weight: 1)

      @tree.bind(:return) { |_v, _s| load_selected }
      @tree.bind(:double_click) { |_v, _s| load_selected }
      @tree.bind(:right_click, subs: ["%x", "%y"]) { |values, _s| right_click(values[0], values[1]) }

      refresh
    end

    # Call after opening a new ROM for it to appear.
    def refresh : Nil
      @entries = @library.all
      children = @app.command(@tree.path, :children, "")
      @app.command(@tree.path, :delete, children) unless children.empty?
      @row_entries.clear

      sorted_entries.each do |entry|
        title = RomInfo.from_rom(entry, overrides: @overrides).title
        iid = @app.command(@tree.path, :insert, "", :end, "-values", [title, format_last_played(entry.last_played)])
        @row_entries[iid] = entry
      end

      select_first
    end

    def show : Nil
      @app.command(:pack, @path, fill: :both, expand: 1)
      refresh
      @app.command(:focus, @tree.path)
    end

    def hide : Nil
      @app.command(:pack, :forget, @path)
    end

    def cleanup : Nil
    end

    private def build_columns : Nil
      @tree.command(:heading, "title", anchor: :w, command: @app.callback { sort_by("title") })
      @tree.command(:heading, "last_played", anchor: :w, command: @app.callback { sort_by("last_played") })
      @tree.command(:column, "title", width: 280, stretch: 1)
      @tree.command(:column, "last_played", width: 120, stretch: 0)
      update_headings
    end

    private def sort_by(column : String) : Nil
      if @sort_column == column
        @sort_ascending = !@sort_ascending
      else
        @sort_column = column
        @sort_ascending = column == "title" # title: asc first; date: newest first
      end
      update_headings
      refresh
    end

    private def update_headings : Nil
      COLUMN_HEADINGS.each do |column, key|
        indicator = @sort_column == column ? sort_indicator : ""
        @tree.command(:heading, column, text: Locale.translate(key) + indicator)
      end
    end

    private def sort_indicator : String
      @sort_ascending ? SORT_ASC : SORT_DESC
    end

    private def sorted_entries : Array(RomLibrary::Entry)
      sorted = @entries.sort_by { |entry| @sort_column == "title" ? entry.title.downcase : entry.last_played }
      @sort_ascending ? sorted : sorted.reverse
    end

    private def format_last_played(iso : String) : String
      return Locale.translate("list_picker.never_played") if iso.empty?
      Time.parse_rfc3339(iso).to_local.to_s("%b %-d, %Y")
    rescue
      iso
    end

    private def select_first : Nil
      first_iid = @app.command(@tree.path, :children, "").split.first?
      return unless first_iid

      @app.command(@tree.path, :selection, :set, first_iid)
      @app.command(@tree.path, :focus, first_iid)
    end

    private def load_selected : Nil
      iid = @app.command(@tree.path, :focus)
      return if iid.empty?

      entry = @row_entries[iid]?
      return unless entry

      @on_select.call(entry.path)
    end

    private def right_click(x : String, y : String) : Nil
      iid = @app.command(@tree.path, :identify, :row, x, y)
      return if iid.empty?

      @app.command(@tree.path, :selection, :set, iid)
      @app.command(@tree.path, :focus, iid)

      entry = @row_entries[iid]?
      return unless entry

      info = RomInfo.from_rom(entry, overrides: @overrides)
      popup_rom_menu("#{@tree.path}.ctx", info, @on_select, @on_quick_load)
    end
  end
end
