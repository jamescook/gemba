# frozen_string_literal: true

require 'fileutils'
require_relative 'locale'
require_relative 'platform'

module Gemba
  # Non-interactive GBA replay viewer with SDL2 video/audio.
  #
  # Opens a window to play back a .gir input recording with full audio and
  # video rendering. No game input is accepted — the bitmasks come from the
  # .gir file. Supports pause, fast-forward, fullscreen, and screenshot
  # hotkeys. Pauses on the last frame when the replay ends.
  #
  # @example
  #   Gemba::ReplayPlayer.new("session.gir").run
  class ReplayPlayer
    include Gemba
    include Locale::Translatable

    DEFAULT_SCALE = 3

    AUDIO_FREQ     = 44100
    MAX_DELTA      = 0.005
    FF_MAX_FRAMES      = 10
    FADE_IN_FRAMES     = (AUDIO_FREQ * 0.02).to_i
    EVENT_LOOP_FAST_MS = 1
    EVENT_LOOP_IDLE_MS = 50

    attr_reader :app, :viewport
    attr_writer :running

    # @return [Boolean] true once the core is loaded and ready
    def ready? = !!@core

    # @return [Boolean] true when paused
    def paused? = @paused

    # @return [Boolean] true when replay has finished all frames
    def replay_ended? = @replay_ended

    # @return [Integer] current frame index during replay
    def frame_index = @frame_index || 0

    # Pause the replay (no-op if already paused).
    def pause
      toggle_pause unless @paused
    end

    # Resume the replay (no-op if not paused).
    def resume
      toggle_pause if @paused
    end

    def initialize(gir_path = nil, sound: true, fullscreen: false, app: nil, callbacks: {})
      @gir_path = gir_path
      @sound = sound
      @fullscreen = fullscreen
      @running = true
      @paused = false
      @fast_forward = false
      @replay_ended = false
      @cleaned_up = false
      @sdl2_ready = false
      @audio_fade_in = 0
      @fps_count = 0
      @fps_time = 0.0

      @config = Gemba.user_config
      @scale  = @config.scale
      @volume = @config.volume / 100.0
      @muted  = @config.muted?
      @turbo_speed  = @config.turbo_speed
      @turbo_volume = @config.turbo_volume_pct / 100.0
      @keep_aspect_ratio = @config.keep_aspect_ratio?
      @show_fps      = @config.show_fps?
      @pixel_filter  = @config.pixel_filter
      @integer_scale = @config.integer_scale?
      @hotkeys = HotkeyMap.new(@config)
      @platform = Platform.default

      if app
        # Child mode: use parent's app, build in a Toplevel
        @app = app
        @standalone = false
        @callbacks = callbacks
        @top = '.replay_player'
        build_child_toplevel
      else
        # Standalone mode: own App (current behavior)
        @app = Teek::App.new
        @app.interp.thread_timer_ms = EVENT_LOOP_IDLE_MS
        @app.show
        @standalone = true
        @callbacks = {}
        @top = '.'

        win_w = @platform.width * @scale
        win_h = @platform.height * @scale
        @app.set_window_title("[REPLAY]")
        @app.set_window_geometry("#{win_w}x#{win_h}")

        build_menu
      end
    end

    def run
      @app.after(1) { load_replay(@gir_path) }
      @app.mainloop
    ensure
      cleanup
    end

    # Show the child window (child mode only).
    def show
      return if @standalone

      @app.command(:wm, 'deiconify', @top)
      @app.command(:raise, @top)
      start_replay_or_idle
    end

    # Hide the child window (child mode only).
    def hide
      return if @standalone

      cleanup_replay
      @app.command(:wm, 'withdraw', @top)
      @callbacks[:on_close]&.call
    end

    # ModalStack protocol
    def show_modal(**)
      return if @standalone

      @app.command(:wm, 'deiconify', @top)
      @app.command(:raise, @top)
      start_replay_or_idle
    end

    def withdraw
      return if @standalone

      cleanup_replay
      @app.command(:wm, 'withdraw', @top)
    end

    private

    def frame_period = 1.0 / @platform.fps
    def audio_buf_capacity = (AUDIO_FREQ / @platform.fps * 6).to_i

    def recreate_texture
      @texture&.destroy
      @texture = @viewport.renderer.create_texture(@platform.width, @platform.height, :streaming)
      @texture.scale_mode = @pixel_filter.to_sym
    end

    def start_replay_or_idle
      if @gir_path && !@animate_started
        load_replay(@gir_path)
      elsif !@gir_path && !@animate_started
        init_sdl2 unless @sdl2_ready
        animate
        @animate_started = true
      end
    end

    # ── Child window setup ──────────────────────────────────────────

    def build_child_toplevel
      @app.command(:toplevel, @top)
      @app.command(:wm, 'title', @top, translate('replay.replay_player'))
      win_w = @platform.width * @scale
      win_h = @platform.height * @scale
      @app.command(:wm, 'geometry', @top, "#{win_w}x#{win_h}")
      @app.command(:wm, 'transient', @top, '.')
      on_close = @callbacks[:on_dismiss] || proc { hide }
      @app.command(:wm, 'protocol', @top, 'WM_DELETE_WINDOW', on_close)
      build_menu
      @app.command(:wm, 'withdraw', @top)
    end

    # Stop core and audio without destroying the viewport (child mode).
    def cleanup_replay
      @stream&.pause unless @stream&.destroyed?
      @stream&.clear unless @stream&.destroyed?
      @core&.destroy unless @core&.destroyed?
      @core = nil
      @replay_ended = false
      @paused = false
      @animate_started = false
      @running = true
    end

    # ── Load / switch replay ──────────────────────────────────────────

    def load_replay(gir_path)
      init_sdl2 unless @sdl2_ready

      @replayer = InputReplayer.new(gir_path)

      rom_path = @replayer.rom_path
      unless rom_path && File.exist?(rom_path)
        show_error("ROM not found",
          "The ROM referenced by this .gir no longer exists:\n#{rom_path || '(none)'}")
        return
      end

      @core&.destroy unless @core&.destroyed?
      @core = Core.new(rom_path, @config.saves_dir)
      new_platform = Platform.for(@core)
      if new_platform != @platform
        @platform = new_platform
        recreate_texture
      end
      @replayer.validate!(@core)
      @core.load_state_from_file(@replayer.anchor_state_path)

      @frame_index = 0
      @total_frames = @replayer.frame_count
      @replay_ended = false
      @paused = false
      @fast_forward = false
      @hud.set_ff_label(nil)

      Gemba.log(:info) { "Replay started: #{gir_path} (#{@total_frames} frames)" }
      if @standalone
        @app.set_window_title("[REPLAY] #{@core.title}")
      else
        @app.command(:wm, 'title', @top, "[REPLAY] #{@core.title}")
      end
      @stream.clear unless @stream.destroyed?
      @stream.resume unless @stream.destroyed?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @next_frame = now
      @fps_count = 0
      @fps_time = now

      set_event_loop_speed(:fast)
      animate unless @animate_started
      @animate_started = true
    rescue InputReplayer::ChecksumMismatch => e
      show_error("Checksum Mismatch", e.message)
    rescue => e
      show_error("Replay Error", "#{e.class}: #{e.message}")
    end

    def switch_replay(gir_path)
      @gir_path = gir_path
      load_replay(gir_path)
    end

    # ── SDL2 init ────────────────────────────────────────────────────

    def init_sdl2
      return if @sdl2_ready

      @app.command('tk', 'busy', @top)

      win_w = @platform.width * @scale
      win_h = @platform.height * @scale

      @top_frame = child_path('replay_frame') unless @standalone
      if @top_frame
        @app.command('ttk::frame', @top_frame)
        @app.command(:pack, @top_frame, fill: :both, expand: true, in: @top)
      end

      parent_opts = @top_frame ? { parent: @top_frame } : {}
      @viewport = Teek::SDL2::Viewport.new(@app, width: win_w, height: win_h, vsync: false, **parent_opts)
      @viewport.pack(fill: :both, expand: true)

      @texture = @viewport.renderer.create_texture(@platform.width, @platform.height, :streaming)
      @texture.scale_mode = @pixel_filter.to_sym

      font_path = File.join(ASSETS_DIR, 'JetBrainsMonoNL-Regular.ttf')
      @overlay_font = File.exist?(font_path) ? @viewport.renderer.load_font(font_path, 14) : nil

      toast_font_path = File.join(ASSETS_DIR, 'ark-pixel-12px-monospaced-ja.ttf')
      toast_font = File.exist?(toast_font_path) ? @viewport.renderer.load_font(toast_font_path, 12) : @overlay_font

      @toast = ToastOverlay.new(
        renderer: @viewport.renderer,
        font: toast_font || @overlay_font,
        duration: @config.toast_duration
      )

      inverse_blend = Teek::SDL2.compose_blend_mode(
        :one_minus_dst_color, :one_minus_src_alpha, :add,
        :zero, :one, :add
      )
      @hud = OverlayRenderer.new(font: @overlay_font, blend_mode: inverse_blend)

      if @sound && Teek::SDL2::AudioStream.available?
        @stream = Teek::SDL2::AudioStream.new(
          frequency: AUDIO_FREQ,
          format:    :s16,
          channels:  2
        )
      else
        @stream = Teek::SDL2::NullAudioStream.new
      end

      setup_input

      @app.command(:wm, 'attributes', @top, '-fullscreen', 1) if @fullscreen
      @sdl2_ready = true

      @app.command('tk', 'busy', 'forget', @top)
      @app.tcl_eval("focus -force #{@viewport.frame.path}")
      @app.update
    rescue => e
      Gemba.log(:error) { "init_sdl2 failed: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}" }
      $stderr.puts "FATAL: init_sdl2 failed: #{e.class}: #{e.message}"
      $stderr.puts e.backtrace.first(10).map { |l| "  #{l}" }.join("\n")
      @app.command('tk', 'busy', 'forget', @top) rescue nil
      @running = false
    end

    # ── Input (hotkey-only, no game buttons) ──────────────────────────

    def setup_input
      @viewport.bind('KeyPress', :keysym, '%s') do |k, state_str|
        if k == 'Escape'
          if @fullscreen
            toggle_fullscreen
          elsif @standalone
            @running = false
          else
            hide
          end
        else
          mods = HotkeyMap.modifiers_from_state(state_str.to_i)
          case @hotkeys.action_for(k, modifiers: mods)
          when :quit         then @standalone ? (@running = false) : hide
          when :pause        then toggle_pause
          when :fast_forward then toggle_fast_forward
          when :fullscreen   then toggle_fullscreen
          when :screenshot   then take_screenshot
          when :show_fps     then toggle_show_fps
          end
        end
      end

      @app.command(:bind, @viewport.frame.path, '<Alt-Return>', proc { toggle_fullscreen })
    end

    # ── Menu (minimal) ────────────────────────────────────────────────

    # Build a Tk child widget path under @top.
    # Tk root '.' uses '.child', Toplevels use '.top.child'.
    def child_path(name)
      @top == '.' ? ".#{name}" : "#{@top}.#{name}"
    end

    def build_menu
      menubar = child_path('menubar')
      @app.command(:menu, menubar)
      @app.command(@top, :configure, menu: menubar)

      @app.command(:menu, "#{menubar}.file", tearoff: 0)
      @app.command(menubar, :add, :cascade, label: translate('menu.file'), menu: "#{menubar}.file")

      @app.command("#{menubar}.file", :add, :command,
                   label: translate('replay.open_recording'),
                   accelerator: 'Cmd+O',
                   command: proc { open_replay_dialog })
      @app.command("#{menubar}.file", :add, :separator)
      @app.command("#{menubar}.file", :add, :command,
                   label: translate('menu.quit'),
                   accelerator: 'Cmd+Q',
                   command: proc { @running = false })

      @app.command(:bind, @top, '<Command-o>', proc { open_replay_dialog })
    end

    def open_replay_dialog
      filetypes = '{{Input Recordings} {.gir}} {{All Files} {*}}'
      title = translate('replay.open_recording').delete("\u2026")
      initial_dir = @config.recordings_dir
      cmd = "tk_getOpenFile -title {#{title}} -filetypes {#{filetypes}}"
      cmd << " -initialdir {#{initial_dir}}" if initial_dir && File.directory?(initial_dir)
      path = @app.tcl_eval(cmd)
      return if path.empty?

      switch_replay(path)
    end

    # ── Frame loop ────────────────────────────────────────────────────

    def animate
      if @running
        tick
        delay = (@core && !@paused) ? 1 : 100
        @app.after(delay) { animate }
      else
        if @standalone
          cleanup
          @app.command(:destroy, '.')
        else
          hide
        end
      end
    end

    def tick
      unless @core
        render_empty_hint if @sdl2_ready
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
        break if @replay_ended

        run_one_frame
        queue_audio

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
        FF_MAX_FRAMES.times do |i|
          break if @replay_ended
          run_one_frame
          if i == 0
            queue_audio(volume_override: @turbo_volume)
          else
            @core.audio_buffer # discard
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
          break if @replay_ended
          run_one_frame
          if frames == 0
            queue_audio(volume_override: @turbo_volume)
          else
            @core.audio_buffer # discard
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
      if @frame_index < @total_frames
        mask = @replayer.bitmask_at(@frame_index)
        @core.set_keys(mask)
        @core.run_frame
        @frame_index += 1
      else
        on_replay_end unless @replay_ended
      end
    end

    def on_replay_end
      @replay_ended = true
      toggle_pause unless @paused
      @toast&.show(translate('replay.ended', frames: @total_frames), permanent: true)
      render_frame
    end

    # ── Audio ─────────────────────────────────────────────────────────

    def queue_audio(volume_override: nil)
      pcm = @core.audio_buffer
      return if pcm.empty?

      if @muted
        @audio_fade_in = 0
      else
        vol = volume_override || @volume
        pcm = apply_volume_to_pcm(pcm, vol) if vol < 1.0
        if @audio_fade_in > 0
          pcm, @audio_fade_in = EmulatorFrame.apply_fade_ramp(pcm, @audio_fade_in, FADE_IN_FRAMES)
        end
        @stream.queue(pcm)
      end
    end

    def apply_volume_to_pcm(pcm, gain)
      samples = pcm.unpack('s*')
      samples.map! { |s| (s * gain).round.clamp(-32768, 32767) }
      samples.pack('s*')
    end

    # ── Rendering ─────────────────────────────────────────────────────

    def render_frame(ff_indicator: false)
      pixels = @core.video_buffer_argb
      @texture.update(pixels)
      dest = compute_dest_rect
      @viewport.render do |r|
        r.clear(0, 0, 0)
        r.copy(@texture, nil, dest)
        @hud.draw(r, dest, show_fps: @show_fps, show_ff: ff_indicator)
        @toast&.draw(r, dest)
      end
    end

    def render_empty_hint
      @empty_hint_tex ||= @overlay_font&.render_text(translate('replay.empty_hint'), 180, 180, 180)
      @viewport.render do |r|
        r.clear(0, 0, 0)
        if @empty_hint_tex
          out_w, out_h = @viewport.renderer.output_size
          x = (out_w - @empty_hint_tex.width) / 2
          y = (out_h - @empty_hint_tex.height) / 2
          r.copy(@empty_hint_tex, nil, [x, y, @empty_hint_tex.width, @empty_hint_tex.height])
        end
      end
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

    def update_fps(frames, now)
      @fps_count += frames
      elapsed = now - @fps_time
      if elapsed >= 1.0
        fps = (@fps_count / elapsed).round(1)
        @hud.set_fps(translate('player.fps', fps: fps)) if @show_fps
        @fps_count = 0
        @fps_time = now
      end
    end

    # ── Hotkey actions ────────────────────────────────────────────────

    def toggle_pause
      return unless @core
      @paused = !@paused
      if @paused
        @stream.clear
        @stream.pause
        unless @replay_ended
          @toast&.show(translate('toast.paused'), permanent: true)
        end
        render_frame
        set_event_loop_speed(:idle)
      else
        set_event_loop_speed(:fast)
        @toast&.destroy unless @replay_ended
        @stream.clear
        @audio_fade_in = FADE_IN_FRAMES
        @stream.resume
        @next_frame = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    def toggle_fast_forward
      return unless @core
      return if @replay_ended

      @fast_forward = !@fast_forward
      if @fast_forward
        @hud.set_ff_label(ff_label_text)
      else
        @hud.set_ff_label(nil)
        @next_frame = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @stream.clear
      end
    end

    def ff_label_text
      @turbo_speed == 0 ? translate('player.ff_max') : translate('player.ff', speed: @turbo_speed)
    end

    def toggle_fullscreen
      @fullscreen = !@fullscreen
      @app.command(:wm, 'attributes', @top, '-fullscreen', @fullscreen ? 1 : 0)
    end

    def toggle_show_fps
      @show_fps = !@show_fps
      @hud.set_fps(nil) unless @show_fps
    end

    def take_screenshot
      return unless @core && !@core.destroyed?

      dir = Config.default_screenshots_dir
      FileUtils.mkdir_p(dir)

      title = @core.title.strip.gsub(/[^a-zA-Z0-9_\-]/, '_')
      stamp = Time.now.strftime('%Y%m%d_%H%M%S')
      name = "replay_#{title}_#{stamp}.png"
      path = File.join(dir, name)

      pixels = @core.video_buffer_argb
      photo_name = "__gemba_rp_ss_#{object_id}"
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

    # ── Helpers ───────────────────────────────────────────────────────

    def set_event_loop_speed(mode)
      if @standalone
        ms = mode == :fast ? EVENT_LOOP_FAST_MS : EVENT_LOOP_IDLE_MS
        @app.interp.thread_timer_ms = ms
      else
        @callbacks[:on_request_speed]&.call(mode)
      end
    end

    def show_error(title, message)
      @app.command('tk_messageBox',
        parent: @top,
        title: title,
        message: message,
        type: :ok,
        icon: :error)
    end

    def cleanup
      return if @cleaned_up
      @cleaned_up = true

      @stream&.pause unless @stream&.destroyed?
      @hud&.destroy
      @toast&.destroy
      @overlay_font&.destroy unless @overlay_font&.destroyed?
      @stream&.destroy unless @stream&.destroyed?
      @texture&.destroy unless @texture&.destroyed?
      @core&.destroy unless @core&.destroyed?
    end
  end
end
