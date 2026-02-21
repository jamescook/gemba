# frozen_string_literal: true

module Gemba
  # Displays achievements for the currently loaded GBA game.
  #
  # Non-modal window accessible from View > Achievements. Shows a treeview
  # of all achievements with name, points, and earned date. A Sync button
  # pulls the latest earned state from the RA server. Only the currently
  # loaded game has live data; other GBA games in the library show empty.
  class AchievementsWindow
    include ChildWindow
    include Locale::Translatable

    TOP = '.gemba_achievements'

    VAR_UNOFFICIAL = '::gemba_ach_unofficial'

    def initialize(app:, rom_library:, config:, callbacks: {})
      @app            = app
      @rom_library    = rom_library
      @config         = config
      @callbacks      = callbacks
      @built             = false
      @backend           = nil
      @current_rom_id    = nil
      @game_entries      = []
      @tree_items        = []
      @item_descriptions = {}
      @tip_item          = nil
      @tip_timer         = nil
      @current_list      = []
      @sort_col          = nil   # nil = default order
      @sort_asc          = true
      @bulk_syncing      = false
      @bulk_cancelled    = false
    end

    # Called by AppController when a ROM loads or the backend is swapped.
    # Updates internal state and refreshes the window if it's visible.
    def update_game(rom_id:, backend:)
      @current_rom_id = rom_id
      @backend        = backend
      return unless @built

      refresh_game_list
      select_game(rom_id)
      populate_tree
      update_title
      update_rich_presence
    end

    # Called by AppController when on_achievements_changed fires.
    def refresh(backend = @backend)
      @backend      = backend
      @display_list = nil  # live backend data takes precedence over cached sync
      return unless @built

      populate_tree
      update_rich_presence
    end

    def show
      build_ui unless @built
      refresh_game_list
      select_game(@current_rom_id)
      # For non-current games (or when no game is loaded), seed from cache so
      # previously-synced data appears without requiring another network hit.
      if @display_list.nil? && @current_rom_id
        cached = Achievements::Cache.read(@current_rom_id)
        @display_list = cached if cached && @backend&.achievement_list.to_a.empty?
      end
      populate_tree
      refresh_auth_state unless @backend&.authenticated?
      update_title
      show_window(modal: false)
    end

    def hide
      if @bulk_syncing
        result = @app.command('tk_messageBox',
          parent: TOP,
          title: translate('dialog.cancel_bulk_sync_title'),
          message: translate('dialog.cancel_bulk_sync_msg'),
          type: :yesno,
          icon: :warning)
        return unless result == 'yes'
        @bulk_cancelled = true
        @bulk_syncing   = false
        unlock_ui_after_bulk_sync
      end
      hide_window(modal: false)
    end

    # ModalStack protocol (non-modal — no grab)
    def show_modal(**_args)
      build_ui unless @built
      refresh_game_list
      select_game(@current_rom_id)
      populate_tree
      update_title
      position_near_parent
      @app.command(:wm, 'deiconify', TOP)
      @app.command(:raise, TOP)
    end

    def withdraw
      @app.command(:wm, 'withdraw', TOP)
    end

    private

    def build_ui
      build_toplevel(translate('achievements.title'), geometry: '560x440') do
        build_toolbar
        build_tree
        build_status
      end
      setup_bus_subscriptions
      @built = true
    end

    def setup_bus_subscriptions
      Gemba.bus.on(:ra_sync_started) do
        @app.command(@sync_btn, :configure, state: :disabled)
        set_status(translate('achievements.sync_pending'))
      end

      Gemba.bus.on(:ra_sync_done) do |ok:, reason: nil, **|
        # Re-enable only if still authenticated; logout during an in-flight
        # request should leave the button disabled.
        refresh_auth_state
        unless ok
          key = case reason
                when :no_game  then 'achievements.sync_no_game'
                when :timeout  then 'achievements.sync_timeout'
                else                'achievements.sync_failed'
                end
          set_status(translate(key))
        end
      end

      Gemba.bus.on(:ra_auth_result) do |status:, **|
        refresh_auth_state
      end

      Gemba.bus.on(:ra_rich_presence_changed) do |message:, **|
        next unless @rp_lbl
        @app.command(@rp_lbl, :configure, text: message)
      end
    end

    def refresh_auth_state
      authenticated = @backend&.authenticated?
      state = authenticated ? :normal : :disabled
      @app.command(@sync_btn,        :configure, state: state)
      @app.command(@unofficial_check, :configure, state: state) if @unofficial_check
      set_status(translate('achievements.not_logged_in')) unless authenticated
    end

    def build_toolbar
      f = "#{TOP}.toolbar"
      @app.command('ttk::frame', f, padding: [8, 8, 8, 4])
      @app.command(:pack, f, fill: :x)

      lbl = "#{f}.lbl"
      @app.command('ttk::label', lbl, text: translate('achievements.game_label'))
      @app.command(:pack, lbl, side: :left, padx: [0, 4])

      @combo = "#{f}.combo"
      @app.command('ttk::combobox', @combo, state: :readonly, width: 36)
      @app.command(:pack, @combo, side: :left)
      @app.command(:bind, @combo, '<<ComboboxSelected>>', proc { |*| on_game_selected })

      @sync_btn = "#{f}.sync"
      @app.command('ttk::button', @sync_btn,
                   text: translate('achievements.sync'),
                   state: @backend&.authenticated? ? :normal : :disabled,
                   command: proc { sync })
      @app.command(:pack, @sync_btn, side: :left, padx: [8, 0])

      @unofficial_check = "#{f}.unofficial"
      @app.set_variable(VAR_UNOFFICIAL, @config.ra_unofficial? ? '1' : '0')
      @app.command('ttk::checkbutton', @unofficial_check,
                   text: translate('achievements.include_unofficial'),
                   variable: VAR_UNOFFICIAL,
                   command: proc { on_unofficial_toggled })
      @app.command(:pack, @unofficial_check, side: :left, padx: [12, 0])
    end

    def build_tree
      f = "#{TOP}.tf"
      @app.command('ttk::frame', f, padding: [8, 0, 8, 4])
      @app.command(:pack, f, fill: :both, expand: 1)

      @tree      = "#{f}.tree"
      @scrollbar = "#{f}.sb"

      @app.command('ttk::treeview', @tree,
                   columns: Teek.make_list('name', 'points', 'earned'),
                   show: :headings,
                   height: 16,
                   selectmode: :browse)

      @app.command(@tree, :heading, 'name',
                   text: translate('achievements.name_col'), anchor: :w,
                   command: proc { sort_tree('name') })
      @app.command(@tree, :heading, 'points',
                   text: translate('achievements.points_col'),
                   command: proc { sort_tree('points') })
      @app.command(@tree, :heading, 'earned',
                   text: translate('achievements.earned_col'),
                   command: proc { sort_tree('earned') })

      @app.command(@tree, :column, 'name',   width: 270)
      @app.command(@tree, :column, 'points', width:  55)
      @app.command(@tree, :column, 'earned', width: 145)

      @app.command('ttk::scrollbar', @scrollbar, orient: :vertical,
                   command: "#{@tree} yview")
      @app.command(@tree, :configure, yscrollcommand: "#{@scrollbar} set")

      @app.command(:pack, @scrollbar, side: :right, fill: :y)
      @app.command(:pack, @tree, side: :left, fill: :both, expand: 1)

      setup_tree_tooltip
    end

    def build_status
      bar = "#{TOP}.status_bar"
      @app.command('ttk::frame', bar)
      @app.command(:pack, bar, fill: :x)

      @status_lbl = "#{bar}.status"
      @app.command('ttk::label', @status_lbl,
                   text: translate('achievements.none'),
                   anchor: :w, padding: [8, 2, 8, 6])
      @app.command(:pack, @status_lbl, side: :left)

      @rp_lbl = "#{bar}.rich_presence"
      @app.command('ttk::label', @rp_lbl,
                   text: '',
                   anchor: :e, padding: [8, 2, 8, 6],
                   foreground: '#666666')
      @app.command(:pack, @rp_lbl, side: :right)
    end

    def refresh_game_list
      entries = @rom_library.all.select { |r| r['platform']&.downcase == 'gba' }
      @game_entries = entries
      titles = entries.map { |r|
        GameIndex.lookup(r['game_code']) || r['title'] || File.basename(r['path'].to_s, '.*')
      }
      @app.command(@combo, :configure, values: Teek.make_list(*titles))
    end

    def select_game(rom_id)
      idx = @game_entries.index { |r| r['rom_id'] == rom_id }
      return unless idx

      @app.command(@combo, :current, idx)
    end

    def on_game_selected
      @display_list = nil
      idx           = @app.command(@combo, :current).to_i
      selected_id   = @game_entries.dig(idx, 'rom_id')

      if selected_id == @current_rom_id
        populate_tree
      else
        @display_list = Achievements::Cache.read(selected_id)
        populate_tree
      end
    end

    def populate_tree
      @current_list = @display_list || @backend&.achievement_list || []
      @sort_col     = nil  # reset to default order when data changes
      @sort_asc     = true
      update_heading_indicators
      render_list(default_sorted(@current_list))
    end

    def sort_tree(col)
      return if @current_list.empty?
      if @sort_col == col
        @sort_asc = !@sort_asc
      else
        @sort_col = col
        @sort_asc = col != 'earned'  # earned defaults desc (newest first)
      end
      update_heading_indicators
      render_list(apply_sort(@current_list))
    end

    def render_list(list)
      clear_tree

      if list.empty?
        update_status(0, 0)
        return
      end

      list.each do |ach|
        earned_str = ach.earned? && ach.earned_at ?
          ach.earned_at.strftime('%Y-%m-%d %H:%M') : ''
        item_id = @app.command(@tree, :insert, '', :end,
                               values: Teek.make_list(ach.title, ach.points.to_s, earned_str)).to_s
        @tree_items        << item_id
        @item_descriptions[item_id] = ach.description unless ach.description.to_s.empty?
      end

      earned_count = list.count(&:earned?)
      update_status(earned_count, list.size)
    end

    def default_sorted(list)
      earned, unearned = list.partition(&:earned?)
      earned.sort_by!   { |a| -(a.earned_at&.to_i || 0) }
      unearned.sort_by!(&:title)
      earned + unearned
    end

    def apply_sort(list)
      case @sort_col
      when 'name'
        sorted = list.sort_by { |a| a.title.downcase }
        @sort_asc ? sorted : sorted.reverse
      when 'points'
        sorted = list.sort_by { |a| a.points }
        @sort_asc ? sorted : sorted.reverse
      when 'earned'
        # Nulls (unearned) always last regardless of direction
        earned, unearned = list.partition(&:earned?)
        sorted_earned = earned.sort_by { |a| a.earned_at.to_i }
        sorted_earned.reverse! unless @sort_asc
        sorted_earned + unearned
      else
        default_sorted(list)
      end
    end

    SORT_ASC  = ' ▲'
    SORT_DESC = ' ▼'

    def update_heading_indicators
      {
        'name'   => translate('achievements.name_col'),
        'points' => translate('achievements.points_col'),
        'earned' => translate('achievements.earned_col'),
      }.each do |col, base_text|
        indicator = if @sort_col == col
          @sort_asc ? SORT_ASC : SORT_DESC
        else
          ''
        end
        @app.command(@tree, :heading, col, text: "#{base_text}#{indicator}")
      end
    end

    def clear_tree
      return if @tree_items.empty?

      hide_tip
      @app.command(@tree, :delete, Teek.make_list(*@tree_items))
      @tree_items.clear
      @item_descriptions.clear
    end

    def update_status(earned, total)
      text = if total == 0
        translate('achievements.none')
      else
        translate('achievements.earned_label', earned: earned, total: total)
      end
      set_status(text)
    end

    def set_status(text)
      return unless @status_lbl
      @app.command(@status_lbl, :configure, text: text)
    end

    def update_rich_presence
      return unless @rp_lbl
      msg = @backend&.rich_presence_message.to_s
      @app.command(@rp_lbl, :configure, text: msg)
    end

    def update_title
      entry      = @game_entries.find { |r| r['rom_id'] == @current_rom_id }
      game_title = entry && (GameIndex.lookup(entry['game_code']) || entry['title'])
      window_title = if game_title
        "#{translate('achievements.title')} \u2014 #{game_title}"
      else
        translate('achievements.title')
      end
      @app.command(:wm, 'title', TOP, window_title)
    end

    def selected_rom_info
      idx   = @app.command(@combo, :current).to_i
      entry = @game_entries[idx]
      return nil unless entry
      RomInfo.from_rom(entry)
    end

    SYNC_TIMEOUT_MS = 60_000

    def sync
      return unless @backend
      rom_info = selected_rom_info
      return unless rom_info

      Gemba.log(:info) { "Achievements: sync started for #{rom_info.title} (#{rom_info.rom_id})" }
      Gemba.bus.emit(:ra_sync_started)

      @sync_timeout = @app.after(SYNC_TIMEOUT_MS) do
        Gemba.log(:warn) { "Achievements: sync timed out after #{SYNC_TIMEOUT_MS / 1000}s" }
        @sync_timeout = nil
        Gemba.bus.emit(:ra_sync_done, ok: false, reason: :timeout)
      end

      @backend.fetch_for_display(rom_info: rom_info) do |list|
        @app.after_cancel(@sync_timeout) if @sync_timeout
        @sync_timeout = nil
        Gemba.log(list ? :info : :warn) {
          "Achievements: fetch_for_display returned #{list ? "#{list.size} achievements" : 'nil'}"
        }
        Achievements::Cache.write(rom_info.rom_id, list) if list
        @display_list = list
        populate_tree
        Gemba.bus.emit(:ra_sync_done, ok: !list.nil?)
      end
    end

    # -- Include unofficial toggle ------------------------------------------

    def on_unofficial_toggled
      return unless @backend&.authenticated?

      value = @app.get_variable(VAR_UNOFFICIAL) == '1'
      Gemba.bus.emit(:ra_unofficial_changed, value: value)

      # Bulk re-sync every library game that has an MD5
      games = @rom_library.all.select { |r|
        !r['md5'].to_s.empty?
      }
      return if games.empty?

      lock_ui_for_bulk_sync
      sync_games_sequentially(games, 0)
    end

    def lock_ui_for_bulk_sync
      @bulk_syncing   = true
      @bulk_cancelled = false
      @app.command(@sync_btn,        :configure, state: :disabled)
      @app.command(@unofficial_check, :configure, state: :disabled)
    end

    def unlock_ui_after_bulk_sync
      @bulk_syncing = false
      refresh_auth_state
    end

    def sync_games_sequentially(games, idx)
      return if @bulk_cancelled

      if idx >= games.size
        unlock_ui_after_bulk_sync
        # Refresh display for the currently selected game
        on_game_selected
        set_status(translate('achievements.bulk_sync_done', count: games.size))
        return
      end

      rom      = games[idx]
      rom_info = RomInfo.from_rom(rom)
      title    = rom_info.title
      set_status(translate('achievements.bulk_syncing',
                           title: title, n: idx + 1, total: games.size))

      @backend.fetch_for_display(rom_info: rom_info) do |list|
        next if @bulk_cancelled
        Achievements::Cache.write(rom_info.rom_id, list) if list
        sync_games_sequentially(games, idx + 1)
      end
    end

    # -- Achievement description tooltip ------------------------------------

    TIP_DELAY_MS  = 500
    TIP_PATH      = "#{TOP}.__tip"
    TIP_BG        = '#FFFFEE'
    TIP_FG        = '#333333'
    TIP_BORDER    = '#999999'

    def setup_tree_tooltip
      @app.command(:bind, @tree, '<Motion>', proc {
        # Identify treeview row under the pointer
        px  = @app.tcl_eval("winfo pointerx #{@tree}").to_i
        py  = @app.tcl_eval("winfo pointery #{@tree}").to_i
        tx  = @app.tcl_eval("winfo rootx #{@tree}").to_i
        ty  = @app.tcl_eval("winfo rooty #{@tree}").to_i
        item = @app.tcl_eval("#{@tree} identify row #{px - tx} #{py - ty}").strip

        next if item == @tip_item
        @tip_item = item
        hide_tip

        next if item.empty?
        desc = @item_descriptions[item]
        next unless desc

        cancel_tip_timer
        @tip_timer = @app.after(TIP_DELAY_MS) { show_tip(desc) }
      })

      @app.command(:bind, @tree, '<Leave>', proc {
        @tip_item = nil
        cancel_tip_timer
        hide_tip
      })
    end

    def show_tip(text)
      hide_tip
      px  = @app.tcl_eval("winfo pointerx .").to_i
      py  = @app.tcl_eval("winfo pointery .").to_i
      wx  = @app.tcl_eval("winfo rootx #{TOP}").to_i
      wy  = @app.tcl_eval("winfo rooty #{TOP}").to_i
      rel_x = px - wx + 14
      rel_y = py - wy + 18

      @app.command(:frame, TIP_PATH, background: TIP_BORDER, borderwidth: 0)
      @app.command(:label, "#{TIP_PATH}.l",
                   text: text, background: TIP_BG, foreground: TIP_FG,
                   padx: 8, pady: 5, justify: :left, wraplength: 320)
      @app.command(:pack, "#{TIP_PATH}.l", padx: 1, pady: 1)
      @app.command(:place, TIP_PATH, x: rel_x, y: rel_y)
      @app.command(:raise, TIP_PATH)
    end

    def hide_tip
      cancel_tip_timer
      @app.tcl_eval("catch {destroy #{TIP_PATH}}")
    end

    def cancel_tip_timer
      return unless @tip_timer
      @app.command(:after, :cancel, @tip_timer)
      @tip_timer = nil
    end
  end
end
