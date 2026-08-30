require "tryst"
require "tryst/ui"
require "./achievements/achievement"
require "./achievements/cache"
require "./rom_library"
require "./rom_info"
require "./rom_overrides"
require "./config"
require "./locale"

module Gemba
  # Browses the achievements of the loaded game: a table of name /
  # points / earned date, a game dropdown over the library, a Sync
  # button and the Include Unofficial switch. Non-modal, reached from
  # View > Achievements. Ports ruby gemba's AchievementsWindow, minus
  # the bulk re-sync of every library game and the description tooltip.
  #
  # Holds no RetroAchievements state of its own: MainWindow owns the
  # session and hands the list in through #update whenever it changes
  # (session up, an unlock, ROM swapped), and the toolbar's actions go
  # back out through #on_sync / #on_unofficial_changed. Only the loaded
  # game has live data; any other library game shows what
  # Achievements::Cache last saw for it (MainWindow writes that cache
  # after every load/sync/unlock), and so does the loaded game itself
  # while its live list is empty - offline, or RA switched off. Live
  # data always wins over the cache when both exist.
  #
  # Built through the Tryst::UI DSL (Session#add into the window handle
  # MainWindow declared), so the widgets are ordinary nodes; the table's
  # rows and heading sorts go through Tk commands on its path, since
  # Handle has no row API.
  class AchievementsWindow
    SORT_ASC  = " ▲"
    SORT_DESC = " ▼"

    COLUMNS = {"name" => "achievements.name_col", "points" => "achievements.points_col", "earned" => "achievements.earned_col"}

    # Public handles so a spec drives the same widgets a user does.
    getter handle : Tryst::UI::Handle
    getter table : Tryst::UI::Handle
    getter dropdown : Tryst::UI::Handle
    getter sync_button : Tryst::UI::Handle
    getter unofficial_checkbox : Tryst::UI::Handle

    # Library games, in dropdown order.
    getter games = [] of RomLibrary::Entry

    @status_var : Tryst::UI::Var
    @game_var : Tryst::UI::Var
    @unofficial_var : Tryst::UI::Var

    @on_sync : (-> Nil)? = nil
    @on_unofficial_changed : (Bool -> Nil)? = nil

    @current_rom_id : String? = nil
    @live_list = [] of Achievements::Achievement
    @shown_list = [] of Achievements::Achievement
    @sort_column : String? = nil
    @sort_ascending = true
    @logged_in = false
    @syncing = false

    # cache_dir: where Achievements::Cache keeps its per-ROM files
    # (Paths.achievements_cache_dir in production; a spec passes a
    # tempdir).
    def initialize(@app : Tryst::App, @handle : Tryst::UI::Handle, session : Tryst::UI::Session,
                   @rom_library : RomLibrary, @config : Config, @overrides : RomOverrides?,
                   @cache_dir : String)
      status_var = nil
      game_var = nil
      unofficial_var = nil
      table_handle = nil
      dropdown_handle = nil
      sync_handle = nil
      unofficial_handle = nil

      session.add(@handle) do |build|
        build.component(:achievements) do |scope|
          # grow:/align: :stretch all the way down, so the table takes
          # whatever the window is resized to and the dropdown the
          # toolbar's leftover width.
          scope.column(:body, pad: 8, gap: 6, align: :stretch, grow: true) do |column|
            column.row(:toolbar, gap: 6) do |row|
              row.label(text: Locale.translate("achievements.game_label"))
              game_var = row.var("")
              dropdown_handle = row.dropdown(:game, bind: game_var, state: :readonly, grow: true)
              sync_handle = row.button(:sync, text: Locale.translate("achievements.sync"), state: :disabled)
            end

            table_handle = column.table(:achievements, columns: ["name", "points", "earned"],
              selectmode: :browse, grow: true)

            # Status on the left, the switch on the right - below the
            # table rather than in the toolbar, where it fell off the
            # edge at the default width.
            column.row(:footer, gap: 6) do |row|
              status_var = row.var(Locale.translate("achievements.none"))
              row.label(:status, bind: status_var, anchor: :w, grow: true)
              unofficial_var = row.var(@config.ra_unofficial?)
              unofficial_handle = row.checkbox(:unofficial, text: Locale.translate("achievements.include_unofficial"),
                bind: unofficial_var)
            end
          end
        end
      end

      @status_var = status_var.as(Tryst::UI::Var)
      @game_var = game_var.as(Tryst::UI::Var)
      @unofficial_var = unofficial_var.as(Tryst::UI::Var)
      @table = table_handle.as(Tryst::UI::Handle)
      @dropdown = dropdown_handle.as(Tryst::UI::Handle)
      @sync_button = sync_handle.as(Tryst::UI::Handle)
      @unofficial_checkbox = unofficial_handle.as(Tryst::UI::Handle)

      # Wired only now, once every ivar is assigned (see RomInfoWindow's
      # note on the same constraint).
      COLUMNS.each_key do |column|
        @app.command(@table.path, :heading, column, anchor: :w, command: @app.callback { sort_by(column) })
      end
      @app.command(@table.path, :column, "name", width: 270, stretch: 1)
      @app.command(@table.path, :column, "points", width: 60, stretch: 0, anchor: :e)
      @app.command(@table.path, :column, "earned", width: 150, stretch: 0)
      update_headings

      @sync_button.on_action { |_values, _signal| @on_sync.try(&.call) }
      @unofficial_checkbox.on_action { |_values, _signal| @on_unofficial_changed.try(&.call(@unofficial_var.value.as(Bool))) }
      @dropdown.on("<<ComboboxSelected>>") { |_values, _signal| on_game_selected }
    end

    # Sync was clicked. MainWindow answers with #sync_started /
    # #sync_finished around its own request, and a fresh #update.
    def on_sync(&block : -> Nil) : Nil
      @on_sync = block
    end

    # The Include Unofficial switch changed, with its new value.
    def on_unofficial_changed(&block : Bool -> Nil) : Nil
      @on_unofficial_changed = block
    end

    # Whether Sync is available at all - it needs credentials.
    def logged_in=(value : Bool) : Bool
      @logged_in = value
      refresh_sync_button
      set_status(Locale.translate("achievements.not_logged_in")) unless value
      value
    end

    # The loaded game (by RomLibrary rom_id, nil when none or not yet
    # identified) and its achievements. Re-reads the library too, so a
    # game opened since the window was last shown appears in the
    # dropdown.
    def update(current_rom_id : String?, list : Array(Achievements::Achievement)) : Nil
      @current_rom_id = current_rom_id
      @live_list = list
      refresh_games
      populate(list_for_selected)
      update_title
    end

    def show(current_rom_id : String?, list : Array(Achievements::Achievement)) : Nil
      update(current_rom_id, list)
      @unofficial_var.value = @config.ra_unofficial?
      @handle.show
    end

    def sync_started : Nil
      @syncing = true
      refresh_sync_button
      set_status(Locale.translate("achievements.sync_pending"))
    end

    # reason: :no_game / :failed - only read when ok is false.
    def sync_finished(ok : Bool, reason : Symbol = :failed) : Nil
      @syncing = false
      refresh_sync_button
      if ok
        populate(list_for_selected)
      else
        key = reason == :no_game ? "achievements.sync_no_game" : "achievements.sync_failed"
        set_status(Locale.translate(key))
      end
    end

    # Picks a library game by rom_id, as the dropdown would. Returns
    # false when no such game is listed.
    def select_game(rom_id : String) : Bool
      index = @games.index { |entry| entry.rom_id == rom_id }
      return false unless index

      @game_var.value = game_title(@games[index])
      on_game_selected
      true
    end

    def selected_game : RomLibrary::Entry?
      @games.find { |entry| game_title(entry) == @game_var.value }
    end

    # The table's rows as displayed, top to bottom: {name, points, earned}.
    def rows : Array({String, String, String})
      children = @app.command(@table.path, :children, "")
      return [] of {String, String, String} if children.empty?

      children.split.map do |iid|
        values = (0..2).map { |i| @app.tcl_eval("lindex [#{@table.path} item #{iid} -values] #{i}") }
        {values[0], values[1], values[2]}
      end
    end

    def status_text : String
      @status_var.value.as(String)
    end

    def title : String
      @app.command(:wm, "title", @handle.path)
    end

    private def refresh_games : Nil
      @games = @rom_library.all
      @dropdown.configure(values: @games.map { |entry| game_title(entry) })
      current = @games.find { |entry| entry.rom_id == @current_rom_id }
      @game_var.value = current ? game_title(current) : ""
    end

    private def game_title(entry : RomLibrary::Entry) : String
      RomInfo.from_rom(entry, overrides: @overrides).title
    end

    private def on_game_selected : Nil
      populate(list_for_selected)
    end

    # The loaded game's live list when it has one; otherwise whatever
    # the cache holds for the selected game (nothing, for a game never
    # synced - or one the worker hasn't identified yet, which has no
    # rom_id to look up). The read goes through #off_thread like every
    # other file access in this app; a per-ROM file is small enough
    # that blocking a dropdown pick on it is fine.
    private def list_for_selected : Array(Achievements::Achievement)
      selected = selected_game
      return [] of Achievements::Achievement unless selected
      return @live_list if selected.rom_id == @current_rom_id && !@live_list.empty?
      return [] of Achievements::Achievement if selected.rom_id.empty?

      @app.off_thread { Achievements::Cache.read(selected.rom_id, @cache_dir) } || [] of Achievements::Achievement
    end

    private def populate(list : Array(Achievements::Achievement)) : Nil
      @shown_list = list
      @sort_column = nil
      @sort_ascending = true
      update_headings
      render(default_order(list))
    end

    private def sort_by(column : String) : Nil
      return if @shown_list.empty?

      if @sort_column == column
        @sort_ascending = !@sort_ascending
      else
        @sort_column = column
        @sort_ascending = column != "earned" # earned: newest first
      end
      update_headings
      render(sorted(@shown_list))
    end

    private def render(list : Array(Achievements::Achievement)) : Nil
      children = @app.command(@table.path, :children, "")
      @app.command(@table.path, :delete, children) unless children.empty?

      list.each do |achievement|
        earned = achievement.earned_at.try(&.to_local.to_s("%Y-%m-%d %H:%M")) || ""
        @app.command(@table.path, :insert, "", :end, "-values", [achievement.title, achievement.points.to_s, earned])
      end

      if list.empty?
        set_status(Locale.translate("achievements.none"))
      else
        set_status(Locale.translate("achievements.earned_label", earned: list.count(&.earned?), total: list.size))
      end
    end

    # Earned first, newest on top; then the rest by title.
    private def default_order(list : Array(Achievements::Achievement)) : Array(Achievements::Achievement)
      earned, unearned = list.partition(&.earned?)
      earned.sort_by { |achievement| -(achievement.earned_at.try(&.to_unix) || 0_i64) } +
        unearned.sort_by(&.title.downcase)
    end

    private def sorted(list : Array(Achievements::Achievement)) : Array(Achievements::Achievement)
      case @sort_column
      when "name"
        ordered = list.sort_by(&.title.downcase)
        @sort_ascending ? ordered : ordered.reverse
      when "points"
        ordered = list.sort_by(&.points)
        @sort_ascending ? ordered : ordered.reverse
      when "earned"
        # Unearned rows stay at the bottom whichever way the dates go.
        earned, unearned = list.partition(&.earned?)
        ordered = earned.sort_by { |achievement| achievement.earned_at.try(&.to_unix) || 0_i64 }
        (@sort_ascending ? ordered : ordered.reverse) + unearned
      else
        default_order(list)
      end
    end

    private def update_headings : Nil
      COLUMNS.each do |column, key|
        indicator = @sort_column == column ? (@sort_ascending ? SORT_ASC : SORT_DESC) : ""
        @app.command(@table.path, :heading, column, text: Locale.translate(key) + indicator)
      end
    end

    private def refresh_sync_button : Nil
      @logged_in && !@syncing ? @sync_button.enable : @sync_button.disable
    end

    private def set_status(text : String) : Nil
      @status_var.value = text
    end

    private def update_title : Nil
      base = Locale.translate("achievements.title")
      current = @games.find { |entry| entry.rom_id == @current_rom_id }
      @app.command(:wm, "title", @handle.path, current ? "#{base} — #{game_title(current)}" : base)
    end
  end
end
