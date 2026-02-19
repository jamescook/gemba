# frozen_string_literal: true

require 'fileutils'
require_relative 'event_bus'
require_relative 'locale'
require_relative 'modal_stack'
require_relative 'frame_stack'
require_relative 'platform'

module Gemba
  # Application controller — the brain of the app.
  #
  # Owns menus, hotkeys, modals, config, rom library, input maps, frame
  # lifecycle, and mode tracking. MainWindow is a pure Tk shell that this
  # controller drives.
  #
  # This is what CLI instantiates.
  class AppController
    include Gemba
    include Locale::Translatable
    include BusEmitter

    DEFAULT_SCALE = 3
    EVENT_LOOP_FAST_MS = 1
    EVENT_LOOP_IDLE_MS = 50
    GAMEPAD_PROBE_MS   = 2000
    GAMEPAD_LISTEN_MS  = 50

    MODAL_LABELS = {
      settings: 'menu.settings',
      picker: 'menu.save_states',
      rom_info: 'menu.rom_info',
      replay_player: 'replay.replay_player',
    }.freeze

    attr_reader :app, :config, :settings_window, :kb_map, :gp_map, :running, :scale

    def initialize(rom_path = nil, sound: true, fullscreen: false, frames: nil)
      @window = MainWindow.new
      @app = @window.app
      @frame_stack = @window.frame_stack

      Gemba.bus = EventBus.new

      @sound = sound
      @config = Gemba.user_config
      @scale = @config.scale
      @fullscreen = fullscreen
      @frame_limit = frames
      @platform = Platform.default
      @initial_rom = rom_path
      @running = true
      @rom_path = nil
      @gamepad = nil
      @rom_library = RomLibrary.new

      @kb_map = KeyboardMap.new(@config)
      @gp_map = GamepadMap.new(@config)
      @keyboard = VirtualKeyboard.new
      @kb_map.device = @keyboard
      @hotkeys = HotkeyMap.new(@config)

      check_writable_dirs

      @window.set_timer_speed(EVENT_LOOP_IDLE_MS)
      @window.set_geometry(@platform.width * @scale, @platform.height * @scale)
      @window.set_title("gemba")

      build_menu

      @modal_stack = ModalStack.new(
        on_enter: method(:modal_entered),
        on_exit:  method(:modal_exited),
        on_focus_change: method(:modal_focus_changed),
      )

      dismiss = proc { @modal_stack.pop }

      @rom_info_window = RomInfoWindow.new(@app, callbacks: {
        on_dismiss: dismiss, on_close: dismiss,
      })
      @state_picker = SaveStatePicker.new(@app, callbacks: {
        on_dismiss: dismiss, on_close: dismiss,
      })
      @settings_window = SettingsWindow.new(@app, tip_dismiss_ms: @config.tip_dismiss_ms, callbacks: {
        on_validate_hotkey:     method(:validate_hotkey),
        on_validate_kb_mapping: method(:validate_kb_mapping),
        on_dismiss: dismiss, on_close: dismiss,
      })

      @settings_window.refresh_gamepad(@kb_map.labels, @kb_map.dead_zone_pct)
      @settings_window.refresh_hotkeys(@hotkeys.labels)
      push_settings_to_ui

      boxart_backend = BoxartFetcher::LibretroBackend.new
      @boxart_fetcher = BoxartFetcher.new(app: @app, cache_dir: Config.boxart_dir, backend: boxart_backend)
      @rom_overrides  = RomOverrides.new
      @game_picker = GamePickerFrame.new(app: @app, rom_library: @rom_library,
                                         boxart_fetcher: @boxart_fetcher, rom_overrides: @rom_overrides)
      @frame_stack.push(:picker, @game_picker)
      @window.set_geometry(GamePickerFrame::PICKER_DEFAULT_W, GamePickerFrame::PICKER_DEFAULT_H)
      @window.set_minsize(GamePickerFrame::PICKER_MIN_W, GamePickerFrame::PICKER_MIN_H)
      apply_frame_aspect(@game_picker)

      setup_drop_target
      setup_global_hotkeys
      setup_bus_subscriptions
    end

    def run
      @app.after(1) { load_rom(@initial_rom) } if @initial_rom
      @app.mainloop
    ensure
      cleanup
    end

    def ready? = @initial_rom ? frame&.rom_loaded? : true

    # Current active frame (for tests and external access)
    def frame = @frame_stack.current_frame
    def current_view = @frame_stack.current

    def running=(val)
      @running = val
      @emulator_frame&.running = val
      return if val
      cleanup
      @app.command(:destroy, '.')
    end

    def disable_confirmations!
      @disable_confirmations = true
    end

    private

    def confirm(title:, message:)
      return true if @disable_confirmations
      result = @app.command('tk_messageBox',
        parent: '.',
        title: title,
        message: message,
        type: :okcancel,
        icon: :warning)
      result == 'ok'
    end

    # ── Bus subscriptions ──────────────────────────────────────────────

    def setup_bus_subscriptions
      bus = Gemba.bus

      # Window-level
      bus.on(:scale_changed) { |val| apply_scale(val) }

      # Input maps
      bus.on(:gamepad_map_changed)  { |btn, gp| active_input.set(btn, gp) }
      bus.on(:keyboard_map_changed) { |btn, key| active_input.set(btn, key) }
      bus.on(:deadzone_changed)     { |val| active_input.set_dead_zone(val) }
      bus.on(:gamepad_reset)        { active_input.reset! }
      bus.on(:keyboard_reset)       { active_input.reset! }
      bus.on(:undo_gamepad)         { undo_mappings }

      # Hotkeys
      bus.on(:hotkey_changed) { |action, key| @hotkeys.set(action, key) }
      bus.on(:hotkey_reset)   { @hotkeys.reset! }
      bus.on(:undo_hotkeys)   { undo_hotkeys }

      # Settings window actions
      bus.on(:settings_save)       { save_config }
      bus.on(:per_game_toggled)    { |val| toggle_per_game(val) }
      bus.on(:open_config_dir)     { open_config_dir }
      bus.on(:open_recordings_dir) { open_recordings_dir }
      bus.on(:open_replay_player)  { show_replay_player }

      # Frame → controller events
      bus.on(:pause_changed) do |paused|
        label = paused ? translate('menu.resume') : translate('menu.pause')
        @app.command(@emu_menu, :entryconfigure, 0, label: label)
      end
      bus.on(:recording_changed)       { update_recording_menu }
      bus.on(:input_recording_changed) { update_input_recording_menu }
      bus.on(:request_quit)            { self.running = false }
      bus.on(:request_escape)          { @fullscreen ? toggle_fullscreen : (self.running = false) }
      bus.on(:request_fullscreen)      { toggle_fullscreen }
      bus.on(:request_save_states)     { show_state_picker }
      bus.on(:request_open_rom)        { handle_open_rom }
      bus.on(:rom_selected)            { |path| load_rom(path) }
      bus.on(:request_show_fps_toggle) do
        frame&.receive(:toggle_show_fps)
        show = frame&.show_fps? || false
        @app.set_variable(SettingsWindow::VAR_SHOW_FPS, show ? '1' : '0')
      end

      # ── ROM loaded reactions ──────────────────────────────────────────
      # Config, RomLibrary, and SettingsWindow each subscribe themselves
      # via subscribe_to_bus. AppController only handles what it owns.

      bus.on(:rom_loaded) do |**|
        refresh_from_config
      end

      bus.on(:rom_loaded) do |title:, path:, saves_dir:, **|
        @window.set_title("gemba \u2014 #{title}")
        @app.command(@view_menu, :entryconfigure, 0, state: :normal)  # Game Library
        @app.command(@view_menu, :entryconfigure, 2, state: :normal)  # ROM Info
        [3, 4, 6, 8, 9].each { |i| @app.command(@emu_menu, :entryconfigure, i, state: :normal) }
        rebuild_recent_menu

        sav_name = File.basename(path, File.extname(path)) + '.sav'
        sav_path = File.join(saves_dir, sav_name)
        if File.exist?(sav_path)
          @emulator_frame.receive(:show_toast, message: translate('toast.loaded_sav', name: sav_name))
        else
          @emulator_frame.receive(:show_toast, message: translate('toast.created_sav', name: sav_name))
        end
      end
    end

    # ── Menu ───────────────────────────────────────────────────────────

    def build_menu
      menubar = '.menubar'
      @app.command(:menu, menubar)
      @app.command('.', :configure, menu: menubar)

      # File menu
      @app.command(:menu, "#{menubar}.file", tearoff: 0)
      @app.command(menubar, :add, :cascade, label: translate('menu.file'), menu: "#{menubar}.file")

      @app.command("#{menubar}.file", :add, :command,
                   label: translate('menu.open_rom'), accelerator: 'Cmd+O',
                   command: proc { open_rom_dialog })

      @recent_menu = "#{menubar}.file.recent"
      @app.command(:menu, @recent_menu, tearoff: 0)
      @app.command("#{menubar}.file", :add, :cascade,
                   label: translate('menu.recent'), menu: @recent_menu)
      rebuild_recent_menu

      @app.command("#{menubar}.file", :add, :separator)
      @app.command("#{menubar}.file", :add, :command,
                   label: translate('menu.quit'), accelerator: 'Cmd+Q',
                   command: proc { self.running = false })

      @app.command(:bind, '.', '<Command-o>', proc { handle_open_rom })
      @app.command(:bind, '.', '<Command-comma>', proc { show_settings })

      # Settings menu
      settings_menu = "#{menubar}.settings"
      @app.command(:menu, settings_menu, tearoff: 0)
      @app.command(menubar, :add, :cascade, label: translate('menu.settings'), menu: settings_menu)

      SettingsWindow::TABS.each do |locale_key, tab_path|
        display = translate(locale_key)
        accel = locale_key == 'settings.video' ? 'Cmd+,' : nil
        opts = { label: "#{display}\u2026", command: proc { show_settings(tab: tab_path) } }
        opts[:accelerator] = accel if accel
        @app.command(settings_menu, :add, :command, **opts)
      end

      # View menu
      view_menu = "#{menubar}.view"
      @app.command(:menu, view_menu, tearoff: 0)
      @app.command(menubar, :add, :cascade, label: translate('menu.view'), menu: view_menu)

      @app.command(view_menu, :add, :command,
                   label: translate('menu.game_library'), state: :disabled,
                   command: proc { show_game_library })
      @app.command(view_menu, :add, :command,
                   label: translate('menu.fullscreen'), accelerator: 'F11',
                   command: proc { toggle_fullscreen })
      @app.command(view_menu, :add, :command,
                   label: translate('menu.rom_info'), state: :disabled,
                   command: proc { show_rom_info })
      @app.command(view_menu, :add, :separator)
      @app.command(view_menu, :add, :command,
                   label: translate('menu.open_logs_dir'),
                   command: proc { open_logs_dir })
      @view_menu = view_menu

      # Emulation menu
      @emu_menu = "#{menubar}.emu"
      @app.command(:menu, @emu_menu, tearoff: 0)
      @app.command(menubar, :add, :cascade, label: translate('menu.emulation'), menu: @emu_menu)

      @app.command(@emu_menu, :add, :command,
                   label: translate('menu.pause'), accelerator: 'P',
                   command: proc { frame&.receive(:pause) })
      @app.command(@emu_menu, :add, :command,
                   label: translate('menu.reset'), accelerator: 'Cmd+R',
                   command: proc { reset_core })
      @app.command(@emu_menu, :add, :separator)
      @app.command(@emu_menu, :add, :command,
                   label: translate('menu.quick_save'), accelerator: 'F5', state: :disabled,
                   command: proc { frame&.receive(:quick_save) })
      @app.command(@emu_menu, :add, :command,
                   label: translate('menu.quick_load'), accelerator: 'F8', state: :disabled,
                   command: proc { frame&.receive(:quick_load) })
      @app.command(@emu_menu, :add, :separator)
      @app.command(@emu_menu, :add, :command,
                   label: translate('menu.save_states'), accelerator: 'F6', state: :disabled,
                   command: proc { show_state_picker })
      @app.command(@emu_menu, :add, :separator)
      @app.command(@emu_menu, :add, :command,
                   label: translate('menu.start_recording'), accelerator: 'F10', state: :disabled,
                   command: proc { frame&.receive(:toggle_recording) })
      @app.command(@emu_menu, :add, :command,
                   label: translate('menu.start_input_recording'), accelerator: 'F4', state: :disabled,
                   command: proc { frame&.receive(:toggle_input_recording) })

      @app.command(:bind, '.', '<Command-r>', proc { reset_core })
    end

    def update_recording_menu
      recording = frame&.recording? || false
      label = recording ? translate('menu.stop_recording') : translate('menu.start_recording')
      @app.command(@emu_menu, :entryconfigure, 8, label: label)
    end

    def update_input_recording_menu
      recording = frame&.input_recording? || false
      label = recording ? translate('menu.stop_input_recording') : translate('menu.start_input_recording')
      @app.command(@emu_menu, :entryconfigure, 9, label: label)
    end

    def rebuild_recent_menu
      @app.command(@recent_menu, :delete, 0, :end) rescue nil

      roms = @config.recent_roms
      if roms.empty?
        @app.command(@recent_menu, :add, :command,
                     label: translate('player.none'), state: :disabled)
      else
        roms.each do |rom_path|
          label = File.basename(rom_path)
          @app.command(@recent_menu, :add, :command,
                       label: label,
                       command: proc { open_recent_rom(rom_path) })
        end
        @app.command(@recent_menu, :add, :separator)
        @app.command(@recent_menu, :add, :command,
                     label: translate('player.clear'),
                     command: proc { clear_recent_roms })
      end
    end

    def clear_recent_roms
      @config.clear_recent_roms
      @config.save!
      rebuild_recent_menu
    end

    # ── Modals ─────────────────────────────────────────────────────────

    def show_game_library
      return if @frame_stack.current == :picker
      return bell if @modal_stack.active?

      if frame&.rom_loaded?
        return unless confirm(
          title: translate('dialog.return_to_library_title'),
          message: translate('dialog.return_to_library_msg'),
        )
      end

      @emulator_frame&.running = false
      @emulator_frame&.cleanup
      @frame_stack.pop
      @emulator_frame = nil
      @rom_path = nil
      @window.set_title("gemba")
      @window.set_geometry(GamePickerFrame::PICKER_DEFAULT_W, GamePickerFrame::PICKER_DEFAULT_H)
      @window.set_minsize(GamePickerFrame::PICKER_MIN_W, GamePickerFrame::PICKER_MIN_H)
      apply_frame_aspect(@game_picker)
      @app.command(@view_menu, :entryconfigure, 0, state: :disabled)
      set_event_loop_speed(:idle)
    end

    def show_settings(tab: nil)
      return bell if @modal_stack.active?
      @modal_stack.push(:settings, @settings_window, show_args: { tab: tab })
    end

    def show_state_picker
      return unless frame&.save_mgr&.state_dir
      return bell if @modal_stack.active?
      @modal_stack.push(:picker, @state_picker,
        show_args: { state_dir: frame.save_mgr.state_dir, quick_slot: @config.quick_save_slot })
    end

    def show_rom_info
      return unless frame&.rom_loaded?
      return bell if @modal_stack.active?
      saves = @config.saves_dir
      sav_name = File.basename(@rom_path, File.extname(@rom_path)) + '.sav'
      sav_path = File.join(saves, sav_name)
      @modal_stack.push(:rom_info, @rom_info_window,
        show_args: { core: frame.core, rom_path: @rom_path, save_path: sav_path })
    end

    def show_replay_player
      @replay_player ||= ReplayPlayer.new(
        app: @app,
        sound: true,
        callbacks: {
          on_dismiss: proc { @modal_stack.pop },
          on_request_speed: method(:set_event_loop_speed),
        }
      )
      @modal_stack.push(:replay_player, @replay_player)
    end

    def modal_entered(_name)
      @was_paused_before_modal = frame&.paused? || false
      frame&.receive(:modal_entered)
    end

    def modal_exited
      frame&.receive(:modal_exited, was_paused: @was_paused_before_modal)
    end

    def modal_focus_changed(name)
      locale_key = MODAL_LABELS[name] || name.to_s
      label = translate(locale_key)
      frame&.receive(:modal_focus_changed, message: translate('toast.waiting_for', label: label))
    end

    # ── File handling ──────────────────────────────────────────────────

    def load_rom(path)
      rom_path = begin
        RomResolver.resolve(path)
      rescue RomResolver::NoRomInZip => e
        show_rom_error(translate('dialog.no_rom_in_zip', name: e.message))
        return
      rescue RomResolver::MultipleRomsInZip => e
        show_rom_error(translate('dialog.multiple_roms_in_zip', name: e.message))
        return
      rescue RomResolver::UnsupportedFormat => e
        show_rom_error(translate('dialog.drop_unsupported_type', ext: e.message))
        return
      rescue RomResolver::ZipReadError => e
        show_rom_error(translate('dialog.zip_read_error', detail: e.message))
        return
      end

      # One-time gamepad subsystem init
      unless @gamepad_inited
        @gamepad_inited = true
        Teek::SDL2::Gamepad.init_subsystem
        Teek::SDL2::Gamepad.on_added { |_| refresh_gamepads }
        Teek::SDL2::Gamepad.on_removed { |_| @gamepad = nil; @gp_map.device = nil; refresh_gamepads }
        refresh_gamepads
        start_gamepad_probe
      end

      # Create EmulatorFrame (fresh each time after returning from game library)
      unless @emulator_frame
        @emulator_frame = create_emulator_frame
        @emulator_frame.init_sdl2
        @window.fullscreen = true if @fullscreen
      end

      # Push emulator onto frame stack (hides picker automatically)
      if @frame_stack.current != :emulator
        @frame_stack.push(:emulator, @emulator_frame)
        @window.reset_minsize
        apply_frame_aspect(@emulator_frame)
      end

      saves = @config.saves_dir
      loaded_core = @emulator_frame.load_core(rom_path, saves_dir: saves, rom_source_path: path)
      @rom_path = path

      new_platform = @emulator_frame.platform
      @platform = new_platform
      apply_scale(@scale)
      Gemba.log(:info) { "ROM loaded: #{loaded_core.title} (#{loaded_core.game_code}) [#{@platform.short_name}]" }

      rom_id = Config.rom_id(loaded_core.game_code, loaded_core.checksum)

      emit(:rom_loaded,
        rom_id: rom_id,
        path: path,
        title: loaded_core.title,
        game_code: loaded_core.game_code,
        platform: @platform.short_name,
        saves_dir: saves,
      )

      @emulator_frame.start_animate
    end

    def open_rom_dialog
      filetypes = '{{GBA ROMs} {.gba}} {{GB ROMs} {.gb .gbc}} {{ZIP Archives} {.zip}} {{All Files} {*}}'
      title = translate('menu.open_rom').delete("\u2026")
      initial = @rom_path ? File.dirname(@rom_path) : Dir.home
      path = @app.tcl_eval("tk_getOpenFile -title {#{title}} -filetypes {#{filetypes}} -initialdir {#{initial}}")
      return if path.empty?
      return unless confirm_rom_change(path)
      load_rom(path)
    end

    def handle_open_rom
      if @modal_stack.current == :replay_player
        open_recordings_dir
      else
        open_rom_dialog
      end
    end

    def open_recent_rom(path)
      unless File.exist?(path)
        @app.command('tk_messageBox',
          parent: '.',
          title: translate('dialog.rom_not_found_title'),
          message: translate('dialog.rom_not_found_msg', path: path),
          type: :ok,
          icon: :error)
        @config.remove_recent_rom(path)
        @config.save!
        rebuild_recent_menu
        return
      end
      return unless confirm_rom_change(path)
      load_rom(path)
    end

    def confirm_rom_change(new_path)
      return true unless frame&.rom_loaded?
      name = File.basename(new_path)
      confirm(
        title: translate('dialog.game_running_title'),
        message: translate('dialog.game_running_msg', name: name),
      )
    end

    def setup_drop_target
      @app.register_drop_target('.')
      @app.bind('.', '<<DropFile>>', :data) do |data|
        paths = @app.split_list(data)
        handle_dropped_files(paths)
      end
    end

    def handle_dropped_files(paths)
      if paths.length != 1
        @app.command('tk_messageBox',
          parent: '.',
          title: translate('dialog.drop_error_title'),
          message: translate('dialog.drop_single_file_only'),
          type: :ok,
          icon: :warning)
        return
      end

      path = paths.first
      ext = File.extname(path).downcase
      unless RomResolver::SUPPORTED_EXTENSIONS.include?(ext)
        @app.command('tk_messageBox',
          parent: '.',
          title: translate('dialog.drop_error_title'),
          message: translate('dialog.drop_unsupported_type', ext: ext),
          type: :ok,
          icon: :warning)
        return
      end

      return unless confirm_rom_change(path)
      load_rom(path)
    end

    def reset_core
      return unless @rom_path
      load_rom(@rom_path)
    end

    # ── Config ─────────────────────────────────────────────────────────

    def save_config
      @config.scale = @scale
      frame&.receive(:write_config)
      @kb_map.save_to_config
      @gp_map.save_to_config
      @hotkeys.save_to_config
      @config.save!
    end

    def push_settings_to_ui
      @app.set_variable(SettingsWindow::VAR_SCALE, "#{@config.scale}x")
      turbo_label = @config.turbo_speed == 0 ? 'Uncapped' : "#{@config.turbo_speed}x"
      @app.set_variable(SettingsWindow::VAR_TURBO, turbo_label)
      @app.set_variable(SettingsWindow::VAR_ASPECT_RATIO, @config.keep_aspect_ratio? ? '1' : '0')
      @app.set_variable(SettingsWindow::VAR_SHOW_FPS, @config.show_fps? ? '1' : '0')
      @app.set_variable(SettingsWindow::VAR_TOAST_DURATION, "#{@config.toast_duration}s")
      filter_label = @config.pixel_filter == 'nearest' ? translate('settings.filter_nearest') : translate('settings.filter_linear')
      @app.set_variable(SettingsWindow::VAR_FILTER, filter_label)
      @app.set_variable(SettingsWindow::VAR_INTEGER_SCALE, @config.integer_scale? ? '1' : '0')
      @app.set_variable(SettingsWindow::VAR_COLOR_CORRECTION, @config.color_correction? ? '1' : '0')
      @app.set_variable(SettingsWindow::VAR_FRAME_BLENDING, @config.frame_blending? ? '1' : '0')
      @app.set_variable(SettingsWindow::VAR_REWIND_ENABLED, @config.rewind_enabled? ? '1' : '0')
      @app.set_variable(SettingsWindow::VAR_VOLUME, @config.volume.to_s)
      @app.set_variable(SettingsWindow::VAR_MUTE, @config.muted? ? '1' : '0')
      @app.set_variable(SettingsWindow::VAR_QUICK_SLOT, @config.quick_save_slot.to_s)
      @app.set_variable(SettingsWindow::VAR_SS_BACKUP, @config.save_state_backup? ? '1' : '0')
      @app.set_variable(SettingsWindow::VAR_REC_COMPRESSION, @config.recording_compression.to_s)
      @app.set_variable(SettingsWindow::VAR_PAUSE_FOCUS, @config.pause_on_focus_loss? ? '1' : '0')
    end

    def refresh_from_config
      @scale = @config.scale
      apply_scale(@scale) if frame&.sdl2_ready?
      frame&.receive(:refresh_from_config)
      push_settings_to_ui
    end

    def toggle_per_game(enabled)
      if enabled
        @config.enable_per_game
      else
        @config.disable_per_game
      end
      refresh_from_config
    end

    # ── Window ─────────────────────────────────────────────────────────

    def toggle_fullscreen
      @fullscreen = !@fullscreen
      @window.fullscreen = @fullscreen
    end

    def create_emulator_frame
      EmulatorFrame.new(
        app: @app, config: @config, platform: @platform, sound: @sound,
        scale: @scale, kb_map: @kb_map, gp_map: @gp_map,
        keyboard: @keyboard, hotkeys: @hotkeys,
        frame_limit: @frame_limit,
        volume: @config.volume / 100.0,
        muted: @config.muted?,
        turbo_speed: @config.turbo_speed,
        turbo_volume: @config.turbo_volume_pct / 100.0,
        keep_aspect_ratio: @config.keep_aspect_ratio?,
        show_fps: @config.show_fps?,
        pixel_filter: @config.pixel_filter,
        integer_scale: @config.integer_scale?,
        color_correction: @config.color_correction?,
        frame_blending: @config.frame_blending?,
        rewind_enabled: @config.rewind_enabled?,
        rewind_seconds: @config.rewind_seconds,
        quick_save_slot: @config.quick_save_slot,
        save_state_backup: @config.save_state_backup?,
        recording_compression: @config.recording_compression,
        pause_on_focus_loss: @config.pause_on_focus_loss?,
      )
    end

    def apply_frame_aspect(frame)
      if (ratio = frame.aspect_ratio)
        @window.set_aspect(*ratio)
      else
        @window.reset_aspect_ratio
      end
    end

    def apply_scale(new_scale)
      @scale = new_scale.clamp(1, 4)
      w = @platform.width * @scale
      h = @platform.height * @scale
      @window.set_geometry(w, h)
    end

    def set_event_loop_speed(mode)
      ms = mode == :fast ? EVENT_LOOP_FAST_MS : EVENT_LOOP_IDLE_MS
      @window.set_timer_speed(ms)
    end

    # ── Gamepad ────────────────────────────────────────────────────────

    def start_gamepad_probe
      @app.after(GAMEPAD_PROBE_MS) { gamepad_probe_tick }
    end

    def gamepad_probe_tick
      return unless @running
      has_gp = @gamepad && !@gamepad.closed?
      settings_visible = @app.command(:wm, 'state', SettingsWindow::TOP) != 'withdrawn' rescue false

      if settings_visible && has_gp
        Teek::SDL2::Gamepad.update_state

        if @settings_window.listening_for
          Teek::SDL2::Gamepad.buttons.each do |btn|
            if @gamepad.button?(btn)
              @settings_window.capture_mapping(btn)
              break
            end
          end
        end

        @app.after(GAMEPAD_LISTEN_MS) { gamepad_probe_tick }
        return
      end

      unless frame&.rom_loaded?
        Teek::SDL2::Gamepad.poll_events rescue nil
      end
      @app.after(GAMEPAD_PROBE_MS) { gamepad_probe_tick }
    end

    def refresh_gamepads
      names = [translate('settings.keyboard_only')]
      prev_gp = @gamepad
      8.times do |i|
        gp = begin; Teek::SDL2::Gamepad.open(i); rescue; nil; end
        next unless gp
        names << gp.name
        @gamepad ||= gp
        gp.close unless gp == @gamepad
      end
      @settings_window&.update_gamepad_list(names)
      if @gamepad && @gamepad != prev_gp
        Gemba.log(:info) { "Gamepad detected: #{@gamepad.name}" }
        @gp_map.device = @gamepad
        @gp_map.load_config
      end
    end

    # ── Input maps ─────────────────────────────────────────────────────

    def active_input
      @settings_window.keyboard_mode? ? @kb_map : @gp_map
    end

    def undo_mappings
      input = active_input
      input.reload!
      @settings_window.refresh_gamepad(input.labels, input.dead_zone_pct)
    end

    def undo_hotkeys
      @hotkeys.reload!
      @settings_window.refresh_hotkeys(@hotkeys.labels)
    end

    def validate_hotkey(hotkey)
      return nil if hotkey.is_a?(Array)
      @kb_map.labels.each do |gba_btn, key|
        return "\"#{hotkey}\" is mapped to GBA button #{gba_btn.upcase}" if key == hotkey
      end
      nil
    end

    def validate_kb_mapping(keysym)
      action = @hotkeys.action_for(keysym)
      if action
        label = action.to_s.tr('_', ' ').capitalize
        return "\"#{keysym}\" is assigned to hotkey: #{label}"
      end
      nil
    end

    # ── Global hotkeys (pre-SDL2) ──────────────────────────────────────

    def setup_global_hotkeys
      @app.bind('.', 'KeyPress', :keysym, '%s') do |k, state_str|
        next if frame&.sdl2_ready? || @modal_stack.active?

        if k == 'Escape'
          self.running = false
        else
          mods = HotkeyMap.modifiers_from_state(state_str.to_i)
          case @hotkeys.action_for(k, modifiers: mods)
          when :quit     then self.running = false
          when :open_rom then handle_open_rom
          end
        end
      end
    end

    # ── Helpers ────────────────────────────────────────────────────────

    def bell
      @app.command(:bell)
    end

    def show_rom_error(message)
      @app.command('tk_messageBox',
        parent: '.',
        title: translate('dialog.drop_error_title'),
        message: message,
        type: :ok,
        icon: :error)
    end

    def check_writable_dirs
      dirs = {
        'Config'      => Config.config_dir,
        'Saves'       => @config.saves_dir,
        'Save States' => Config.default_states_dir,
      }

      problems = []
      dirs.each do |label, dir|
        begin
          FileUtils.mkdir_p(dir)
        rescue SystemCallError => e
          problems << "#{label}: #{dir}\n  #{e.message}"
          next
        end
        unless File.writable?(dir)
          problems << "#{label}: #{dir}\n  Not writable"
        end
      end

      return if problems.empty?

      msg = "Cannot write to required directories:\n\n#{problems.join("\n\n")}\n\n" \
            "Check file permissions or set a custom path in config."
      @app.command(:tk_messageBox, icon: :error, type: :ok,
                   title: 'gemba', message: msg)
      @app.destroy('.')
      exit 1
    end

    def open_config_dir
      Gemba.open_directory(Config.config_dir)
    end

    def open_recordings_dir
      Gemba.open_directory(@config.recordings_dir)
    end

    def open_logs_dir
      Gemba.open_directory(Config.default_logs_dir)
    end

    def cleanup
      return if @cleaned_up
      @cleaned_up = true
      @emulator_frame&.cleanup
      @game_picker&.cleanup
      RomResolver.cleanup_temp
    end
  end
end
