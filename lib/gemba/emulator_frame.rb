# frozen_string_literal: true

require 'fileutils'

module Gemba
  # SDL2 emulation frame — owns the mGBA core, viewport, audio stream,
  # frame loop, and all rendering. Designed to be packed/unpacked inside
  # a host window (AppController) so it can coexist with other "frames" like
  # a game picker or replay viewer.
  #
  # Communication:
  #   AppController → EmulatorFrame: @frame.receive(:event_name, **args)
  #   EmulatorFrame → AppController: EventBus events (pause_changed, request_quit, etc.)
  #   Settings → EmulatorFrame: bus events subscribed directly
  class EmulatorFrame
    include Locale::Translatable
    include BusEmitter

    # mGBA outputs at 44100 Hz (stereo int16)
    AUDIO_FREQ         = 44100
    MAX_DELTA          = 0.005   # ±0.5% max adjustment (dynamic rate control)
    FF_MAX_FRAMES      = 10     # cap for uncapped turbo to avoid locking event loop
    FADE_IN_FRAMES     = (AUDIO_FREQ * 0.02).to_i  # ~20ms = 882 samples
    REWIND_PUSH_INTERVAL = 60   # ~1 second at ~60 fps
    FOCUS_POLL_MS      = 200

    # @param app [Teek::App] the Tk application
    # @param config [Config] configuration object
    # @param platform [Platform] initial platform (GBA default)
    # @param sound [Boolean] whether audio is enabled
    # @param scale [Integer] video scale multiplier
    # @param kb_map [KeyboardMap] keyboard input mapping (shared reference)
    # @param gp_map [GamepadMap] gamepad input mapping (shared reference)
    # @param keyboard [VirtualKeyboard] virtual keyboard state (shared reference)
    # @param hotkeys [HotkeyMap] hotkey bindings (shared reference)
    # @param frame_limit [Integer, nil] stop after this many frames (testing)
    def initialize(app:, config:, platform:, sound:, scale:,
                   kb_map:, gp_map:, keyboard:, hotkeys:,
                   frame_limit: nil,
                   volume:, muted:, turbo_speed:, turbo_volume:,
                   keep_aspect_ratio:, show_fps:, pixel_filter:,
                   integer_scale:, color_correction:, frame_blending:,
                   rewind_enabled:, rewind_seconds:,
                   quick_save_slot:, save_state_backup:,
                   recording_compression:, pause_on_focus_loss:)
      @app = app
      @config = config
      @platform = platform
      @sound = sound
      @scale = scale
      @kb_map = kb_map
      @gp_map = gp_map
      @keyboard = keyboard
      @hotkeys = hotkeys
      @frame_limit = frame_limit

      # Emulation config state
      @volume = volume
      @muted = muted
      @turbo_speed = turbo_speed
      @turbo_volume = turbo_volume
      @keep_aspect_ratio = keep_aspect_ratio
      @show_fps = show_fps
      @pixel_filter = pixel_filter
      @integer_scale = integer_scale
      @color_correction = color_correction
      @frame_blending = frame_blending
      @rewind_enabled = rewind_enabled
      @rewind_seconds = rewind_seconds
      @quick_save_slot = quick_save_slot
      @save_state_backup = save_state_backup
      @recording_compression = recording_compression
      @pause_on_focus_loss = pause_on_focus_loss

      setup_bus_subscriptions

      # Runtime state
      @audio_fade_in = 0
      @total_frames = 0
      @fast_forward = false
      @paused = false
      @core = nil
      @sdl2_ready = false
      @animate_started = false
      @running = true
      @cleaned_up = false
      @recorder = nil
      @input_recorder = nil
      @save_mgr = nil
      @rewind_frame_counter = 0
      @achievement_backend = Achievements::NullBackend.new
    end

    # -- Public accessors -------------------------------------------------------

    # @return [Teek::SDL2::Viewport, nil]
    attr_reader :viewport

    # @return [Core, nil]
    attr_reader :core

    # @return [SaveStateManager, nil]
    attr_reader :save_mgr

    # @return [Recorder, nil]
    attr_reader :recorder

    # @return [Platform]
    attr_reader :platform

    # @return [Float] current volume 0.0–1.0
    attr_reader :volume

    # @return [Integer] turbo speed multiplier (0 = uncapped)
    attr_reader :turbo_speed

    # @return [Achievements::Backend]
    attr_reader :achievement_backend

    # Swap in a new achievement backend. Registers callbacks that forward
    # unlock events through EventBus for any UI consumer to handle.
    # @param backend [Achievements::Backend]
    def achievement_backend=(backend)
      @achievement_backend = backend
      backend.on_unlock { |ach| emit(:achievement_unlocked, achievement: ach) }
    end

    # @return [Boolean]
    def muted? = @muted

    # @return [Boolean]
    def aspect_ratio = nil   # emulator drives its own geometry via apply_scale
    def sdl2_ready? = @sdl2_ready

    # @return [Boolean]
    def paused? = @paused

    # @return [Boolean]
    def fast_forward? = @fast_forward

    # @return [Boolean]
    def recording? = @recorder&.recording? || false

    # @return [Boolean]
    def input_recording? = @input_recorder&.recording? || false

    # @return [Boolean]
    def rom_loaded? = !!@core

    # @return [Boolean]
    def show_fps? = @show_fps

    # Allow AppController to control the animate loop
    attr_writer :running

    # Allow AppController to update scale (for screenshots)
    attr_writer :scale

    # FrameStack protocol
    def show
      return unless @sdl2_ready && @viewport
      @app.command(:pack, @viewport.frame.path, fill: :both, expand: 1)
    end

    def hide
      return unless @sdl2_ready && @viewport
      @app.command(:pack, :forget, @viewport.frame.path) rescue nil
    end

    # Single entry point for AppController → EmulatorFrame communication.
    # AppController calls @frame.receive(:event_name, **args) instead of
    # knowing about individual methods.
    def receive(event, **args)
      case event
      when :pause                  then toggle_pause
      when :fast_forward           then toggle_fast_forward
      when :rewind                 then do_rewind
      when :quick_save             then quick_save
      when :quick_load             then quick_load
      when :save_state             then save_state(args[:slot])
      when :load_state             then load_state(args[:slot])
      when :screenshot             then take_screenshot
      when :toggle_recording       then toggle_recording
      when :toggle_input_recording then toggle_input_recording
      when :toggle_show_fps
        @show_fps = !@show_fps
        @hud&.set_fps(nil) unless @show_fps
      when :show_toast
        show_toast(args[:message], permanent: args[:permanent] || false)
      when :dismiss_toast
        dismiss_toast
      when :modal_entered
        toggle_fast_forward if fast_forward?
        toggle_pause if rom_loaded? && !paused?
      when :modal_exited
        dismiss_toast
        toggle_pause if rom_loaded? && !args[:was_paused]
      when :modal_focus_changed
        dismiss_toast
        show_toast(args[:message], permanent: true)
      when :write_config           then write_config
      when :refresh_from_config    then refresh_from_config(@config)
      end
    end

    # -- SDL2 lifecycle ---------------------------------------------------------

    # Create the SDL2 viewport, audio stream, fonts, and input bindings.
    # Must be called once before load_core.
    def init_sdl2
      return if @sdl2_ready

      @app.command('tk', 'busy', '.')

      win_w = @platform.width * @scale
      win_h = @platform.height * @scale

      @viewport = Teek::SDL2::Viewport.new(@app, width: win_w, height: win_h, vsync: false)
      @viewport.pack(fill: :both, expand: true)

      # Streaming texture at native resolution
      @texture = @viewport.renderer.create_texture(@platform.width, @platform.height, :streaming)
      @texture.scale_mode = @pixel_filter.to_sym

      # Font for on-screen indicators (FPS, fast-forward label)
      font_path = File.join(ASSETS_DIR, 'JetBrainsMonoNL-Regular.ttf')
      @overlay_font = File.exist?(font_path) ? @viewport.renderer.load_font(font_path, 14) : nil

      # CJK-capable font for toast notifications and translated UI text
      toast_font_path = File.join(ASSETS_DIR, 'ark-pixel-12px-monospaced-ja.ttf')
      toast_font = File.exist?(toast_font_path) ? @viewport.renderer.load_font(toast_font_path, 12) : @overlay_font

      @toast = ToastOverlay.new(
        renderer: @viewport.renderer,
        font: toast_font || @overlay_font,
        duration: @config.toast_duration
      )

      # Custom blend mode: white text inverts the background behind it.
      inverse_blend = Teek::SDL2.compose_blend_mode(
        :one_minus_dst_color, :one_minus_src_alpha, :add,
        :zero, :one, :add
      )

      @hud = OverlayRenderer.new(font: @overlay_font, blend_mode: inverse_blend)

      # Audio stream — stereo int16.
      if @sound && Teek::SDL2::AudioStream.available?
        @stream = Teek::SDL2::AudioStream.new(
          frequency: AUDIO_FREQ,
          format:    :s16,
          channels:  2
        )
        @stream.resume
      else
        if @sound
          Gemba.log(:warn) { "No audio device found, continuing without sound" }
          warn "gemba: no audio device found, continuing without sound"
        end
        @stream = Teek::SDL2::NullAudioStream.new
      end

      setup_input

      @sdl2_ready = true

      # Unblock interaction now that SDL2 is ready
      @app.command('tk', 'busy', 'forget', '.')

      # Auto-focus viewport for keyboard input
      @app.tcl_eval("focus -force #{@viewport.frame.path}")
      @app.update
    rescue => e
      Gemba.log(:error) { "init_sdl2 failed: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}" }
      $stderr.puts "FATAL: init_sdl2 failed: #{e.class}: #{e.message}"
      $stderr.puts e.backtrace.first(10).map { |l| "  #{l}" }.join("\n")
      @app.command('tk', 'busy', 'forget', '.') rescue nil
      emit(:request_quit)
    end

    # Load (or reload) a ROM core. Creates Core + SaveStateManager.
    # @param rom_path [String] resolved path to the ROM file
    # @param saves_dir [String] directory for .sav files
    # @param bios_path [String, nil] full path to BIOS file (loaded before reset)
    # @param rom_source_path [String] original path (for input recorder)
    # @return [Core] the new core
    def load_core(rom_path, saves_dir:, bios_path: nil, rom_source_path: nil, md5: nil)
      stop_recording if @recorder&.recording?
      stop_input_recording if @input_recorder&.recording?

      if @core && !@core.destroyed?
        @core.destroy
      end
      @stream.clear

      FileUtils.mkdir_p(saves_dir) unless File.directory?(saves_dir)
      @core = Core.new(rom_path, saves_dir, bios_path)
      @rom_source_path = rom_source_path || rom_path
      @rom_md5         = md5

      new_platform = Platform.for(@core)
      if new_platform != @platform
        @platform = new_platform
        recreate_texture
      end

      @save_mgr = SaveStateManager.new(core: @core, config: @config, app: @app, platform: @platform)
      @save_mgr.state_dir = @save_mgr.state_dir_for_rom(@core)
      @save_mgr.quick_save_slot = @quick_save_slot
      @save_mgr.backup = @save_state_backup
      @core.color_correction = @color_correction if @color_correction
      @core.frame_blending = @frame_blending if @frame_blending
      @core.rewind_init(@rewind_seconds) if @rewind_enabled
      @rewind_frame_counter = 0
      @paused = false
      @stream.resume
      set_event_loop_speed(:fast)
      @fps_count = 0
      @fps_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @next_frame = @fps_time
      @audio_samples_produced = 0

      @achievement_backend.load_game(@core, @rom_source_path, @rom_md5)

      @core
    end

    # Start the emulation animate loop. Call once after first load_core.
    def start_animate
      return if @animate_started
      @animate_started = true
      animate
    end

    # -- Toast helpers (called by AppController via receive) ----------------------

    def show_toast(msg, permanent: false)
      @toast&.show(msg, permanent: permanent)
      render_if_paused
    end

    def dismiss_toast
      @toast&.destroy
    end

    # -- Cleanup ----------------------------------------------------------------

    def cleanup
      return if @cleaned_up
      @cleaned_up = true

      stop_recording if @recorder&.recording?
      stop_input_recording if @input_recorder&.recording?
      @stream&.pause unless @stream&.destroyed?
      @hud&.destroy
      @toast&.destroy
      @overlay_font&.destroy unless @overlay_font&.destroyed?
      @stream&.destroy unless @stream&.destroyed?
      @texture&.destroy unless @texture&.destroyed?
      @core&.destroy unless @core&.destroyed?
      if @viewport
        @app.command(:destroy, @viewport.frame.path) rescue nil
        @viewport.destroy rescue nil
      end
      @sdl2_ready = false
      RomResolver.cleanup_temp
    end

    # -- Emulation control ------------------------------------------------------

    def toggle_pause
      return unless @core
      @paused = !@paused
      if @paused
        @stream.clear
        @stream.pause
        @toast&.show(translate('toast.paused'), permanent: true)
        render_frame
        set_event_loop_speed(:idle)
      else
        set_event_loop_speed(:fast)
        @toast&.destroy
        @stream.clear
        @audio_fade_in = FADE_IN_FRAMES
        @stream.resume
        @next_frame = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
      emit(:pause_changed, @paused)
    end

    def toggle_fast_forward
      return unless @core
      @fast_forward = !@fast_forward
      if @fast_forward
        @hud.set_ff_label(ff_label_text)
      else
        @hud.set_ff_label(nil)
        @next_frame = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @stream.clear
      end
    end

    def do_rewind
      return unless @core && !@core.destroyed?
      unless @rewind_enabled
        @toast&.show(translate('toast.no_rewind'))
        render_if_paused
        return
      end
      if @core.rewind_pop == true
        @core.run_frame
        @stream.clear
        @audio_fade_in = FADE_IN_FRAMES
        @rewind_frame_counter = 0
        @toast&.show(translate('toast.rewound'))
        render_frame
      else
        @toast&.show(translate('toast.no_rewind'))
        render_if_paused
      end
    end

    # -- Save states (delegated to SaveStateManager) ----------------------------

    def save_state(slot)
      return unless @save_mgr
      _ok, msg = @save_mgr.save_state(slot)
      @toast&.show(msg) if msg
    end

    def load_state(slot)
      return unless @save_mgr
      ok, msg = @save_mgr.load_state(slot)
      @toast&.show(msg) if msg
      # After a save state loads, memory jumps abruptly to whatever it was when
      # the state was saved.  Achievements that were already in stage 3 (active)
      # would fire immediately if the saved memory happens to satisfy their
      # conditions.  Reset all achievements back through the priming/waiting
      # startup sequence — same as what rcheevos does on state load.
      if ok
        Gemba.log(:info) { "save state loaded (slot #{slot}) — resetting achievement runtime" }
        @achievement_backend.reset_runtime
        render_clean_if_paused
      end
    end

    def quick_save
      return unless @save_mgr
      _ok, msg = @save_mgr.quick_save
      @toast&.show(msg) if msg
    end

    def quick_load
      return unless @save_mgr
      ok, msg = @save_mgr.quick_load
      @toast&.show(msg) if msg
      # Same as load_state — memory jumped, reset achievement runtime.
      if ok
        Gemba.log(:info) { "quick save state loaded — resetting achievement runtime" }
        @achievement_backend.reset_runtime
        render_clean_if_paused
      end
    end

    # -- Screenshot -------------------------------------------------------------

    def take_screenshot
      return unless @core && !@core.destroyed?

      dir = Config.default_screenshots_dir
      FileUtils.mkdir_p(dir)

      title = @core.title.strip.gsub(/[^a-zA-Z0-9_\-]/, '_')
      stamp = Time.now.strftime('%Y%m%d_%H%M%S')
      name = "#{title}_#{stamp}.png"
      path = File.join(dir, name)

      pixels = @core.video_buffer_argb
      photo_name = "__gemba_ss_#{object_id}"
      out_w = @platform.width * @scale
      out_h = @platform.height * @scale
      @app.command(:image, :create, :photo, photo_name,
                   width: out_w, height: out_h)
      @app.interp.photo_put_zoomed_block(photo_name, pixels, @platform.width, @platform.height,
                                         zoom_x: @scale, zoom_y: @scale, format: :argb)
      @app.command(photo_name, :write, path, format: :png)
      @app.command(:image, :delete, photo_name)
      @toast&.show(translate('toast.screenshot_saved', name: name))
    rescue StandardError => e
      warn "gemba: screenshot failed: #{e.message} (#{e.class})"
      @app.command(:image, :delete, photo_name) rescue nil
      @toast&.show(translate('toast.screenshot_failed'))
    end

    # -- Recording --------------------------------------------------------------

    def toggle_recording
      return unless @core
      @recorder&.recording? ? stop_recording : start_recording
    end

    def start_recording
      dir = @config.recordings_dir
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S_%L')
      title = @core.title.strip.gsub(/[^a-zA-Z0-9_.-]/, '_')
      filename = "#{title}_#{timestamp}.grec"
      path = File.join(dir, filename)
      @recorder = Recorder.new(path, width: @platform.width, height: @platform.height,
                               fps_fraction: @platform.fps_fraction,
                               compression: @recording_compression)
      @recorder.start
      Gemba.log(:info) { "Recording started: #{path}" }
      @toast&.show(translate('toast.recording_started'))
      emit(:recording_changed)
    end

    def stop_recording
      return unless @recorder&.recording?
      @recorder.stop
      count = @recorder.frame_count
      Gemba.log(:info) { "Recording stopped: #{count} frames" }
      @toast&.show(translate('toast.recording_stopped', frames: count))
      @recorder = nil
      emit(:recording_changed)
    end

    # -- Input recording --------------------------------------------------------

    def toggle_input_recording
      return unless @core
      @input_recorder&.recording? ? stop_input_recording : start_input_recording
    end

    def start_input_recording
      dir = @config.recordings_dir
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S_%L')
      title = @core.title.strip.gsub(/[^a-zA-Z0-9_.-]/, '_')
      filename = "#{title}_#{timestamp}.gir"
      path = File.join(dir, filename)
      @input_recorder = InputRecorder.new(path, core: @core, rom_path: @rom_source_path)
      @input_recorder.start
      @toast&.show(translate('toast.input_recording_started'))
      emit(:input_recording_changed)
    end

    def stop_input_recording
      return unless @input_recorder&.recording?
      @input_recorder.stop
      count = @input_recorder.frame_count
      @toast&.show(translate('toast.input_recording_stopped', frames: count))
      @input_recorder = nil
      emit(:input_recording_changed)
    end

    # -- Config appliers --------------------------------------------------------

    def apply_volume(vol)
      @volume = vol.to_f.clamp(0.0, 1.0)
    end

    def apply_mute(muted)
      @muted = !!muted
    end

    def apply_turbo_speed(speed)
      @turbo_speed = speed
      @hud.set_ff_label(ff_label_text) if @fast_forward
    end

    def apply_aspect_ratio(keep)
      @keep_aspect_ratio = keep
    end

    def apply_show_fps(show)
      @show_fps = show
      @hud.set_fps(nil) unless @show_fps
    end

    def apply_toast_duration(secs)
      @config.toast_duration = secs
      @toast.duration = secs
    end

    def apply_pixel_filter(filter)
      @pixel_filter = filter
      @texture.scale_mode = filter.to_sym if @texture
    end

    def apply_integer_scale(enabled)
      @integer_scale = !!enabled
    end

    def apply_color_correction(enabled)
      @color_correction = !!enabled
      if @core && !@core.destroyed?
        @core.color_correction = @color_correction
        render_if_paused
      end
    end

    def apply_frame_blending(enabled)
      @frame_blending = !!enabled
      if @core && !@core.destroyed?
        @core.frame_blending = @frame_blending
        render_if_paused
      end
    end

    def apply_rewind_toggle(enabled)
      @rewind_enabled = !!enabled
      if @core && !@core.destroyed?
        if @rewind_enabled
          @core.rewind_init(@rewind_seconds)
          @rewind_frame_counter = 0
        else
          @core.rewind_deinit
        end
      end
    end

    def apply_recording_compression(val)
      @recording_compression = val.to_i.clamp(1, 9)
    end

    def apply_pause_on_focus_loss(val)
      @pause_on_focus_loss = val
      @was_paused_before_focus_loss = false unless val
    end

    def apply_quick_slot(slot)
      @quick_save_slot = slot.to_i.clamp(1, 10)
      @save_mgr.quick_save_slot = @quick_save_slot if @save_mgr
    end

    def apply_backup(enabled)
      @save_state_backup = !!enabled
      @save_mgr.backup = @save_state_backup if @save_mgr
    end

    # Sync all config-derived state from a config object after per-game switch.
    def refresh_from_config(config)
      @pixel_filter     = config.pixel_filter
      @integer_scale    = config.integer_scale?
      @color_correction = config.color_correction?
      @frame_blending   = config.frame_blending?
      @rewind_enabled   = config.rewind_enabled?
      @rewind_seconds   = config.rewind_seconds
      @quick_save_slot  = config.quick_save_slot
      @save_state_backup = config.save_state_backup?
      @recording_compression = config.recording_compression
      @volume           = config.volume / 100.0
      @muted            = config.muted?
      @turbo_speed      = config.turbo_speed

      @texture.scale_mode = @pixel_filter.to_sym if @texture
      if @core && !@core.destroyed?
        @core.color_correction = @color_correction
        @core.frame_blending = @frame_blending
        render_if_paused
      end
      @save_mgr.quick_save_slot = @quick_save_slot if @save_mgr
      @save_mgr.backup = @save_state_backup if @save_mgr
    end

    # Write all config-derived state back to the config object.
    # Called by AppController before config.save!
    def write_config
      @config.volume = (@volume * 100).round
      @config.muted = @muted
      @config.turbo_speed = @turbo_speed
      @config.keep_aspect_ratio = @keep_aspect_ratio
      @config.show_fps = @show_fps
      @config.pixel_filter = @pixel_filter
      @config.integer_scale = @integer_scale
      @config.color_correction = @color_correction
      @config.frame_blending = @frame_blending
      @config.rewind_enabled = @rewind_enabled
      @config.rewind_seconds = @rewind_seconds
      @config.quick_save_slot = @quick_save_slot
      @config.save_state_backup = @save_state_backup
      @config.recording_compression = @recording_compression
      @config.pause_on_focus_loss = @pause_on_focus_loss
    end

    # -- Class methods ----------------------------------------------------------

    # Apply a linear fade-in ramp to int16 stereo PCM data.
    # Pure function: takes remaining/total counters, returns [pcm, new_remaining].
    # @param pcm [String] packed int16 stereo PCM
    # @param remaining [Integer] fade samples remaining (counts down to 0)
    # @param total [Integer] total fade length in samples
    # @return [Array(String, Integer)] modified PCM and updated remaining count
    def self.apply_fade_ramp(pcm, remaining, total)
      samples = pcm.unpack('s*')
      i = 0
      while i < samples.length && remaining > 0
        gain = 1.0 - (remaining.to_f / total)
        samples[i]     = (samples[i]     * gain).round.clamp(-32768, 32767)
        samples[i + 1] = (samples[i + 1] * gain).round.clamp(-32768, 32767) if i + 1 < samples.length
        remaining -= 1
        i += 2
      end
      [samples.pack('s*'), remaining]
    end

    private

    def setup_bus_subscriptions
      bus = Gemba.bus

      # Video/rendering
      bus.on(:filter_changed)            { |val| apply_pixel_filter(val) }
      bus.on(:integer_scale_changed)     { |val| apply_integer_scale(val) }
      bus.on(:color_correction_changed)  { |val| apply_color_correction(val) }
      bus.on(:frame_blending_changed)    { |val| apply_frame_blending(val) }
      bus.on(:aspect_ratio_changed)      { |val| apply_aspect_ratio(val) }
      bus.on(:show_fps_changed)          { |val| apply_show_fps(val) }
      bus.on(:toast_duration_changed)    { |val| apply_toast_duration(val) }
      bus.on(:turbo_speed_changed)       { |val| apply_turbo_speed(val) }
      bus.on(:rewind_toggled)            { |val| apply_rewind_toggle(val) }
      bus.on(:pause_on_focus_loss_changed) { |val| apply_pause_on_focus_loss(val) }

      # Audio
      bus.on(:volume_changed) { |vol| apply_volume(vol) }
      bus.on(:mute_changed)   { |val| apply_mute(val) }

      # Recording / save states
      bus.on(:compression_changed)     { |val| apply_recording_compression(val) }
      bus.on(:quick_slot_changed)      { |val| apply_quick_slot(val) }
      bus.on(:backup_changed)          { |val| apply_backup(val) }

      # Save state picker events
      bus.on(:state_save_requested) { |slot| save_state(slot) }
      bus.on(:state_load_requested) { |slot| load_state(slot) }
    end

    # -- Frame loop -------------------------------------------------------------

    def animate
      return unless @running
      tick
      delay = (@core && !@paused) ? 1 : 100
      @app.after(delay) { animate }
    end

    def tick
      unless @core
        @viewport.render { |r| r.clear(0, 0, 0) }
        return
      end

      return if @paused

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @next_frame ||= now

      if @fast_forward
        tick_fast_forward(now)
      else
        tick_normal(now)
      end
    end

    def tick_normal(now)
      frames = 0
      while @next_frame <= now && frames < 4
        run_one_frame
        rec_pcm = capture_frame
        queue_audio(raw_pcm: rec_pcm)

        fill = (@stream.queued_samples.to_f / audio_buf_capacity).clamp(0.0, 1.0)
        ratio = (1.0 - MAX_DELTA) + 2.0 * fill * MAX_DELTA
        @next_frame += frame_period * ratio
        frames += 1
      end

      @next_frame = now if now - @next_frame > 0.1
      return if frames == 0

      render_frame
      update_fps(frames, now)
    end

    def tick_fast_forward(now)
      if @turbo_speed == 0
        keys = poll_input
        FF_MAX_FRAMES.times do |i|
          @core.set_keys(keys)
          @core.run_frame
          rec_pcm = capture_frame
          if i == 0
            queue_audio(volume_override: @turbo_volume, raw_pcm: rec_pcm)
          elsif !rec_pcm
            @core.audio_buffer
          end
        end
        @next_frame = now
        render_frame(ff_indicator: true)
        update_fps(FF_MAX_FRAMES, now)
        return
      end

      frames = 0
      while @next_frame <= now && frames < @turbo_speed * 4
        @turbo_speed.times do
          run_one_frame
          rec_pcm = capture_frame
          if frames == 0
            queue_audio(volume_override: @turbo_volume, raw_pcm: rec_pcm)
          elsif !rec_pcm
            @core.audio_buffer
          end
          frames += 1
        end
        @next_frame += frame_period
      end
      @next_frame = now if now - @next_frame > 0.1
      return if frames == 0

      render_frame(ff_indicator: true)
      update_fps(frames, now)
    end

    def run_one_frame
      mask = poll_input
      @input_recorder&.capture(mask) if @input_recorder&.recording?
      @core.set_keys(mask)
      @core.run_frame
      @total_frames += 1
      @running = false if @frame_limit && @total_frames >= @frame_limit
      if @rewind_enabled
        @rewind_frame_counter += 1
        if @rewind_frame_counter >= REWIND_PUSH_INTERVAL
          @core.rewind_push
          @rewind_frame_counter = 0
        end
      end
      @achievement_backend.do_frame(@core)
    end

    # -- Input ------------------------------------------------------------------

    def setup_input
      @viewport.bind('KeyPress', :keysym, '%s') do |k, state_str|
        if k == 'Escape'
          emit(:request_escape)
        else
          mods = HotkeyMap.modifiers_from_state(state_str.to_i)
          case @hotkeys.action_for(k, modifiers: mods)
          when :quit          then @app.command(:event, 'generate', '.', '<<Quit>>')
          when :pause         then toggle_pause
          when :fast_forward  then toggle_fast_forward
          when :fullscreen    then emit(:request_fullscreen)
          when :show_fps      then emit(:request_show_fps_toggle)
          when :quick_save    then @app.command(:event, 'generate', '.', '<<QuickSave>>')
          when :quick_load    then @app.command(:event, 'generate', '.', '<<QuickLoad>>')
          when :save_states   then emit(:request_save_states)
          when :screenshot    then take_screenshot
          when :rewind        then do_rewind
          when :record        then @app.command(:event, 'generate', '.', '<<RecordToggle>>')
          when :input_record  then toggle_input_recording
          when :open_rom      then emit(:request_open_rom)
          else @keyboard.press(k)
          end
        end
      end

      @viewport.bind('KeyRelease', :keysym) do |k|
        @keyboard.release(k)
      end

      @viewport.bind('FocusIn')  { @has_focus = true }
      @viewport.bind('FocusOut') { @has_focus = false }

      start_focus_poll

      # Virtual event bindings — bound on '.' so tests can trigger them directly
      # without needing widget focus. Physical key handlers above translate to
      # these virtual events so the action logic lives in one place.
      @app.command(:bind, '.', '<<Quit>>',         proc { emit(:request_quit) })
      @app.command(:bind, '.', '<<QuickSave>>',    proc { quick_save })
      @app.command(:bind, '.', '<<QuickLoad>>',    proc { quick_load })
      @app.command(:bind, '.', '<<RecordToggle>>', proc { toggle_recording })

      # Alt+Return fullscreen toggle (emulator convention)
      @app.command(:bind, @viewport.frame.path, '<Alt-Return>', proc { emit(:request_fullscreen) })
    end

    # Read keyboard + gamepad state, return combined bitmask.
    def poll_input
      begin
        Teek::SDL2::Gamepad.update_state
      rescue StandardError
        @gp_map.device = nil
      end
      @kb_map.mask | @gp_map.mask
    end

    # -- Rendering --------------------------------------------------------------

    def render_frame(ff_indicator: false)
      pixels = @core.video_buffer_argb
      @texture.update(pixels)
      dest = compute_dest_rect
      @viewport.render do |r|
        r.clear(0, 0, 0)
        r.copy(@texture, nil, dest)
        if @recorder&.recording? || @input_recorder&.recording?
          bx = (dest ? dest[0] : 0) + 12
          by = (dest ? dest[1] : 0) + 12
          if @recorder&.recording?
            draw_filled_circle(r, bx, by, 5, 220, 30, 30, 200)
            bx += 14
          end
          if @input_recorder&.recording?
            draw_filled_circle(r, bx, by, 5, 30, 180, 30, 200)
          end
        end
        @hud.draw(r, dest, show_fps: @show_fps, show_ff: ff_indicator)
        @toast&.draw(r, dest)
      end
    end

    def render_if_paused
      render_frame if @paused && @core && @texture
    end

    # Like render_if_paused but suppresses frame blending for one frame.
    # Used after state loads: mGBA's previous-frame buffer is stale, so blending
    # would show a mix of the pre-load frame and the saved state frame.
    def render_clean_if_paused
      return unless @paused && @core && @texture
      @core.frame_blending = false if @frame_blending
      render_frame
      @core.frame_blending = true if @frame_blending
    end

    def compute_dest_rect
      return nil unless @keep_aspect_ratio

      out_w, out_h = @viewport.renderer.output_size
      scale_x = out_w.to_f / @platform.width
      scale_y = out_h.to_f / @platform.height
      scale = [scale_x, scale_y].min
      scale = scale.floor if @integer_scale && scale >= 1.0

      dest_w = (@platform.width * scale).to_i
      dest_h = (@platform.height * scale).to_i
      dest_x = (out_w - dest_w) / 2
      dest_y = (out_h - dest_h) / 2

      [dest_x, dest_y, dest_w, dest_h]
    end

    def draw_filled_circle(renderer, cx, cy, radius, r, g, b, a)
      r2 = radius * radius
      (-radius..radius).each do |dy|
        dx = Math.sqrt(r2 - dy * dy).to_i
        renderer.fill_rect(cx - dx, cy + dy, dx * 2 + 1, 1, r, g, b, a)
      end
    end

    def update_fps(frames, now)
      @fps_count += frames
      elapsed = now - @fps_time
      if elapsed >= 1.0
        fps = (@fps_count / elapsed).round(1)
        @hud.set_fps(translate('player.fps', fps: fps)) if @show_fps
        @audio_samples_produced = 0
        @fps_count = 0
        @fps_time = now
      end
    end

    # -- Audio ------------------------------------------------------------------

    def queue_audio(volume_override: nil, raw_pcm: nil)
      pcm = raw_pcm || @core.audio_buffer
      return if pcm.empty?

      @audio_samples_produced += pcm.bytesize / 4
      if @muted
        @audio_fade_in = 0
      else
        vol = volume_override || @volume
        pcm = apply_volume_to_pcm(pcm, vol) if vol < 1.0
        if @audio_fade_in > 0
          pcm, @audio_fade_in = self.class.apply_fade_ramp(pcm, @audio_fade_in, FADE_IN_FRAMES)
        end
        @stream.queue(pcm)
      end
    end

    def apply_volume_to_pcm(pcm, gain = @volume)
      samples = pcm.unpack('s*')
      samples.map! { |s| (s * gain).round.clamp(-32768, 32767) }
      samples.pack('s*')
    end

    # Capture current frame for recording.
    def capture_frame
      return nil unless @recorder&.recording?
      pcm = @core.audio_buffer
      @recorder.capture(@core.video_buffer_argb, pcm)
      pcm
    end

    # -- Focus polling ----------------------------------------------------------

    def start_focus_poll
      @had_focus = @viewport.renderer.input_focus?
      @app.after(FOCUS_POLL_MS) { focus_poll_tick }
    end

    def focus_poll_tick
      return unless @running

      has_focus = @viewport.renderer.input_focus?

      if @had_focus && !has_focus
        if @pause_on_focus_loss && @core && !@paused
          @was_paused_before_focus_loss = true
          toggle_pause
        end
      elsif !@had_focus && has_focus
        if @was_paused_before_focus_loss && @paused
          @was_paused_before_focus_loss = false
          toggle_pause
        end
      end

      @had_focus = has_focus
      @app.after(FOCUS_POLL_MS) { focus_poll_tick }
    rescue StandardError
      nil
    end

    # -- Helpers ----------------------------------------------------------------

    def frame_period = 1.0 / @platform.fps
    def audio_buf_capacity = (AUDIO_FREQ / @platform.fps * 6).to_i

    def recreate_texture
      @texture&.destroy
      @texture = @viewport.renderer.create_texture(@platform.width, @platform.height, :streaming)
      @texture.scale_mode = @pixel_filter.to_sym
    end

    def ff_label_text
      @turbo_speed == 0 ? translate('player.ff_max') : translate('player.ff', speed: @turbo_speed)
    end

    def set_event_loop_speed(mode)
      ms = mode == :fast ? 1 : 50
      @app.interp.thread_timer_ms = ms
    end
  end
end
