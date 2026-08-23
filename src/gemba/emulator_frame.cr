require "./video_output"
require "./audio_output"
require "./emulation_worker"
require "./save_state_manager"
require "./keyboard_map"
require "./gamepad_map"
require "./frame_stack"
require "./rom_info_data"
require "./locale"

module Gemba
  # The per-ROM-session half of ruby's own EmulatorFrame (lib/gemba/
  # emulator_frame.rb) - implements the Frame protocol so MainWindow's
  # FrameStack can show/hide it alongside GamePickerFrame.
  #
  # Deliberately does NOT own VideoOutput/AudioOutput the way ruby's
  # single-thread EmulatorFrame owns its SDL2 surface/stream outright:
  # those are expensive, real OS resources (an SDL renderer + audio
  # device) that this port already builds once and reuses across ROM
  # loads via VideoOutput#reset! (see its own doc comment - recreating
  # them per ROM would mean re-opening the audio device and rebuilding
  # the SDL renderer every time the player returns to the game picker
  # and picks something else). EmulatorFrame takes both as constructor
  # dependencies instead, and only owns what's genuinely fresh per ROM:
  # the EmulationWorker (a whole OS thread) and turbo/volume state.
  class EmulatorFrame
    include Frame

    TURBO_VOLUME  = 0.25
    NATIVE_WIDTH  =  240
    NATIVE_HEIGHT =  160

    getter worker : EmulationWorker
    getter rom_title : String
    getter rom_info : RomInfoData?

    # Wall-clock window a frame count is averaged over before the FPS
    # counter's text updates - matches ruby's own update_fps.
    FPS_INTERVAL = 1.0

    @turbo : Bool = false
    @saved_volume : Float64
    @on_message : (String -> Nil)?
    @on_rom_info : (RomInfoData -> Nil)?
    @fps_count : Int32 = 0
    @fps_started_at : Time::Instant

    def initialize(@app : Tryst::App, @video : VideoOutput, @audio : AudioOutput,
                   @keyboard_map : KeyboardMap, @gamepad_map : GamepadMap,
                   rom_path : String, state_dir_override : String? = nil,
                   quick_save_slot : Int32 = SaveStateManager::DEFAULT_QUICK_SAVE_SLOT,
                   backup : Bool = SaveStateManager::DEFAULT_BACKUP,
                   debounce : Time::Span = SaveStateManager::DEFAULT_DEBOUNCE)
      @rom_title = File.basename(rom_path).sub(/\.gba$/i, "")
      @saved_volume = @audio.volume
      @fps_started_at = Time.instant

      @video.reset!(NATIVE_WIDTH, NATIVE_HEIGHT)
      @audio.reset!

      worker = EmulationWorker.new(@app, rom_path, state_dir_override: state_dir_override,
        quick_save_slot: quick_save_slot, backup: backup, debounce: debounce)
      worker.on_frame { |packet| on_frame(packet) }
      worker.on_message { |text| handle_message(text) }
      @worker = worker
    end

    # Pass-through so the caller can still react to a bad ROM, without
    # EmulatorFrame itself deciding how to report it (dialog box, log
    # line - that's app-level policy, same split MainWindow drew before
    # this class existed).
    def on_error(&block : String -> Nil) : self
      @worker.on_error(&block)
      self
    end

    # Fires for any worker message OTHER than "rom_info:..." (which
    # #handle_message intercepts and caches as #rom_info itself) -
    # currently "save_result:.../load_result:...".
    def on_message(&block : String -> Nil) : self
      @on_message = block
      self
    end

    # Fires once, the moment the "rom_info:..." message itself arrives
    # (not just whenever #rom_info happens to be queried afterward) - lets
    # a caller react right when game_code/checksum become known, e.g. to
    # patch them onto the RomLibrary entry #remember already created.
    def on_rom_info(&block : RomInfoData -> Nil) : self
      @on_rom_info = block
      self
    end

    def show : Nil
      @app.command(:pack, @video.viewport.path, fill: :both, expand: 1)
      @app.command(:focus, @video.viewport.path)
    end

    def hide : Nil
      @app.command(:pack, :forget, @video.viewport.path)
    end

    # Stops the worker thread. Does NOT destroy @video/@audio - those
    # outlive this frame, see the class comment.
    def cleanup : Nil
      @worker.stop
    end

    def quick_save : Nil
      @worker.quick_save
    end

    def quick_load : Nil
      @worker.quick_load
    end

    def save_slot(slot : Int32) : Nil
      @worker.save_slot(slot)
    end

    def load_slot(slot : Int32) : Nil
      @worker.load_slot(slot)
    end

    # The per-ROM save-state directory (states/<game>-<crc>/, computed
    # from the cached #rom_info) - what the save-state picker lists
    # slots/thumbnails from. nil until the "rom_info:" message arrives
    # (see #handle_message) - Core itself is worker-thread-only, so this
    # is computed from the same plain data that crosses over for
    # RomInfoWindow, not from Core directly.
    def state_dir : String?
      rom_info.try { |data| SaveStateManager.state_dir_for(data.game_code, data.checksum) }
    end

    def paused? : Bool
      @worker.paused?
    end

    def pause : Nil
      @worker.pause
      @video.show_toast(Locale.translate("toast.paused"), permanent: true)
      @video.redraw
      @video.present
    end

    def resume : Nil
      @worker.resume
      @video.hide_toast
    end

    def toggle_pause : Nil
      paused? ? resume : pause
    end

    def toggle_turbo : Nil
      @turbo = !@turbo
      @worker.turbo = @turbo

      if @turbo
        @saved_volume = @audio.volume
        @audio.volume = TURBO_VOLUME
        @video.show_ff_label(Locale.translate("player.ff_max"))
      else
        @audio.volume = @saved_volume
        @video.hide_ff_label
      end
    end

    private def on_frame(packet : EmulationWorker::FramePacket) : Nil
      @video.present(packet[:video], show_ff: @turbo)
      @audio.queue(packet[:audio])
      # Both calls above copy the packet's buffers out synchronously
      # (VideoOutput#draw into its own ARGB buffer/texture, AudioOutput#
      # queue into the SDL stream) - safe to hand the ring slot back to
      # the worker as the very next thing, not before.
      @worker.release_frame(packet[:frame_num])
      @worker.input_mask = (@keyboard_map.mask | @gamepad_map.mask).value.to_u32
      @worker.report_fill(@audio.fill_ratio)
      update_fps
    end

    # Ported from ruby's own #update_fps: count frames as they actually
    # arrive (already paced by EmulationWorker, turbo or not) and
    # recompute the displayed rate once per FPS_INTERVAL rather than on
    # every single frame - a number that changes every ~16ms is not
    # something anyone can read.
    private def update_fps : Nil
      @fps_count += 1
      elapsed = (Time.instant - @fps_started_at).total_seconds
      return if elapsed < FPS_INTERVAL

      fps = (@fps_count / elapsed).round(1)
      @video.show_fps_text(Locale.translate("player.fps", fps: fps)) if @video.show_fps?
      @fps_count = 0
      @fps_started_at = Time.instant
    end

    private def handle_message(text : String) : Nil
      tag, _, payload = text.partition(':')

      if tag == "rom_info"
        data = RomInfoData.from_json(payload)
        @rom_info = data
        @on_rom_info.try(&.call(data))
      else
        @on_message.try(&.call(text))
      end
    end
  end
end
