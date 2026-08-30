require "tryst/ui"
require "tryst-sdl"
require "./emulation_worker"
require "./emulator_frame"
require "./video_output"
require "./audio_output"
require "./keyboard_map"
require "./gamepad_map"
require "./hotkey_map"
require "./key_source"
require "./paths"
require "./session_logger"
require "./locale"
require "./game_index"
require "./events"
require "./config"
require "./rom_library"
require "./frame_stack"
require "./modal_stack"
require "./auto_pause"
require "./game_picker_frame"
require "./list_picker_frame"
require "./boxart_fetcher"
require "./boxart_fetcher/libretro_backend"
require "./rom_overrides"
require "./achievements/retro_achievements/backend"
require "./achievements/retro_achievements/unlock_queue"
require "./achievements/rom_hash"
require "./achievements/retro_achievements/fake_requester"
require "./rom_info_window"
require "./achievements_window"
require "./settings_window"
require "./save_state_picker"

module Gemba
  # The real, runnable Gemba app - merges MainWindow and AppController
  # into one class; see #load_rom for the key entry point.
  #
  # Gamepad hot-plug detection/#device assignment: see #init_gamepad_subsystem's
  # own doc comment.
  class MainWindow
    NATIVE_WIDTH  = 240
    NATIVE_HEIGHT = 160

    # Matches ruby's own AppController - a slow idle probe (hot-plug
    # detection only fires this often) vs. a fast one while Settings is
    # open and a device is already attached (so a rebind capture feels
    # responsive). See #gamepad_probe_tick.
    GAMEPAD_PROBE_MS  = 2000
    GAMEPAD_LISTEN_MS =   50

    # Matches ruby gemba's PING_INTERVAL_SEC. RetroAchievements treats
    # this as the "still playing" heartbeat, so it also decides how
    # quickly a finished session stops showing on the site.
    RA_PING_INTERVAL_MS = 120_000

    # Only ever armed while a menu is actually posted - see
    # #watch_menu_bar.
    MENU_POLL_MS = 100

    # Matches ruby gemba's own FOCUS_POLL_MS - see #watch_app_focus.
    FOCUS_POLL_MS = 200

    # Matches ruby gemba's own turbo_volume_pct default (25) - see
    # EmulatorFrame's own doc comment on why turbo needs this at all.
    TURBO_VOLUME = EmulatorFrame::TURBO_VOLUME

    # Adapts a Viewport's #key_down? to KeySource's #button? - see
    # KeySource's own doc comment for why this seam exists at all.
    private class ViewportKeyboard
      include KeySource

      def initialize(@viewport : Tryst::SDL::Viewport)
      end

      def button?(key : String) : Bool
        @viewport.key_down?(key)
      end
    end

    getter app : Tryst::App
    getter video : VideoOutput
    getter audio : AudioOutput
    getter gamepad_map : GamepadMap
    getter config : Config
    getter events : Events
    getter modal_stack : ModalStack
    getter settings_window : SettingsWindow
    getter rom_info_window : RomInfoWindow
    getter achievements_window : AchievementsWindow
    getter save_state_picker : SaveStatePicker
    getter game_picker : GamePickerFrame
    getter list_picker : ListPickerFrame
    getter boxart_fetcher : BoxartFetcher
    getter ra_backend : Achievements::RetroAchievements::Backend
    getter rom_overrides : RomOverrides
    getter frame_stack : FrameStack

    # Which picker FrameStack currently shows.
    getter active_picker : Frame

    # ROM-dependent menu items - disabled at startup, enabled once
    # #load_rom succeeds (see it). Exposed for spec coverage of that
    # gating; nothing else needs to reach these directly.
    getter rom_info_item : Tryst::UI::Handle?
    getter quick_save_item : Tryst::UI::Handle?
    getter quick_load_item : Tryst::UI::Handle?
    getter save_states_item : Tryst::UI::Handle?

    def worker : EmulationWorker?
      @emulator_frame.try(&.worker)
    end

    def emulator_frame : EmulatorFrame?
      @emulator_frame
    end

    @emulator_frame : EmulatorFrame?

    # Every pause gemba issues on the user's behalf goes through here -
    # see AutoPause for why overlapping causes need real bookkeeping
    # rather than a boolean, and #hold_auto_pause below for the reasons
    # in use.
    getter auto_pause = AutoPause.new

    # RetroAchievements session for the ROM currently loaded: the game
    # id resolved from its hash, its achievements (earned or not - the
    # earned-state bookkeeping lives HERE, the worker's runtime only
    # ever holds the ones still to be earned), its presence script and
    # the latest presence string the worker has evaluated. All
    # nil/empty until a ROM with RA support is running and the user is
    # logged in.
    @ra_game_id : Int64? = nil
    @ra_script : String? = nil
    @ra_achievements = {} of UInt32 => Achievements::Achievement
    @ra_rich_presence : String = ""
    @ra_ping_timer : Tryst::RepeatingTimer? = nil

    # Outlives any one RA session - see its own class doc for why a
    # pending retry isn't tied to the game it was earned in.
    @ra_unlocks : Achievements::RetroAchievements::UnlockQueue

    # The loaded ROM's RomLibrary rom_id - nil until the worker has
    # reported its header (see #update_rom_identity), which is what the
    # achievements window keys its game dropdown on.
    @current_rom_id : String? = nil

    # Bumped by every #stop_ra_session. Starting a session is three
    # network round-trips, and the ROM can be swapped (or RA switched
    # off) while one is in flight - a reply carrying an older number is
    # from a session that no longer exists, and is dropped rather than
    # loading the previous game's achievements onto the new worker.
    @ra_session = 0
    @pause_item : Tryst::UI::Handle?

    # The menu bar itself, and the poll that watches it for the menu
    # closing again - see #watch_menu_bar.
    @menu_bar : Tryst::UI::Handle?
    @menu_poll : Tryst::RepeatingTimer? = nil

    # See #watch_app_focus.
    @focus_probe : Proc(Bool)
    @app_focus_seen = false

    # rom_library_path/config_path forward straight to RomLibrary/Config
    # - see their own doc comments. Production code omits both; a spec
    # passes isolated tempfile paths so a test ROM load never touches
    # the real ~/Library/Application Support/gemba data (same
    # state_dir_override convention EmulationWorker's save-state tests
    # already use).
    # Config/Locale/GameIndex's own file reads below are genuine blocking
    # syscalls (see the same guard #save_config routes around via
    # App#off_thread) but happen before any Tryst::App/interpreter
    # exists in this process at all - there's no Tk thread yet to
    # corrupt, only the guard's own conservative heuristic firing
    # early. Routing them through off_thread isn't possible yet either:
    # off_thread needs a live App, and menu labels need Locale loaded
    # BEFORE the menu (further down) can be built, which itself must
    # happen before Session#run_async ever constructs one. Accepted as
    # a one-time cold-start exception; every OTHER file write in this
    # class (RomLibrary#remember, Config#save! from #wire_events) runs
    # well after @app exists and does go through #off_thread.
    #
    # gamepad_polling: false skips #init_gamepad_subsystem entirely -
    # for a spec that doesn't care about gamepad hot-plug, since
    # Tryst::SDL::Gamepad.on_added/#on_removed are process-wide
    # singletons (replaced, not stacked, on every registration - see
    # their own doc comments): a spec that doesn't need this class's own
    # callbacks shouldn't be left holding them once its own App is
    # destroyed, ready to fire against dead ivars the next time some
    # OTHER spec (in the same process) calls .poll_events.
    def initialize(rom_library_path : String? = nil, config_path : String? = nil,
                   rom_overrides_path : String? = nil, boxart_cache_dir : String? = nil,
                   @gamepad_polling : Bool = true,
                   ra_requester : Proc(Hash(String, String), {JSON::Any?, Bool})? = nil,
                   ra_retry_schedule : Achievements::RetroAchievements::UnlockQueue::Schedule = Achievements::RetroAchievements::UnlockQueue::Schedule::DEFAULT,
                   focus_probe : Proc(Bool)? = nil,
                   logs_dir : String? = nil)
      @config = config_path ? Config.new(config_path) : Config.new
      Locale.load(@config.locale)
      GameIndex.preload!
      @events = Events.new
      @rom_library = rom_library_path ? RomLibrary.new(rom_library_path) : RomLibrary.new

      @session = Tryst::UI::Session.new(title: "Gemba")
      @keyboard_map = KeyboardMap.new
      @keyboard_map.load_config(@config)
      @gamepad_map = GamepadMap.new
      @hotkeys = HotkeyMap.new
      @hotkeys.load_config(@config)

      # Menu + the Settings/ROM Info window declarations must happen
      # before Session#run_async (which realizes the whole tree into a
      # live App) - and, same as the menu build below, can't be pulled
      # into a separate method: Crystal bans any self instance-method
      # call until every ivar is assigned, and @app/@video/@audio/etc.
      # aren't yet. RomInfoWindow builds its OWN window/content purely
      # through the DSL (safe to construct now); SettingsWindow needs a
      # real Tryst::App to embed Tryst::Switch/SegmentedControl/
      # ValueSlider (raw-block args are only ever an AppContract - see
      # its own class comment), so only an EMPTY window is declared here
      # and SettingsWindow's actual content is built after run_async.
      @settings_handle = @session.window(:gemba_settings, title: Locale.translate("menu.settings"),
        resizable: false, modal: true)
      @save_states_handle = @session.window(:gemba_save_states, title: Locale.translate("picker.title"),
        resizable: false, modal: true)
      # Non-modal: browsing achievements while the game keeps running is
      # the point. Content is added after run_async, like Settings.
      @achievements_handle = @session.window(:gemba_achievements, title: Locale.translate("achievements.title"),
        geometry: "560x440", modal: false)
      @rom_info_window = RomInfoWindow.new(@session)

      @menu_bar = @session.menu_bar do |bar|
        bar.menu(label: Locale.translate("menu.file")) do |file|
          file.item(:open_rom, label: Locale.translate("menu.open_rom"), shortcut: "Ctrl+O") { open_rom_dialog }
          file.item(:screenshot, label: Locale.translate("settings.hk_screenshot"), shortcut: "F9") { take_screenshot }
          file.separator
          file.item(:quit, label: Locale.translate("menu.quit"), shortcut: "Ctrl+Q") { quit }
        end

        # One item per tab rather than a lone "Settings…" nested under a
        # Settings menu - same window either way, opened straight on the
        # section the user picked.
        bar.menu(label: Locale.translate("menu.settings")) do |settings_menu|
          settings_menu.item(:settings_general, label: Locale.translate("settings.general")) { show_settings(:general) }
          settings_menu.item(:settings_video, label: Locale.translate("settings.video")) { show_settings(:video) }
          settings_menu.item(:settings_audio, label: Locale.translate("settings.audio")) { show_settings(:audio) }
          settings_menu.item(:settings_gameplay, label: Locale.translate("settings.gameplay")) { show_settings(:gameplay) }
          settings_menu.item(:settings_gamepad, label: Locale.translate("settings.gamepad")) { show_settings(:gamepad) }
          settings_menu.item(:settings_achievements, label: Locale.translate("settings.retroachievements")) { show_settings(:achievements) }
        end

        bar.menu(label: Locale.translate("menu.view")) do |view|
          @rom_info_item = view.item(:rom_info, label: Locale.translate("menu.rom_info"), state: :disabled) { show_rom_info }
          view.item(:achievements, label: Locale.translate("menu.achievements")) { show_achievements }
          view.item(:fullscreen, label: Locale.translate("menu.fullscreen"), shortcut: "F11") { toggle_fullscreen }
          view.separator
          view.item(:open_logs_dir, label: Locale.translate("menu.open_logs_dir")) { open_logs_dir }
        end

        bar.menu(label: Locale.translate("menu.emulation")) do |emu|
          @pause_item = emu.item(:pause, label: Locale.translate("menu.pause"), shortcut: "P") { toggle_pause }
          emu.item(:turbo, label: "Turbo", shortcut: "Tab") { toggle_turbo }
          emu.separator
          @quick_save_item = emu.item(:quick_save, label: Locale.translate("menu.quick_save"),
            shortcut: "F5", state: :disabled) { quick_save }
          @quick_load_item = emu.item(:quick_load, label: Locale.translate("menu.quick_load"),
            shortcut: "F8", state: :disabled) { quick_load }
          @save_states_item = emu.item(:save_states, label: Locale.translate("menu.save_states"),
            shortcut: "F6", state: :disabled) { show_save_states }
        end
      end

      @app = @session.run_async.app
      @video = VideoOutput.new(@app, native_width: NATIVE_WIDTH, native_height: NATIVE_HEIGHT, scale: @config.scale)
      @audio = AudioOutput.new
      @keyboard_map.device = ViewportKeyboard.new(@video.viewport)

      # Overridable because SDL's real focus flag can't be steered from
      # a headless spec - the same seam ra_requester: is.
      @focus_probe = focus_probe || -> { @video.viewport.input_focus? }

      # Viewport packs itself immediately on construction (see its own
      # #initialize) - hidden again right away since the game picker,
      # not the emulator, is what FrameStack shows first. EmulatorFrame
      # #show/#hide take over repacking it once a ROM actually loads.
      @app.command(:pack, :forget, @video.viewport.path)

      @settings_window = SettingsWindow.new(@app, @settings_handle, @events, @hotkeys, @session)
      @save_state_picker = SaveStatePicker.new(@app, @save_states_handle)

      # BoxartFetcher.new does a blocking Dir.mkdir_p, and RomOverrides.new
      # a blocking File.exists?/File.read/JSON.parse - both run here on
      # the main thread, well after @app/the Tk interpreter already
      # exist (unlike Config.new/RomLibrary.new/Locale.load/GameIndex.preload!
      # above, which get away with it only because there's no Tk thread
      # yet at that point) - so both need #off_thread same as every
      # other blocking call in this class.
      boxart_dir = boxart_cache_dir || Paths.boxart_dir
      @boxart_fetcher = @app.off_thread { BoxartFetcher.new(@app, boxart_dir, BoxartFetcher::LibretroBackend.new) }
      @rom_overrides = @app.off_thread { RomOverrides.new(rom_overrides_path || RomOverrides.path, boxart_dir: boxart_dir) }
      Gemba.logger ||= @app.off_thread { SessionLogger.new(logs_dir || Paths.logs_dir) }
      @ra_backend = ra_requester ? Achievements::RetroAchievements::Backend.new(@app, ra_requester) : Achievements::RetroAchievements::Backend.new(@app)
      # ra_retry_schedule: a spec passes millisecond delays so a retry
      # can be watched without the real 30s wait.
      @ra_unlocks = Achievements::RetroAchievements::UnlockQueue.new(@app, @ra_backend, ra_retry_schedule) do
        {@config.ra_username, @config.ra_token}
      end
      @achievements_window = AchievementsWindow.new(@app, @achievements_handle, @session, @rom_library, @config, @rom_overrides)

      on_open_rom = -> { open_rom_dialog }
      on_select = ->(path : String) { load_rom(path) }
      on_quick_load = ->(path : String, slot : Int32) { load_rom(path); @emulator_frame.try(&.load_slot(slot)) }
      on_view_changed = ->(view : String) { switch_picker_view(view) }

      @game_picker = GamePickerFrame.new(@app, ".", @rom_library, @config, @boxart_fetcher, @rom_overrides,
        on_open_rom, on_select, on_quick_load, on_view_changed)
      @list_picker = ListPickerFrame.new(@app, ".", @rom_library, @config, @rom_overrides,
        on_open_rom, on_select, on_quick_load, on_view_changed)

      @active_picker = @config.picker_view == "list" ? @list_picker.as(Frame) : @game_picker.as(Frame)
      @frame_stack = FrameStack.new
      @frame_stack.push(:picker, @active_picker)

      @modal_stack = ModalStack.new(
        on_enter: ->(_name : Symbol) { enter_modal },
        on_exit: -> { exit_modal },
      )
      @rom_info_window.on_close { @modal_stack.pop }
      @save_state_picker.on_close { @modal_stack.pop }
      @save_state_picker.on_save { |slot| @emulator_frame.try(&.save_slot(slot)) }
      @save_state_picker.on_load { |slot| @emulator_frame.try(&.load_slot(slot)) }

      # Only now, once every ivar is assigned, can an instance method
      # actually be called - see the comment above on why the menu/
      # window declarations couldn't be one.
      apply_initial_config
      wire_events
      bind_hotkeys
      watch_app_focus
      watch_menu_bar
      init_gamepad_subsystem if @gamepad_polling
      @app.bring_to_front
    end

    # Enters the Tk event loop. Blocks until the window closes.
    def run : Nil
      @app.mainloop
    end

    def load_rom(path : String) : Nil
      @emulator_frame.try(&.cleanup)

      frame = EmulatorFrame.new(@app, @video, @audio, @keyboard_map, @gamepad_map, @hotkeys, path,
        quick_save_slot: @config.quick_save_slot, backup: @config.save_state_backup?,
        debounce: @config.save_state_debounce.seconds, rewind_seconds: @config.rewind_seconds)
      frame.on_error { |text| report_error(text) }
      frame.on_message { |text| handle_worker_message(text) }
      frame.on_rom_info { |data| update_rom_identity(path, data) }
      @emulator_frame = frame
      @current_rom_id = nil

      if @frame_stack.current == :emulator
        @frame_stack.replace_current(frame)
      else
        @frame_stack.push(:emulator, frame)
      end

      @app.set_window_title("Gemba - #{frame.rom_title}")
      @app.off_thread { @rom_library.remember(frame.rom_title, path, Time.utc.to_rfc3339) }
      @game_picker.refresh
      @list_picker.refresh

      @rom_info_item.try(&.enable)
      @quick_save_item.try(&.enable)
      @quick_load_item.try(&.enable)
      @save_states_item.try(&.enable)

      start_ra_session(path)
    end

    # This game's achievements as RetroAchievements defines them, with
    # earned state - empty until a session is up (see #start_ra_session).
    def ra_achievements : Array(Achievements::Achievement)
      @ra_achievements.values
    end

    # Resolves this ROM against RetroAchievements and, if it's a known
    # game, loads its achievements: r=gameid for the id, r=patch for
    # the definitions, r=unlocks for what's already earned, and only
    # THEN activates the rest on the worker - the unlocks reply has to
    # land before anything is evaluated, or a condition that happens to
    # hold could award something the player earned years ago. Rich
    # presence (script + ping heartbeat) starts on top if switched on.
    # Every step is a no-op unless the user is logged in, and any
    # failure just leaves achievements off for this game - nothing here
    # is worth interrupting play over.
    private def start_ra_session(rom_path : String) : Nil
      stop_ra_session

      return unless @config.ra_enabled?
      return if @config.ra_username.empty? || @config.ra_token.empty?

      username, token = @config.ra_username, @config.ra_token
      include_unofficial = @config.ra_unofficial?
      session = @ra_session

      spawn do
        md5 = @app.off_thread(new_thread: true) { Achievements::RomHash.for_file(rom_path) }
        Gemba.log { "RA: lookup for #{File.basename(rom_path)} md5=#{md5[0, 8]}…" }

        @ra_backend.lookup_game_id(md5) do |game_id|
          next unless session == @ra_session
          unless game_id
            Gemba.log { "RA: no RetroAchievements game matches this ROM" }
            next
          end

          @ra_backend.fetch_patch(username, token, game_id, include_unofficial: include_unofficial) do |patch|
            next unless session == @ra_session
            unless patch
              Gemba.log(SessionLogger::Level::Warn) { "RA: failed to fetch patch data for game #{game_id} - achievements off" }
              next
            end

            @ra_backend.fetch_unlocks(username, token, game_id) do |earned|
              next unless session == @ra_session
              unless earned
                Gemba.log(SessionLogger::Level::Warn) { "RA: failed to fetch unlocks for game #{game_id} - achievements off" }
                next
              end

              begin_ra_session(game_id, patch, earned, username, token)
            end
          end
        end
      end
    end

    # The synchronous tail of #start_ra_session, once everything the
    # site has to say about this game is in hand.
    private def begin_ra_session(game_id : Int64, patch : Achievements::RetroAchievements::Backend::Patch,
                                 earned : Set(UInt32), username : String, token : String) : Nil
      @ra_game_id = game_id
      @ra_script = patch.script
      @ra_achievements.clear
      pending = [] of Achievements::Achievement
      patch.achievements.each do |achievement|
        if earned.includes?(achievement.id)
          # The site only says WHICH ids are earned, not when - marked
          # as of now, same as ruby gemba does.
          @ra_achievements[achievement.id] = achievement.earn
        else
          @ra_achievements[achievement.id] = achievement
          pending << achievement
        end
      end

      @emulator_frame.try(&.worker.activate_achievements(pending))
      Gemba.log do
        "RA: loaded #{@ra_achievements.size} achievements for game #{game_id}, " \
        "#{@ra_achievements.size - pending.size} already earned"
      end
      refresh_achievements_window

      start_rich_presence(username, token, game_id) if @config.ra_rich_presence?
    end

    # Hands the presence script to the worker and starts the heartbeat
    # that makes the site show what's being played. Needs a session
    # (#begin_ra_session) to already be up.
    private def start_rich_presence(username : String, token : String, game_id : Int64) : Nil
      script = @ra_script
      unless script
        Gemba.log { "RA: game #{game_id} has no rich presence script" }
        return
      end

      @emulator_frame.try(&.worker.activate_rich_presence(script))
      start_ping_timer(username, token, game_id)
      Gemba.log { "RA: rich presence active for game #{game_id}" }
    end

    private def start_ping_timer(username : String, token : String, game_id : Int64) : Nil
      # First ping goes out as soon as the session is known, not one
      # full interval later: RA only starts showing "playing <game>"
      # once it has had a ping, and waiting 2 minutes for that reads as
      # the feature being broken. Ruby gets this from its own
      # `@ping_last_at.nil?` short-circuit; App#every has no leading
      # tick, so it's explicit here.
      send_ping(username, token, game_id)
      @ra_ping_timer = @app.every(RA_PING_INTERVAL_MS) { send_ping(username, token, game_id) }
    end

    private def send_ping(username : String, token : String, game_id : Int64) : Nil
      @ra_backend.ping(username, token, game_id, @ra_rich_presence) do |success|
        Gemba.log(success ? SessionLogger::Level::Info : SessionLogger::Level::Warn) do
          "RA: ping g=#{game_id} m=#{@ra_rich_presence.inspect} ok=#{success}"
        end
      end
    end

    # Stops the heartbeat and forgets the presence string. The worker
    # keeps evaluating the script - the string only ever goes out with
    # a ping, so with no ping it's inert, and switching presence back
    # on doesn't have to re-fetch anything.
    private def stop_rich_presence : Nil
      @ra_ping_timer.try(&.cancel)
      @ra_ping_timer = nil
      @ra_rich_presence = ""
    end

    private def stop_ra_session : Nil
      stop_rich_presence
      @ra_session += 1
      @ra_game_id = nil
      @ra_script = nil
      @ra_achievements.clear
      @emulator_frame.try(&.worker.clear_ra_runtime)
      refresh_achievements_window
    end

    # Pulls the latest earned state for the running session (r=unlocks
    # again) and merges it into the list - the achievements window's
    # Sync button. Deliberately leaves the worker's runtime alone: an
    # id newly earned elsewhere stays active there, and if it triggers
    # later #on_achievement_unlocked's own earned check drops it, so a
    # mid-game resync never resets anyone's hit counts.
    private def sync_ra_achievements : Nil
      unless ra_logged_in?
        @achievements_window.logged_in = false
        return
      end
      game_id = @ra_game_id
      unless game_id
        @achievements_window.sync_finished(false, :no_game)
        return
      end

      @achievements_window.sync_started
      Gemba.log { "RA: sync requested for game #{game_id}" }
      @ra_backend.fetch_unlocks(@config.ra_username, @config.ra_token, game_id) do |earned|
        if earned
          earned.each do |id|
            achievement = @ra_achievements[id]?
            @ra_achievements[id] = achievement.earn if achievement && !achievement.earned?
          end
          refresh_achievements_window
        else
          Gemba.log(SessionLogger::Level::Warn) { "RA: sync failed for game #{game_id}" }
        end
        @achievements_window.sync_finished(!earned.nil?)
      end
    end

    private def ra_logged_in? : Bool
      !@config.ra_username.empty? && !@config.ra_token.empty?
    end

    private def refresh_achievements_window : Nil
      @achievements_window.update(@current_rom_id, ra_achievements)
    end

    # An id the worker's runtime just saw trigger. Awarded once at
    # most: the worker knows nothing about earned state, so an id not
    # in this game's list, or already earned, stops here.
    private def on_achievement_unlocked(id : UInt32) : Nil
      achievement = @ra_achievements[id]?
      return if achievement.nil? || achievement.earned?

      earned = achievement.earn
      @ra_achievements[id] = earned
      Gemba.log { "RA: unlocked achievement #{id} #{earned.title.inspect} (#{earned.points}pts)" }
      @video.show_toast(Locale.translate("toast.achievement_unlocked", title: earned.title, points: earned.points))
      @emulator_frame.try(&.take_achievement_screenshot(id)) if @config.ra_screenshot_on_unlock?
      submit_unlock(id)
      refresh_achievements_window
    end

    # Tells the site - and keeps telling it, on the queue's backoff
    # schedule, if the site doesn't answer.
    private def submit_unlock(id : UInt32) : Nil
      @ra_unlocks.submit(id, hardcore: false)
    end

    # Ids the site has yet to confirm - see UnlockQueue#pending_ids.
    def ra_pending_unlocks : Array(UInt32)
      @ra_unlocks.pending_ids
    end

    # The RetroAchievements half of #handle_worker_message. Returns true
    # when text was one of ours.
    private def handle_ra_message(text : String) : Bool
      if presence = text.lchop?("rich_presence:")
        @ra_rich_presence = presence
        Gemba.log { "RA: rich presence = #{presence}" }
      elsif id = text.lchop?("achievement_unlocked:")
        on_achievement_unlocked(id.to_u32)
      elsif payload = text.lchop?("achievement_rejected:")
        id, reason = payload.split(':', 2)
        Gemba.log(SessionLogger::Level::Warn) { "RA: skipping achievement #{id} - #{reason}" }
      elsif payload = text.lchop?("achievement_screenshot_result:")
        finish_achievement_screenshot(payload)
      else
        return false
      end
      true
    end

    # Same upscale as a requested screenshot gets, minus the toast: the
    # unlock's own toast is the one the player should be reading.
    private def finish_achievement_screenshot(payload : String) : Nil
      ok, filename = payload.split(':', 2)
      unless ok == "true"
        Gemba.log(SessionLogger::Level::Warn) { "RA: unlock screenshot failed" }
        return
      end

      scale = @config.screenshot_scale
      upscale_screenshot(File.join(Paths.screenshots_dir, filename.to_s), scale) if scale > 1
      Gemba.log { "RA: unlock screenshot saved: #{filename}" }
    end

    # Patches game_code/rom_id onto the RomLibrary entry #remember just
    # created, once EmulationWorker reports them back - Core (and so
    # game_code/checksum) isn't available until the worker's own thread
    # finishes loading it, arriving well after #remember's own synchronous
    # call above already ran. Same off_thread wrapping as #remember for
    # the same reason (RomLibrary#update_identity's save! is a blocking
    # File.write).
    private def update_rom_identity(path : String, data : RomInfoData) : Nil
      @app.off_thread { @rom_library.update_identity(path, data.game_code, data.checksum) }
      @current_rom_id = RomLibrary.rom_id(data.game_code, data.checksum)
      refresh_achievements_window
    end

    # Swaps the active picker (@frame_stack's current entry, if a picker
    # is actually showing right now - a no-op otherwise, matching ruby's
    # own guard) and persists the choice - see @game_picker/@list_picker's
    # shared PickerRowActions#popup_view_menu, the gear-menu UI that
    # calls this.
    private def switch_picker_view(view : String) : Nil
      return if @config.picker_view == view

      new_picker = view == "list" ? @list_picker.as(Frame) : @game_picker.as(Frame)
      @frame_stack.replace_current(new_picker) if @frame_stack.current == :picker
      @active_picker = new_picker
      @config.picker_view = view
      @app.off_thread { @config.save! }
    end

    # Only the actions with a real handler get bound - HotkeyMap's own
    # defaults also name record/input_record, neither implemented yet -
    # binding those now would just be dead keys. rewind is implemented
    # but deliberately NOT bound here: it's a hold-style action (see
    # EmulatorFrame#poll_rewind), not a single-press toggle like every
    # other hotkey #bind_hotkey wires up.
    private def bind_hotkeys : Nil
      bind_hotkey(:quit) { quit }
      bind_hotkey(:pause) { toggle_pause }
      bind_hotkey(:fast_forward) { toggle_turbo }
      bind_hotkey(:fullscreen) { toggle_fullscreen }
      bind_hotkey(:quick_save) { quick_save }
      bind_hotkey(:quick_load) { quick_load }
      bind_hotkey(:save_states) { show_save_states }
      bind_hotkey(:screenshot) { take_screenshot }
      bind_hotkey(:show_fps) { toggle_show_fps }
    end

    private def bind_hotkey(action : Symbol, &block : -> Nil) : Nil
      hotkey = @hotkeys.key_for(action)
      return unless hotkey

      spec = hotkey.is_a?(Array) ? hotkey.join('-') : hotkey
      @session.on_key(spec) { |_args, _signal| block.call }
    end

    # Ported from ruby's own AppController#gamepad_probe_tick/
    # #refresh_gamepads (start_gamepad_probe et al) - a recursive
    # @app.after chain rather than Tryst::App#every, since (unlike
    # #every) the interval itself needs to change: GAMEPAD_LISTEN_MS
    # while Settings is open with a device attached (for a responsive
    # rebind capture), GAMEPAD_PROBE_MS otherwise. Brings up
    # Tryst::SDL::Gamepad's subsystem, wires its process-wide on_added/
    # on_removed hot-plug callbacks to #refresh_gamepads, and does one
    # eager refresh so a gamepad already connected at startup isn't
    # missed (matches Gamepad.init_subsystem's own doc comment on why
    # that ordering matters).
    private def init_gamepad_subsystem : Nil
      Tryst::SDL::Gamepad.init_subsystem
      Tryst::SDL::Gamepad.on_added { |_instance_id| refresh_gamepads }
      Tryst::SDL::Gamepad.on_removed do |_instance_id|
        @gamepad_map.device = nil
        refresh_gamepads
      end
      refresh_gamepads
      schedule_gamepad_probe(GAMEPAD_PROBE_MS)
    end

    private def schedule_gamepad_probe(ms : Int32) : Nil
      @app.after(ms) { gamepad_probe_tick }
    end

    # While Settings is open and a device is already attached: refreshes
    # its cached button state (Gamepad#button? reads a cache SDL only
    # updates on a pump - see Gamepad.update_state's own doc comment for
    # why this variant, not .poll_events, is safe to call this often)
    # and, while GamepadTab is waiting for a rebind, scans every button
    # for the first one currently held. Otherwise: pumps SDL's event
    # queue (.poll_events, needed for on_added/on_removed to fire at
    # all) to catch a hot-plug - but ONLY while no ROM is actively
    # running, matching ruby's own guard: SDL_PollEvent pumps the same
    # native run loop Tk's own Aqua backend shares on macOS (see
    # Viewport#track_keyboard's own comment), so pumping it from a timer
    # during real gameplay would contend with Tk for it. Live gameplay
    # input still gets fresh gamepad state every frame regardless -
    # EmulatorFrame#on_frame's own call to Gamepad.update_state, not
    # this loop.
    private def gamepad_probe_tick : Nil
      device = @gamepad_map.device

      if @modal_stack.current == :settings && device
        Tryst::SDL::Gamepad.update_state

        if @settings_window.gamepad_tab.listening_for
          Tryst::SDL::Gamepad::BUTTONS.each do |gp_btn|
            next unless device.button?(gp_btn)
            @settings_window.gamepad_tab.capture_mapping(gp_btn.to_s)
            break
          end
        end

        schedule_gamepad_probe(GAMEPAD_LISTEN_MS)
        return
      end

      Tryst::SDL::Gamepad.poll_events if @frame_stack.current != :emulator
      schedule_gamepad_probe(GAMEPAD_PROBE_MS)
    rescue Tryst::TclError
      # The window this chain belongs to was destroyed while a tick was
      # still pending (a recursive @app.after chain has no built-in way
      # to know that happened) - stop rescheduling rather than keep
      # firing into a dead window forever.
    end

    # Opens every currently connected gamepad just long enough to read
    # its name for the Settings dropdown, keeping the FIRST one as
    # GamepadMap's own #device and closing the rest - matches ruby's own
    # `@gamepad ||= gp` (a second connected pad doesn't steal the active
    # one; only #on_removed clearing #device first lets a later refresh
    # pick a new one). #open raising for an id SDL reports but can't
    # actually open (a mid-enumeration disconnect) just skips that id
    # rather than aborting the whole refresh.
    private def refresh_gamepads : Nil
      names = [] of String

      Tryst::SDL::Gamepad.ids.each do |id|
        gamepad = begin
          Tryst::SDL::Gamepad.open(id)
        rescue Tryst::SDL::Error
          next
        end
        names << gamepad.name

        if @gamepad_map.device
          gamepad.destroy
        else
          @gamepad_map.device = gamepad
          @gamepad_map.load_config(@config)
        end
      end

      @settings_window.gamepad_tab.update_gamepad_list(names)
    end

    private def apply_initial_config : Nil
      @video.filter = @config.pixel_filter == "nearest" ? :nearest : :linear
      @video.integer_scale = @config.integer_scale?
      @video.color_correction = @config.color_correction?
      @video.frame_blending = @config.frame_blending?
      @video.keep_aspect_ratio = @config.keep_aspect_ratio?
      @video.show_fps = @config.show_fps?
      @audio.volume = @config.volume / 100.0
      @audio.muted = @config.muted?
      @settings_window.load_from_config(@config)
      refresh_gamepad_tab
    end

    # Live-applies every Gemba::Events signal to VideoOutput/AudioOutput
    # AND persists it to Config - settings changes should take effect
    # live and persist, not just one or the other.
    private def wire_events : Nil
      @events.scale_changed.connect do |scale|
        @app.set_window_geometry("#{NATIVE_WIDTH * scale}x#{NATIVE_HEIGHT * scale}")
        @config.scale = scale
        save_config
      end
      @events.volume_changed.connect do |volume|
        @audio.volume = volume
        @config.volume = (volume * 100).to_i
        save_config
      end
      @events.mute_changed.connect do |muted|
        @audio.muted = muted
        @config.muted = muted
        save_config
      end
      @events.filter_changed.connect do |mode|
        @video.filter = mode
        @config.pixel_filter = mode.to_s
        save_config
      end
      @events.integer_scale_changed.connect do |enabled|
        @video.integer_scale = enabled
        @config.integer_scale = enabled
        save_config
      end
      @events.color_correction_changed.connect do |enabled|
        @video.color_correction = enabled
        @config.color_correction = enabled
        save_config
      end
      @events.frame_blending_changed.connect do |enabled|
        @video.frame_blending = enabled
        @config.frame_blending = enabled
        save_config
      end
      @events.aspect_ratio_changed.connect do |enabled|
        @video.keep_aspect_ratio = enabled
        @config.keep_aspect_ratio = enabled
        save_config
      end

      # Nothing to apply eagerly - #watch_app_focus reads the setting at
      # the moment the app is deactivated. Switching it off mid-session
      # still lets an already-held focus pause release normally.
      @events.pause_on_focus_loss_changed.connect do |enabled|
        @config.pause_on_focus_loss = enabled
        save_config
      end

      # Also nothing to apply eagerly - #take_screenshot reads
      # @config.screenshot_scale at the moment a screenshot is taken.
      @events.screenshot_scale_changed.connect do |scale|
        @config.screenshot_scale = scale
        save_config
      end

      # Takes effect starting with the NEXT #load_rom - see #load_rom's
      # own rewind_seconds: argument, and EmulationWorker's own doc
      # comment on why the buffer size can't change on a running Core.
      @events.rewind_seconds_changed.connect do |seconds|
        @config.rewind_seconds = seconds
        save_config
      end

      # Both switches take effect on the ROM already running, rather
      # than only on the next load.
      @events.ra_enabled_changed.connect do |enabled|
        @config.ra_enabled = enabled
        save_config
        if enabled
          @emulator_frame.try { |frame| start_ra_session(frame.worker.rom_path) }
        else
          stop_ra_session
        end
      end
      @events.ra_rich_presence_changed.connect do |enabled|
        @config.ra_rich_presence = enabled
        save_config
        if enabled
          # Only once a session is up; if one is still being resolved,
          # #begin_ra_session reads the switch itself when it lands.
          @ra_game_id.try { |game_id| start_rich_presence(@config.ra_username, @config.ra_token, game_id) }
        else
          stop_rich_presence
        end
      end
      @events.ra_screenshot_on_unlock_changed.connect do |enabled|
        @config.ra_screenshot_on_unlock = enabled
        save_config
      end
      @achievements_window.on_sync { sync_ra_achievements }
      # The set of achievements itself changes, so the session is
      # rebuilt from r=patch - unlike Sync, which only re-reads earned
      # state.
      @achievements_window.on_unofficial_changed do |include_unofficial|
        @config.ra_unofficial = include_unofficial
        save_config
        @emulator_frame.try { |frame| start_ra_session(frame.worker.rom_path) }
      end

      @events.ra_login_requested.connect do |username, password|
        @ra_backend.login_with_password(username, password) do |token, error|
          if token
            @config.ra_username = username
            @config.ra_token = token
            save_config
            @settings_window.achievements_tab.login_succeeded(token)
            @achievements_window.logged_in = true
          else
            @settings_window.achievements_tab.auth_failed(error.to_s)
          end
        end
      end
      @events.ra_verify_requested.connect do
        @ra_backend.verify_token(@config.ra_username, @config.ra_token) do |success, error|
          if success
            @settings_window.achievements_tab.ping_succeeded
            @app.after(3000) { @settings_window.achievements_tab.clear_transient_feedback }
          else
            @settings_window.achievements_tab.auth_failed(error.to_s)
          end
        end
      end
      @events.ra_logout_requested.connect do
        @config.ra_token = ""
        save_config
        @settings_window.achievements_tab.logged_out
        @achievements_window.logged_in = false
      end
      @events.ra_reset_requested.connect do
        @config.ra_username = ""
        @config.ra_token = ""
        save_config
      end

      @events.keyboard_mapping_changed.connect do |btn, keysym|
        @keyboard_map.set(btn, keysym)
        @keyboard_map.save_to_config(@config)
        save_config
      end
      @events.gamepad_mapping_changed.connect do |btn, gp_button|
        @gamepad_map.set(btn, gp_button)
        @gamepad_map.save_to_config(@config)
        save_config
      end
      @events.gamepad_dead_zone_changed.connect do |threshold|
        @gamepad_map.dead_zone = threshold
        @gamepad_map.save_to_config(@config)
        save_config
      end
      @events.keyboard_reset.connect do
        @keyboard_map.reset!
        @keyboard_map.save_to_config(@config)
        save_config
      end
      @events.gamepad_reset.connect do
        @gamepad_map.reset!
        @gamepad_map.save_to_config(@config)
        save_config
      end
      # config.reload! is a real blocking File.read - off_thread same as
      # #save_config's own File.write.
      @events.undo_input_mappings.connect do |keyboard_mode|
        if keyboard_mode
          @app.off_thread { @keyboard_map.reload!(@config) }
        else
          @app.off_thread { @gamepad_map.reload!(@config) }
        end
        refresh_gamepad_tab
      end
      @events.input_mode_changed.connect { refresh_gamepad_tab }
    end

    # Pushes whichever map (keyboard or gamepad) is active in the
    # Gamepad tab's own combo back into it - the tab has no reference to
    # either map itself (see Settings::GamepadTab's own doc comment), so
    # this is the only place its display can pick up real saved state:
    # initial load, after Undo, and after switching modes.
    private def refresh_gamepad_tab : Nil
      tab = @settings_window.gamepad_tab
      if tab.keyboard_mode?
        tab.refresh(@keyboard_map.labels, 0)
      else
        tab.refresh(@gamepad_map.labels.transform_values(&.to_s), @gamepad_map.dead_zone_pct)
      end
    end

    # Config#save! is a real blocking File.write - routed through
    # off_thread since this runs from a live event, well after
    # @app/the Tk mainloop both exist, unlike Config's initial load in
    # #initialize (see that method's own comment).
    private def save_config : Nil
      @app.off_thread { @config.save! }
    end

    private def open_rom_dialog : Nil
      filetypes : Tryst::FileTypes = [{"GBA ROMs", [".gba"]}, {"All Files", "*"}]
      path = @app.choose_open_file(filetypes: filetypes, title: Locale.translate("menu.open_rom").delete('…'))
      load_rom(path) if path.is_a?(String)
    end

    def quick_save : Nil
      @emulator_frame.try(&.quick_save)
    end

    def quick_load : Nil
      @emulator_frame.try(&.quick_load)
    end

    # save_result:<ok>:<slot>:<text> / load_result:<ok>:<slot>:<text>,
    # from EmulatorFrame's own #on_message pass-through (see its class
    # comment for why the actual save/load happens on the worker thread
    # and only the outcome crosses back). Failures are logged rather
    # than shown to the player - a modal message_box would be jarring
    # for something meant to be a quick, low-ceremony action.
    private def handle_worker_message(text : String) : Nil
      # Handled before the 4-part split below, which would raise on a
      # message this shape (a presence string has no slot/ok fields, and
      # can itself contain colons; an unlock is a bare id).
      return if handle_ra_message(text)

      # Also handled up front: screenshot_result:<ok>:<filename> only
      # has 3 fields, not the 4 save_result/load_result carry - the
      # generic split below would otherwise raise on parts[3].
      if payload = text.lchop?("screenshot_result:")
        ok, filename = payload.split(':', 2)
        if ok == "true"
          scale = @config.screenshot_scale
          upscale_screenshot(File.join(Paths.screenshots_dir, filename), scale) if scale > 1
          @video.show_toast(Locale.translate("toast.screenshot_saved", name: filename))
        else
          @video.show_toast(Locale.translate("toast.screenshot_failed"))
        end
        return
      end

      parts = text.split(':', 4)
      tag, ok, slot, message = parts[0], parts[1], parts[2], parts[3]

      case tag
      when "save_result"
        if ok == "true"
          @video.show_toast(Locale.translate("toast.state_saved", slot: slot))
          write_state_thumbnail(slot.to_i)
        else
          STDERR.puts "[Gemba] #{message}"
        end
      when "load_result"
        # The previous frame is now stale - blending against it would
        # show a mix of the pre-load frame and the loaded one, for the
        # one frame it takes VideoOutput to catch up (matches ruby's
        # own render_clean_if_paused, ported at the granularity that
        # actually applies here: FramePainter's own blend buffer).
        if ok == "true"
          @video.painter.reset!
          @video.show_toast(Locale.translate("toast.state_loaded", slot: slot))
        else
          STDERR.puts "[Gemba] #{message}"
        end
      end
    end

    # Writes the current frame as this slot's thumbnail PNG - the
    # state_dir/state<slot>.ss the worker just wrote to already exists
    # (SaveStateManager#save_state creates it before saving), so this
    # never needs its own mkdir_p.
    private def write_state_thumbnail(slot : Int32) : Nil
      bytes = @video.last_frame_argb
      return unless bytes

      dir = @emulator_frame.try(&.state_dir)
      return unless dir

      path = SaveStateManager.screenshot_path(dir, slot)
      photo = Tryst::Photo.new(@app, width: @video.native_width, height: @video.native_height)
      begin
        photo.put_zoomed_block(bytes, @video.native_width, @video.native_height, format: Tryst::PixelFormat::ARGB)
        photo.command(:write, path, format: "png")
      ensure
        photo.delete
      end
    end

    # Rewrites path in place at scale x its native size, via Tk::Photo's
    # own PNG codec (same as #write_state_thumbnail) rather than a
    # Crystal-side one. Runs on the Tk thread, same as every other Photo
    # write in this class - the file is tiny (native 240x160 GBA
    # resolution), so this is a fast local round-trip, not a real
    # blocking-syscall concern.
    private def upscale_screenshot(path : String, scale : Int32) : Nil
      source = Tryst::Photo.new(@app, file: path)
      begin
        size = source.get_size
        pixels = source.get_image
        dest = Tryst::Photo.new(@app, width: size[:width] * scale, height: size[:height] * scale)
        begin
          dest.put_zoomed_block(pixels[:data], size[:width], size[:height],
            zoom_x: scale, zoom_y: scale, format: Tryst::PixelFormat::RGBA)
          dest.command(:write, path, format: "png")
        ensure
          dest.delete
        end
      ensure
        source.delete
      end
    end

    # Takes the RAW emulator frame straight from the core (see
    # Core#take_screenshot_to_file) - deliberately NOT the same
    # post-color-correction/frame-blending frame VideoOutput displays
    # (that's what write_state_thumbnail uses for save-state thumbnails,
    # where matching what's on screen actually matters). The core's own
    # PNG encoder is the canonical screenshot and needs no Tk::Photo
    # round-trip; runs on the worker thread since Core is
    # worker-thread-only, reporting back through handle_worker_message.
    def take_screenshot : Nil
      @emulator_frame.try(&.take_screenshot)
    end

    private def toggle_pause : Nil
      @emulator_frame.try(&.toggle_pause)
      update_pause_label
    end

    private def update_pause_label : Nil
      paused = @emulator_frame.try(&.paused?) || false
      label = paused ? Locale.translate("menu.resume") : Locale.translate("menu.pause")
      @pause_item.try(&.configure(label: label))
    end

    private def toggle_turbo : Nil
      @emulator_frame.try(&.toggle_turbo)
    end

    private def toggle_show_fps : Nil
      @video.show_fps = !@video.show_fps?
      @config.show_fps = @video.show_fps?
      save_config
    end

    private def toggle_fullscreen : Nil
      window = @app.window
      window.set_attribute("-fullscreen", !fullscreen?)
    end

    private def fullscreen? : Bool
      @app.tcl_to_bool(@app.window.attribute("-fullscreen"))
    end

    # Reveals the log directory in the OS file manager - same as ruby
    # gemba's own View menu item, which also only opens the folder
    # rather than rendering logs in-app.
    private def open_logs_dir : Nil
      dir = Gemba.logger.try(&.log_dir) || Paths.logs_dir
      @app.off_thread do
        Dir.mkdir_p(dir)
        platform = Tryst.platform
        if platform.darwin?
          Process.run("open", [dir])
        elsif platform.windows?
          Process.run("explorer.exe", [dir.gsub('/', '\\')])
        else
          Process.run("xdg-open", [dir])
        end
      end
    end

    private def report_error(text : String) : Nil
      @app.message_box(text, title: "Emulation error", icon: :error)
    end

    # Public rather than private like most menu actions - see
    # main_window_spec.cr's own settings/ROM-info reopen-after-close
    # tests, which need to trigger this the same way a real menu click
    # does without reaching for a reflection hack.
    def show_settings(tab : Symbol = :general) : Nil
      return if @modal_stack.active?

      @settings_window.load_from_config(@config)
      refresh_gamepad_tab
      @settings_window.select_tab(tab)
      @modal_stack.push(:settings, @settings_window.handle)
    end

    # Non-modal, so it doesn't go through ModalStack - it can stay open
    # while the game runs and while Settings is up.
    def show_achievements : Nil
      @achievements_window.logged_in = ra_logged_in?
      @achievements_window.show(@current_rom_id, ra_achievements)
    end

    def show_rom_info : Nil
      return if @modal_stack.active?

      frame = @emulator_frame
      return unless frame

      data = frame.rom_info
      return unless data

      sav_path = File.join(Paths.saves_dir, "#{frame.rom_title}.sav")
      @rom_info_window.show(data, frame.rom_title, sav_path)
      @modal_stack.push(:rom_info, @rom_info_window.handle)
    end

    def show_save_states : Nil
      return if @modal_stack.active?

      frame = @emulator_frame
      return unless frame

      dir = frame.state_dir
      return unless dir

      @save_state_picker.refresh(dir, @config.quick_save_slot)
      @modal_stack.push(:save_states, @save_state_picker.handle)
    end

    # Reasons in use: :modal (a settings/ROM-info/save-state dialog is
    # up), :focus_loss (the app stopped being the active one), :menu (a
    # menu bar cascade is posted). AutoPause decides whether this
    # particular hold/release is the one that actually flips the
    # emulator, so overlapping causes nest correctly.
    private def hold_auto_pause(reason : Symbol) : Nil
      frame = @emulator_frame
      return unless @auto_pause.hold(reason, frame.try(&.paused?) || false)

      Gemba.log { "auto-pause: hold #{reason}" }
      frame.try(&.pause)
      update_pause_label
    end

    private def release_auto_pause(reason : Symbol) : Nil
      return unless @auto_pause.release(reason)

      Gemba.log { "auto-pause: release #{reason}" }
      @emulator_frame.try(&.resume)
      update_pause_label
    end

    # Polls SDL for the window's keyboard focus, the same way ruby gemba
    # does and for the same reason: Tk's <Deactivate>/<Activate> look
    # like the right events but never arrive for a toplevel SDL has
    # adopted - <Activate> does, <Deactivate> does not - so a binding on
    # them silently does nothing.
    #
    # Latched on the first focus actually OBSERVED rather than trusted
    # from the start, because the flag isn't meaningful everywhere: on
    # macOS SDL adopts the toplevel's own window and the flag tracks
    # Cmd-Tab and Spaces, but X11 hands SDL a child window of the frame,
    # which never receives X input focus at all, so it reads false
    # forever. Latching means the feature stays off there instead of
    # pausing a game that nothing would ever unpause.
    #
    # The release is unconditional while the hold honours the setting -
    # switching the setting off while the app is in the background has
    # to still let the game come back.
    private def watch_app_focus : Nil
      probe = @focus_probe
      @app.every(FOCUS_POLL_MS) do
        if probe.call
          @app_focus_seen = true
          release_auto_pause(:focus_loss)
        elsif @app_focus_seen && @config.pause_on_focus_loss?
          hold_auto_pause(:focus_loss)
        end
      end
    end

    # A menu posted over a game running at max turbo makes the whole UI
    # crawl: Tk deliberately keeps its event loop running while a menu
    # is open (on macOS it spins one on NSEventTrackingRunLoopMode for
    # exactly that reason), so the emulation worker goes right on
    # competing with the menu for it.
    #
    # <<MenuSelect>> fires on the menu BAR as soon as one of its
    # cascades opens, which is the hold. There's no matching "menu
    # closed" event on macOS - the native NSMenu delegate generates none
    # - but ending menu tracking does clear the bar's active entry, so
    # polling for that is the release. X11 clears it too AND fires a
    # final <<MenuSelect>>, so there the poll rarely gets a turn.
    private def watch_menu_bar : Nil
      bar = @menu_bar
      return unless bar

      @app.bind(bar.path, :menu_select) { |_values, _signal| menu_activity }
    end

    private def menu_activity : Nil
      if menu_bar_idle?
        @menu_poll.try(&.cancel)
        @menu_poll = nil
        release_auto_pause(:menu)
      else
        hold_auto_pause(:menu)
        @menu_poll ||= @app.every(MENU_POLL_MS) { menu_activity }
      end
    end

    # True once no cascade of the menu bar is posted any more. Tk answers
    # "none" for a menu with no active entry; anything unexpected (an
    # error off a torn-down bar) counts as closed too, rather than
    # leaving the game paused with nothing left to release it.
    private def menu_bar_idle? : Bool
      bar = @menu_bar
      return true unless bar

      @app.command(bar.path, :index, "active").to_i?.nil?
    rescue
      true
    end

    # Pauses/resumes emulation around a modal's whole visible lifetime -
    # a settings dialog open over a running game shouldn't keep burning
    # CPU (or audio) behind it. Only the FIRST modal entered/last exited
    # triggers this (ModalStack only calls on_enter/on_exit at the
    # empty <-> non-empty transition), matching ruby's own
    # modal_entered/modal_exited.
    #
    # Unconditional, unlike the focus-loss pause below: a modal covers
    # the game whether or not the user wants focus changes to pause it.
    private def enter_modal : Nil
      hold_auto_pause(:modal)
    end

    private def exit_modal : Nil
      release_auto_pause(:modal)

      # A modal's own #show grabs keyboard focus (Handle#show); nothing
      # releases it back on hide, so it's still nominally on the (now
      # withdrawn) modal - confirmed directly, app-wide hotkeys (bind .,
      # see #bind_hotkey) stop reaching "." until focus is reclaimed.
      # EmulatorFrame and ListPickerFrame both reclaim their own focus
      # target on #show (viewport / tree, respectively) - GamePickerFrame
      # doesn't grab any (matching ruby's own game_picker_frame.rb,
      # which doesn't either - its cards aren't keyboard-focusable).
      # Re-running whichever is current is still correct either way.
      @frame_stack.current_frame.try(&.show)
    end

    private def quit : Nil
      @emulator_frame.try(&.cleanup)
      @ra_unlocks.shutdown
      @audio.destroy
      @app.destroy
    end
  end
end
