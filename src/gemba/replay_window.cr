require "tryst/ui"
require "./video_output"
require "./audio_output"
require "./emulation_worker"
require "./input_replayer"
require "./hotkey_map"
require "./locale"
require "./session_logger"

module Gemba
  # The .gir replay viewer - ruby gemba's ReplayPlayer, in this port's
  # shape: no core or frame loop of its own, just an EmulationWorker in
  # replay mode (see its replay_gir) rendered into this window's own
  # VideoOutput/AudioOutput pair. No game input is accepted - the masks
  # come from the recording; the only keys are the pause/fast-forward
  # hotkeys and Escape to close.
  #
  # The window handle is declared (empty) by MainWindow before
  # run_async, like Settings; this class attaches the SDL viewport and
  # audio stream lazily on first #open, since both need a live App -
  # and keeps them across opens, the same reuse argument as the main
  # VideoOutput's.
  #
  # MainWindow owns the modal-stack push/pop (which is also what pauses
  # the running game underneath, ruby-style) - this class just asks to
  # be closed via #on_close_requested.
  class ReplayWindow
    getter handle : Tryst::UI::Handle

    # True once the recording's last frame has played (the worker's
    # "replay_ended:" message) - the replay pauses there, ruby-style.
    getter? ended : Bool = false

    # The active replay's worker - exposed so MainWindow's teardown
    # (and a spec) can confirm it actually stopped. nil until #open.
    getter worker : EmulationWorker?

    @video : VideoOutput?
    @audio : AudioOutput?
    @fast_forward = false
    @fullscreen = false
    @rom_title = ""
    @on_close_requested : (-> Nil)?

    def initialize(@app : Tryst::App, @handle : Tryst::UI::Handle, @hotkeys : HotkeyMap,
                   @scale : Int32 = 3)
      bind_key(:pause) { toggle_pause }
      bind_key(:fast_forward) { toggle_fast_forward }
      bind_key(:fullscreen) { toggle_fullscreen }
      bind_key(:screenshot) { take_screenshot }
      @handle.on_key(:escape) { |_args, _signal| @on_close_requested.try(&.call) }
    end

    # Escape or the WM close button - MainWindow wires this to stop the
    # replay and pop the modal stack.
    def on_close_requested(&block : -> Nil) : Nil
      @on_close_requested = block
    end

    # Starts replaying gir_path. Returns nil on success, or a
    # human-readable error when the recording can't be opened (most
    # commonly: the ROM it references no longer exists at its recorded
    # path). A checksum/anchor failure inside the worker reports
    # through the log instead - it only surfaces after the worker
    # thread has the Core open.
    def open(gir_path : String) : String?
      stop

      rom_path, rom_exists = @app.off_thread do
        parsed = InputReplayer.new(gir_path).rom_path
        {parsed, !!(parsed && File.exists?(parsed))}
      end
      unless rom_path && rom_exists
        return "The ROM referenced by this recording no longer exists:\n#{rom_path || "(none)"}"
      end

      # The SDL viewport can only attach to a MAPPED Tk window (it needs
      # the native window handle) - deiconify and run the event loop
      # once before first building it. MainWindow's modal push #show's
      # the handle again right after; that's harmless.
      @handle.show
      @app.update

      video = (@video ||= VideoOutput.new(@app, parent: @handle.path, scale: @scale))
      audio = (@audio ||= AudioOutput.new)
      video.reset!(240, 160)
      audio.reset!
      @ended = false
      @fast_forward = false
      # "replay_" prefix so these screenshots sort apart from live-play
      # ones, matching ruby's replay take_screenshot naming.
      @rom_title = "replay_#{File.basename(rom_path).sub(/\.gba$/i, "")}"

      worker = EmulationWorker.new(@app, rom_path, replay_gir: gir_path)
      worker.on_frame { |packet| on_frame(packet) }
      worker.on_message { |text| handle_message(text) }
      worker.on_error do |text|
        Gemba.log(SessionLogger::Level::Error) { "Replay failed: #{text}" }
        @ended = true
      end
      @worker = worker
      nil
    end

    # Stops the current replay's worker (idempotent) - the window
    # itself is hidden by MainWindow's modal pop, not here.
    def stop : Nil
      @worker.try(&.stop)
      @worker = nil
      @audio.try(&.pause)
      @video.try(&.hide_toast)
      @video.try(&.hide_ff_label)
      toggle_fullscreen if @fullscreen
    end

    # Full resource teardown for app shutdown.
    def destroy : Nil
      stop
      @video.try(&.destroy)
      @video = nil
      @audio.try(&.destroy)
      @audio = nil
    end

    def paused? : Bool
      @worker.try(&.paused?) || false
    end

    def toggle_pause : Nil
      worker = @worker
      return if worker.nil? || ended?

      if worker.paused?
        worker.resume
        @video.try(&.hide_toast)
      else
        worker.pause
        if video = @video
          video.show_toast(Locale.translate("toast.paused"), permanent: true)
          video.redraw
          video.present
        end
      end
    end

    def toggle_fullscreen : Nil
      @fullscreen = !@fullscreen
      @app.command(:wm, "attributes", @handle.path, "-fullscreen", @fullscreen ? 1 : 0)
    end

    # Same worker screenshot path a live game uses (the message-based
    # round trip is already replay-safe); only the toast lands on THIS
    # window's video.
    def take_screenshot : Nil
      @worker.try(&.take_screenshot(@rom_title))
    end

    def toggle_fast_forward : Nil
      worker = @worker
      return if worker.nil? || ended?

      @fast_forward = !@fast_forward
      worker.turbo = @fast_forward
      if @fast_forward
        @video.try(&.show_ff_label(Locale.translate("player.ff_max")))
      else
        @video.try(&.hide_ff_label)
      end
    end

    private def on_frame(packet : EmulationWorker::FramePacket) : Nil
      worker = @worker
      return unless worker

      @video.try(&.present(packet[:video], show_ff: @fast_forward))
      @audio.try do |audio|
        audio.queue(packet[:audio])
        worker.report_fill(audio.fill_ratio)
      end
      worker.release_frame(packet[:frame_num])
    end

    private def handle_message(text : String) : Nil
      if payload = text.lchop?("screenshot_result:")
        ok, filename = payload.split(':', 2)
        key = ok == "true" ? "toast.screenshot_saved" : "toast.screenshot_failed"
        @video.try(&.show_toast(Locale.translate(key, name: filename)))
        return
      end

      return unless frames = text.lchop?("replay_ended:")

      @ended = true
      # Pause on the last frame with a persistent "complete" toast,
      # matching ruby's on_replay_end - the worker is already idling
      # past the end (see EmulationWorker#replay_mask), the pause just
      # makes the state honest for #paused?/resume.
      @worker.try(&.pause)
      if video = @video
        video.show_toast(Locale.translate("replay.ended", frames: frames), permanent: true)
        video.redraw
        video.present
      end
    end

    private def bind_key(action : Symbol, &block : -> Nil) : Nil
      hotkey = @hotkeys.key_for(action)
      return unless hotkey

      spec = hotkey.is_a?(Array) ? hotkey.join('-') : hotkey
      @handle.on_key(spec) { |_args, _signal| block.call }
    end
  end
end
