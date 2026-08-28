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
require "./game_picker_frame"
require "./list_picker_frame"
require "./boxart_fetcher"
require "./boxart_fetcher/libretro_backend"
require "./rom_overrides"
require "./achievements/retro_achievements/backend"
require "./rom_info_window"
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
    @was_paused_before_modal : Bool = false
    @pause_item : Tryst::UI::Handle?

    # rom_library_path/config_path forward straight to RomLibrary/Config
    # - see their own doc comments. Production code omits both; a spec
    # passes isolated tempfile paths so a test ROM load never touches
    # the real ~/Library/Application Support/gemba data (same
    # state_dir_override convention EmulationWorker's save-state tests
    # already use).
    # Config/Locale/GameIndex's own file reads below are genuine blocking
    # syscalls (see the same guard #take_screenshot routes around via
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
      @rom_info_window = RomInfoWindow.new(@session)

      @session.menu_bar do |bar|
        bar.menu(label: Locale.translate("menu.file")) do |file|
          file.item(:open_rom, label: Locale.translate("menu.open_rom"), shortcut: "Ctrl+O") { open_rom_dialog }
          file.item(:screenshot, label: Locale.translate("settings.hk_screenshot"), shortcut: "F9") { take_screenshot }
          file.separator
          file.item(:quit, label: Locale.translate("menu.quit"), shortcut: "Ctrl+Q") { quit }
        end

        bar.menu(label: Locale.translate("menu.settings")) do |settings_menu|
          settings_menu.item(:open_settings, label: "#{Locale.translate("menu.settings")}…") { show_settings }
        end

        bar.menu(label: Locale.translate("menu.view")) do |view|
          @rom_info_item = view.item(:rom_info, label: Locale.translate("menu.rom_info"), state: :disabled) { show_rom_info }
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

      # Viewport packs itself immediately on construction (see its own
      # #initialize) - hidden again right away since the game picker,
      # not the emulator, is what FrameStack shows first. EmulatorFrame
      # #show/#hide take over repacking it once a ROM actually loads.
      @app.command(:pack, :forget, @video.viewport.path)

      @settings_window = SettingsWindow.new(@app, @settings_handle, @events, @hotkeys)
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

      # Takes effect starting with the NEXT #load_rom - see #load_rom's
      # own rewind_seconds: argument, and EmulationWorker's own doc
      # comment on why the buffer size can't change on a running Core.
      @events.rewind_seconds_changed.connect do |seconds|
        @config.rewind_seconds = seconds
        save_config
      end

      @events.ra_enabled_changed.connect do |enabled|
        @config.ra_enabled = enabled
        save_config
      end
      @events.ra_rich_presence_changed.connect do |enabled|
        @config.ra_rich_presence = enabled
        save_config
      end
      @events.ra_screenshot_on_unlock_changed.connect do |enabled|
        @config.ra_screenshot_on_unlock = enabled
        save_config
      end

      @events.ra_login_requested.connect do |username, password|
        @ra_backend.login_with_password(username, password) do |token, error|
          if token
            @config.ra_username = username
            @config.ra_token = token
            save_config
            @settings_window.achievements_tab.login_succeeded(token)
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
    # off_thread same as #take_screenshot's own Dir.mkdir_p/Time.local,
    # and for the same reason (this runs from a live event, well after
    # @app/the Tk mainloop both exist, unlike Config's initial load in
    # #initialize - see that method's own comment).
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

    # Captures whatever's currently on screen (post color-correction/
    # frame-blending, same as ruby's own Core#video_buffer_argb-based
    # take_screenshot) at the CURRENT scale.
    def take_screenshot : Nil
      bytes = @video.last_frame_argb
      return unless bytes

      dir = Paths.screenshots_dir
      # Both Dir.mkdir_p and Time.local are blocking calls that don't
      # belong on Tk's own thread (Time.local lazily loads timezone data
      # from disk the first time anything asks for local time - not
      # obviously a file read, but confirmed directly: it trips the same
      # syscall guard File.mkdir_p does).
      stamp = @app.off_thread do
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        Time.local.to_s("%Y%m%d_%H%M%S")
      end
      rom_title = @emulator_frame.try(&.rom_title)
      title = rom_title.nil? || rom_title.empty? ? "gemba" : rom_title
      path = File.join(dir, "#{title}_#{stamp}.png")

      scale = @config.scale
      out_w = @video.native_width * scale
      out_h = @video.native_height * scale
      photo = Tryst::Photo.new(@app, width: out_w, height: out_h)
      begin
        photo.put_zoomed_block(bytes, @video.native_width, @video.native_height,
          zoom_x: scale, zoom_y: scale, format: Tryst::PixelFormat::ARGB)
        photo.command(:write, path, format: "png")
      ensure
        photo.delete
      end
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
    def show_settings : Nil
      return if @modal_stack.active?

      @settings_window.load_from_config(@config)
      refresh_gamepad_tab
      @modal_stack.push(:settings, @settings_window.handle)
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

    # Pauses/resumes emulation around a modal's whole visible lifetime -
    # a settings dialog open over a running game shouldn't keep burning
    # CPU (or audio) behind it. Only the FIRST modal entered/last exited
    # triggers this (ModalStack only calls on_enter/on_exit at the
    # empty <-> non-empty transition), matching ruby's own
    # modal_entered/modal_exited.
    private def enter_modal : Nil
      frame = @emulator_frame
      @was_paused_before_modal = frame.try(&.paused?) || false
      frame.try(&.pause) unless @was_paused_before_modal
    end

    private def exit_modal : Nil
      @emulator_frame.try(&.resume) unless @was_paused_before_modal

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
      @audio.destroy
      @app.destroy
    end
  end
end
