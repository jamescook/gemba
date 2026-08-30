require "tryst"
require "./core"
require "./save_state_manager"
require "./rom_info_data"
require "./config"
require "./achievements/ra_runtime"
require "./achievements/achievement"
require "./input_recorder"
require "./recorder"

module Gemba
  # Runs one loaded ROM's Core on its own OS thread (Tryst::BackgroundWork)
  # and delivers a video+audio packet to the main thread every emulated
  # frame.
  #
  # A fresh EmulationWorker per ROM load - MainWindow #stop's the old one
  # and constructs a new one rather than this class supporting swapping
  # ROMs in place, matching Core's own one-ROM-per-instance shape.
  #
  # Input and the audio-fill dynamic-pacing ratio (see FRAME below) both
  # live on the MAIN thread (Tk key state, the SDL AudioStream) but are
  # needed every frame on the WORKER thread - crossing over via
  # BackgroundWork's String message channel, "mask:<uint32>" and
  # "fill:<float>" prefixed so the one channel can carry both.
  class EmulationWorker
    alias FramePacket = NamedTuple(video: Slice(UInt32), audio: Slice(Int16), frame_num: Int32)

    GBA_FPS        = 59.7275006
    FRAME_INTERVAL = 1.0 / GBA_FPS
    MAX_DELTA      = 0.005
    TURBO_DIVISOR  =   4.0

    # Preallocated video/audio slots #run rotates through instead of
    # allocating a fresh buffer every frame (see FrameRing). Sized well
    # past what a normally-polling UI ever needs (see EmulatorFrame#on_frame,
    # which calls #release_frame as its last step every frame) so the ring
    # only actually exhausts under sustained backlog - e.g. turbo (up to
    # TURBO_DIVISOR frames per real-time slot) outrunning a stalled UI
    # thread for multiple poll cycles in a row. #run falls back to a
    # one-off allocation for any frame that finds its slot still in use
    # rather than ever reusing it early - correctness (never tearing a
    # slot still being read) always wins over staying allocation-free.
    RING_SIZE = 16

    # Frames between Rich Presence evaluations (~4s at 60fps), matching
    # ruby gemba's own RP_EVAL_INTERVAL. The rcheevos runtime still gets
    # a #do_frame every frame - only the string is sampled this rarely,
    # since it's only ever sent to a server every 2 minutes.
    RP_EVAL_INTERVAL = 240

    getter rom_path : String

    # state_dir_override forwards straight to SaveStateManager - see its
    # own doc comment. Production code omits it; a spec passes an
    # isolated tempdir so save/load-state testing never touches a real
    # user's actual save states. quick_save_slot/backup/debounce also
    # forward straight to SaveStateManager - read from Config on the
    # main thread by the caller, since Config itself isn't safe to
    # share with the worker thread. rewind_seconds forwards to Core as
    # its rewind_entries (rounded to whole frames at GBA_FPS) - Config's
    # rewind buffer size only takes effect for a freshly-constructed
    # Core, not one already running.
    def initialize(app : Tryst::App, @rom_path : String, state_dir_override : String? = nil,
                   @quick_save_slot : Int32 = SaveStateManager::DEFAULT_QUICK_SAVE_SLOT,
                   @backup : Bool = SaveStateManager::DEFAULT_BACKUP,
                   @debounce : Time::Span = SaveStateManager::DEFAULT_DEBOUNCE,
                   rewind_seconds : Int32 = Config::DEFAULT_REWIND_SECONDS)
      # Process-wide (BackgroundWork.drop_intermediate is a class_property,
      # not per-instance) - safe to set unconditionally since gemba's own
      # process has no other BackgroundWork use that would want dropping.
      # A dropped frame here means dropped audio, not a skipped progress
      # bar tick - the default (true) would produce an audible glitch
      # every time delivery falls behind by more than one frame.
      Tryst::BackgroundWork.drop_intermediate = false

      rewind_entries = (rewind_seconds * GBA_FPS).round.to_i

      @background = Tryst::BackgroundWork(String, FramePacket).new(app, rom_path) do |task, path|
        run(task, path, state_dir_override, @quick_save_slot, @backup, @debounce, rewind_entries)
      end
    end

    def on_frame(&block : FramePacket -> Nil) : self
      @background.on_progress { |packet| block.call(packet) }
      self
    end

    def on_error(&block : String -> Nil) : self
      @background.on_error { |text| block.call(text) }
      self
    end

    # Fires for a non-frame message the worker sends back - currently
    # "save_result:<ok>:<slot>:<text>"/"load_result:<ok>:<slot>:<text>"/
    # "screenshot_result:<ok>:<filename>" (see #quick_save/#quick_load/
    # #save_slot/#load_slot/#take_screenshot), "rich_presence:<text>"
    # (#activate_rich_presence) and "achievement_unlocked:<id>"/
    # "achievement_rejected:<id>:<reason>"/
    # "achievement_screenshot_result:<ok>:<filename>"
    # (#activate_achievements/#take_achievement_screenshot), and
    # "input_record_result:start:<ok>[:<error>]"/
    # "input_record_result:stop:<frames>"
    # (#start_input_recording/#stop_input_recording), and
    # "record_result:start:<ok>[:<error>]"/"record_result:stop:<frames>"
    # (#start_recording/#stop_recording).
    def on_message(&block : String -> Nil) : self
      @background.on_message { |text| block.call(text) }
      self
    end

    # Fire-and-forget: the actual save happens on the worker's own
    # thread (see #run) - SaveStateManager and Core both live there
    # exclusively - and reports back via #on_message once it's done.
    def quick_save : Nil
      @background.send_message("quick_save")
    end

    def quick_load : Nil
      @background.send_message("quick_load")
    end

    # Same as #quick_save/#quick_load, but for an explicit slot (1-10) -
    # what the save-state picker uses; quick_save/quick_load themselves
    # stay in terms of SaveStateManager's own quick_save_slot.
    def save_slot(slot : Int32) : Nil
      @background.send_message("save_slot:#{slot}")
    end

    def load_slot(slot : Int32) : Nil
      @background.send_message("load_slot:#{slot}")
    end

    # rom_title crosses over because it's derived from the ROM's file
    # path (EmulatorFrame#rom_title), which the main thread already has
    # and Core has no equivalent of - Core#title is the cart header's
    # own game title, not the same string.
    def take_screenshot(rom_title : String) : Nil
      @background.send_message("screenshot:#{rom_title}")
    end

    # The screenshot an achievement unlock takes automatically (see
    # MainWindow's handling of "achievement_unlocked:"): same PNG as
    # #take_screenshot, named <title>_achievement_<id>_<timestamp>.png
    # so it's findable among ordinary screenshots, reported back as
    # "achievement_screenshot_result:<ok>:<filename>" - its own tag
    # because, unlike a screenshot the player asked for, this one
    # shouldn't push a "Screenshot saved" toast over the unlock's own.
    def take_achievement_screenshot(achievement_id : UInt32, rom_title : String) : Nil
      @background.send_message("achievement_screenshot:#{achievement_id}:#{rom_title}")
    end

    # Hands the game's Rich Presence script to the worker, which is
    # where the rcheevos runtime lives. Once loaded, the worker reports
    # the evaluated string back through #on_message as
    # "rich_presence:<text>", whenever it changes.
    def activate_rich_presence(script : String) : Nil
      @background.send_message("ra_script:#{script}")
    end

    # Loads achievements into the worker's rcheevos runtime, one
    # message each (a memaddr can be long, and a single message per
    # achievement keeps one rejected condition from taking the rest
    # down with it). From then on every emulated frame evaluates them
    # against live memory, and an id whose condition is met comes back
    # through #on_message as "achievement_unlocked:<id>" - once per
    # activation, rcheevos leaves a triggered achievement in its
    # triggered state rather than re-firing it. One rcheevos rejects
    # comes back as "achievement_rejected:<id>:<reason>" instead.
    #
    # Only ever hand this the achievements NOT already earned: the
    # worker has no idea what the player has, and an earned one
    # activated here would fire again as soon as its condition held.
    def activate_achievements(achievements : Array(Achievements::Achievement)) : Nil
      achievements.each do |achievement|
        @background.send_message("ra_activate:#{achievement.id}:#{achievement.memaddr}")
      end
    end

    # Drops every achievement and the presence script from the runtime.
    def clear_ra_runtime : Nil
      @background.send_message("ra_clear")
    end

    # The keys currently held, as a Button mask - sent to the worker for
    # its NEXT frame, not applied synchronously (it's on a different
    # thread).
    def input_mask=(mask : UInt32) : Nil
      @background.send_message("mask:#{mask}")
    end

    # How full the (main-thread) audio queue is right now, 0.0..1.0 -
    # feeds the worker's own dynamic-rate pacing. See the class comment.
    def report_fill(ratio : Float64) : Nil
      @background.send_message("fill:#{ratio}")
    end

    def turbo=(enabled : Bool) : Nil
      @background.send_message(enabled ? "turbo:on" : "turbo:off")
    end

    # Starts recording per-frame input masks to path (see InputRecorder
    # - it lives on the worker thread, where Core and the authoritative
    # per-frame mask both are; the main thread's #input_mask= updates
    # only arrive between frames, so capturing there could log a mask a
    # frame never actually ran under). Parent directories are created as
    # needed. Reports back "input_record_result:start:<ok>[:<error>]" -
    # a start can genuinely fail (the anchor save state not writing) and
    # the caller's recording indicator should only ever show a recording
    # that's real. Ignored if a recording is already running.
    def start_input_recording(path : String) : Nil
      @background.send_message("input_record_start:#{path}")
    end

    # Stops and finalizes the current recording (flush + the header's
    # in-place frame_count rewrite), reporting
    # "input_record_result:stop:<frames>". Ignored if nothing is
    # recording. A worker stopped mid-recording (#stop, or the ROM being
    # swapped) finalizes the file the same way on its way out - it just
    # sends no message, since the channel is already closing.
    def stop_input_recording : Nil
      @background.send_message("input_record_stop")
    end

    # Starts recording video+audio to a .grec at path (see Recorder).
    # Same shape as #start_input_recording, for the same reason: the
    # frames being recorded only exist on the worker thread, so the
    # recorder lives there too, and the caller's indicator flips on the
    # confirmed "record_result:start:<ok>" - never optimistically.
    # compression is a zlib level (Config#recording_compression).
    def start_recording(path : String, compression : Int32 = 1) : Nil
      @background.send_message("record_start:#{compression}:#{path}")
    end

    # Stops and finalizes the .grec (footer written, writer thread
    # joined), reporting "record_result:stop:<frames>". A worker
    # stopped mid-recording finalizes on its way out without a message,
    # like input recording.
    def stop_recording : Nil
      @background.send_message("record_stop")
    end

    # Hold-to-rewind: true while the hotkey is physically held (see
    # EmulatorFrame#on_frame, which polls key state every frame since
    # Tk only fires one KeyRelease for a held key, not a stream).
    def rewind=(enabled : Bool) : Nil
      @background.send_message(enabled ? "rewind:on" : "rewind:off")
    end

    # Tells the worker it's safe to reuse the ring buffer slot that
    # frame_num's video/audio point into (see FrameRing) - call once done
    # reading a delivered FramePacket's buffers, not before (EmulatorFrame#
    # on_frame does this as its last step, after both @video.present and
    # @audio.queue have already copied the data out synchronously). A
    # frame_num whose slot was already reused (a fallback allocation, or a
    # stale/duplicate call) is silently ignored - see FrameRing#release.
    def release_frame(frame_num : Int32) : Nil
      @background.send_message("frame_done:#{frame_num}")
    end

    def pause : Nil
      @background.pause
    end

    def resume : Nil
      @background.resume
    end

    def paused? : Bool
      @background.paused?
    end

    def done? : Bool
      @background.done?
    end

    # Stops the worker. Not reusable afterward - load_rom on the caller
    # constructs a fresh EmulationWorker instead.
    def stop : Nil
      @background.close
    end

    # Mutable mask/pace-ratio/turbo state the worker loop below tracks,
    # updated by whatever message last arrived on the String channel -
    # pulled out of #run so its own message-dispatch logic doesn't count
    # against #run's cyclomatic complexity.
    private class WorkerState
      property mask : UInt32 = 0_u32
      property ratio : Float64 = 1.0
      property? turbo : Bool = false
      property? rewind : Bool = false

      # The active input recording, if any - held here (rather than as
      # a #run local) so the message dispatch below can start/stop it
      # while the frame loop reads it. Worker-thread-only, like the
      # Core it snapshots its anchor state from.
      property input_recorder : InputRecorder?

      # The active .grec video recording, same arrangement.
      property recorder : Recorder?

      # Applies one message. Returns true if it was a Stop (the caller's
      # cue to break its loop) - every other kind updates state in place
      # and returns false.
      def apply(msg : Tryst::BackgroundMessage) : Bool
        case msg
        when Tryst::BackgroundControl::Stop
          true
        when String
          apply_string(msg)
          false
        else
          false
        end
      end

      private def apply_string(msg : String) : Nil
        tag, payload = msg.split(':', 2)
        case tag
        when "mask"   then @mask = payload.to_u32
        when "fill"   then @ratio = (1.0 - MAX_DELTA) + 2.0 * payload.to_f64 * MAX_DELTA
        when "turbo"  then @turbo = payload == "on"
        when "rewind" then @rewind = payload == "on"
        end
      end
    end

    # A small pool of preallocated video/audio buffers #run rotates
    # through by frame_num % size, replacing a fresh .dup every frame.
    # Slot N is "in use" (owner[N] set to whichever frame_num currently
    # occupies it) from the moment #acquire hands it out until the main
    # thread calls EmulationWorker#release_frame for that exact frame_num
    # - #run must never reacquire a slot that's still in use, or the main
    # thread could end up reading a slot the worker has already started
    # overwriting for a later frame (tearing).
    private class FrameRing
      def initialize(video_len : Int32, audio_capacity : Int32, size : Int32)
        @video = Array(Slice(UInt32)).new(size) { Slice(UInt32).new(video_len, 0_u32) }
        @audio = Array(Slice(Int16)).new(size) { Slice(Int16).new(audio_capacity, 0_i16) }
        @owner = Array(Int32?).new(size, nil)
        @size = size
      end

      def free?(frame_num : Int32) : Bool
        @owner[frame_num % @size].nil?
      end

      # Claims frame_num's slot, marking it in use, and returns the
      # (video, audio) buffers to write this frame's data into. Only
      # ever call once #free? confirmed the slot isn't still owned by an
      # older, not-yet-released frame.
      def acquire(frame_num : Int32) : {Slice(UInt32), Slice(Int16)}
        slot = frame_num % @size
        @owner[slot] = frame_num
        {@video[slot], @audio[slot]}
      end

      # Frees frame_num's slot for reuse - a no-op if that slot has
      # already been reassigned to a later frame_num (a stale or
      # duplicate release, or a frame_num that took the fallback-
      # allocation path and never actually owned a slot).
      def release(frame_num : Int32) : Nil
        slot = frame_num % @size
        @owner[slot] = nil if @owner[slot] == frame_num
      end
    end

    private def run(task : Tryst::TaskContext(FramePacket), rom_path : String, state_dir_override : String?,
                    quick_save_slot : Int32, backup : Bool, debounce : Time::Span, rewind_entries : Int32) : Nil
      core = Core.new(rom_path, rewind_entries: rewind_entries)
      task.send_message("rom_info:#{RomInfoData.from_core(core).to_json}")
      save_states = SaveStateManager.new(core, state_dir: state_dir_override,
        quick_save_slot: quick_save_slot, backup: backup, debounce: debounce)
      frame_num = 0
      next_frame_at = Time.instant
      state = WorkerState.new
      ring = FrameRing.new(core.video_buffer.size, Core::AUDIO_BUFFER_SIZE.to_i32 * 2, RING_SIZE)

      # Lives on THIS thread, not the main one: evaluating conditions
      # means reading emulator memory through core.bus_read*, and Core
      # is worker-thread-only. Only the results cross back - the
      # presence string and triggered achievement ids - as plain
      # messages; which ids are already earned, and telling the site
      # about a new one, is the main thread's business.
      ra_runtime = Achievements::RARuntime.new
      rich_presence = ""

      loop do
        task.check_pause
        break if drain_messages(task, core, save_states, state, ring, ra_runtime)

        core.keys = state.mask
        # Captured HERE, not where the "mask:" message lands: this is
        # the mask this frame actually runs under, which is the whole
        # contract a .gir replay depends on.
        state.input_recorder.try(&.capture(state.mask))

        # Ported from mgba/core/thread.c's own _frameStarted: while
        # rewinding, restore the most recent snapshot instead of taking a
        # new one, so running forward one frame from progressively older
        # states is what produces the backward-playing effect. Falls back
        # to a normal #rewind_append (both when not rewinding, and once
        # rewinding runs out of history) so playback always has SOME
        # snapshot to resume forward from afterward.
        core.rewind_append unless state.rewind? && core.rewind_restore
        core.run_frame

        rich_presence = evaluate_achievements(task, core, ra_runtime, frame_num, rich_presence)

        # Turbo runs ~TURBO_DIVISOR emulated frames per real-time frame
        # slot, but mGBA generates audio at its own fixed rate regardless
        # of how fast we're stepping it - queuing every turbo frame's
        # audio would push TURBO_DIVISOR times too much PCM into a
        # fixed-rate stream every real second, which is a genuine desync,
        # not just a pitch change. Ported from emulator_frame.rb's own
        # tick_fast_forward: keep only 1 in TURBO_DIVISOR frames' audio,
        # but still DRAIN the rest (call #audio_buffer, discard the
        # result) so mGBA's internal buffer doesn't overflow between
        # kept frames.
        audio = core.audio_buffer
        # Every frame's video AND audio, before the turbo keep/drop
        # below - the recording stays full-rate even while turbo
        # playback discards most audio (ruby's capture_frame does the
        # same, returning the pcm so the play path reuses the one
        # drain).
        state.recorder.try(&.capture(core.video_buffer, audio))
        keep_audio = !state.turbo? || frame_num % TURBO_DIVISOR.to_i == 0

        video, packet_audio =
          if ring.free?(frame_num)
            video_slot, audio_slot = ring.acquire(frame_num)
            video_slot.copy_from(core.video_buffer)
            {video_slot, copy_into_audio_slot(audio_slot, audio, keep_audio)}
          else
            # Ring exhausted - the main thread has fallen further behind
            # than RING_SIZE frames (never expected in steady state; see
            # RING_SIZE's own comment). Fall back to a one-off allocation
            # rather than reusing a slot still being read.
            {core.video_buffer.dup, keep_audio ? audio.dup : Slice(Int16).empty}
          end

        task.yield({video: video, audio: packet_audio, frame_num: frame_num})
        frame_num += 1

        interval = state.turbo? ? FRAME_INTERVAL / TURBO_DIVISOR : FRAME_INTERVAL * state.ratio
        next_frame_at += interval.seconds
        now = Time.instant
        sleep(next_frame_at - now) if next_frame_at > now
        next_frame_at = now if now - next_frame_at > 0.1.seconds
      end
    ensure
      # The loop above never exits normally on #stop: TaskContext raises
      # Stopped out of check_pause/check_message the moment the Stop
      # control arrives (caught by BackgroundWork#start, a frame above
      # this one), so teardown only ever runs via this ensure - plain
      # code after the loop silently never ran (which used to leak a
      # whole mGBA core per ROM swap, ra_runtime.close and core.destroy
      # having sat exactly there). The .try calls aren't decoration
      # either: Core.new itself can raise (a bad ROM path), landing here
      # with the later locals never assigned.
      #
      # A recording still running when the worker stops (ROM swapped,
      # app quitting) is finalized rather than left with a zero
      # frame_count and an unflushed tail - the file should replay no
      # matter how the session ended.
      state.try(&.input_recorder).try(&.stop)
      state.try(&.recorder).try(&.stop)
      ra_runtime.try(&.close)
      core.try(&.destroy)
    end

    # Copies this frame's drained audio into its ring slot and returns
    # the (sub-)slice actually holding it - empty if the frame isn't
    # keeping audio (turbo drop), or a defensive fresh .dup on the
    # extremely unlikely chance mGBA ever drains more samples than
    # AUDIO_BUFFER_SIZE allows for (see Core::AUDIO_BUFFER_SIZE) - never
    # crash on a size mismatch just to stay allocation-free.
    private def copy_into_audio_slot(slot : Slice(Int16), audio : Slice(Int16), keep_audio : Bool) : Slice(Int16)
      return Slice(Int16).empty unless keep_audio
      return audio.dup if audio.size > slot.size

      view = slot[0, audio.size]
      view.copy_from(audio)
      view
    end

    # Steps the rcheevos runtime for this frame - reporting any
    # achievement whose condition was just met - and, every
    # RP_EVAL_INTERVAL frames, samples the presence string, sending it
    # to the main thread only when it actually changed. Returns the
    # current string so the caller can carry it to the next frame.
    #
    # No "skip when there are no achievements" guard on the presence
    # half (ruby gemba has one, `return if @achievements.empty?`): a
    # game with a presence script but no achievements is a real thing,
    # and that guard would silently switch its presence off.
    private def evaluate_achievements(task : Tryst::TaskContext(FramePacket), core : Core,
                                      ra_runtime : Achievements::RARuntime,
                                      frame_num : Int32, previous : String) : String
      return previous unless ra_runtime.count > 0 || ra_runtime.richpresence_active?

      # do_frame is what refreshes rcheevos' cached memory values -
      # get_richpresence alone reads stale ones, so this runs every
      # frame even though the string is only sampled periodically.
      triggered = ra_runtime.do_frame { |address, num_bytes| ra_peek(core, address, num_bytes) }
      triggered.each { |id| task.send_message("achievement_unlocked:#{id}") }

      return previous unless ra_runtime.richpresence_active?
      return previous unless frame_num % RP_EVAL_INTERVAL == 0

      message = ra_runtime.get_richpresence { |address, num_bytes| ra_peek(core, address, num_bytes) }
      return previous unless message && message != previous

      task.send_message("rich_presence:#{message}")
      message
    end

    # RA addresses are flat; mGBA's bus is not - see
    # RARuntime.to_gba_address. rcheevos asks for "num_bytes starting at
    # address", little-endian, at any byte offset - but a GBA halfword/
    # word load at a misaligned address doesn't do that, it returns the
    # aligned value byte-rotated. So an aligned read goes straight to
    # the bus, and a misaligned one is assembled from single bytes,
    # which is the value the script actually meant. 0 for an address
    # outside IWRAM/EWRAM, rcheevos' own convention for unreadable
    # memory.
    private def ra_peek(core : Core, address : UInt32, num_bytes : UInt32) : UInt32
      gba = Achievements::RARuntime.to_gba_address(address)
      return 0_u32 unless gba

      case num_bytes
      when 1 then core.bus_read8(gba).to_u32
      when 2 then gba & 1 == 0 ? core.bus_read16(gba).to_u32 : ra_peek_bytes(core, gba, 2)
      when 4 then gba & 3 == 0 ? core.bus_read32(gba) : ra_peek_bytes(core, gba, 4)
      else        0_u32
      end
    end

    private def ra_peek_bytes(core : Core, gba : UInt32, count : Int32) : UInt32
      value = 0_u32
      count.times { |i| value |= core.bus_read8(gba + i).to_u32 << (8 * i) }
      value
    end

    # The RetroAchievements half of the worker's message channel, split
    # out so #drain_messages' own dispatch stays under the complexity
    # limit. Returns true when msg was one of ours.
    private def apply_ra_message(msg, task : Tryst::TaskContext(FramePacket),
                                 ra_runtime : Achievements::RARuntime) : Bool
      return false unless msg.is_a?(String)

      if script = msg.lchop?("ra_script:")
        ra_runtime.activate_richpresence(script)
      elsif payload = msg.lchop?("ra_activate:")
        activate_achievement(payload, task, ra_runtime)
      elsif msg == "ra_clear"
        ra_runtime.clear
      else
        return false
      end
      true
    end

    # "<id>:<memaddr>" - split on the FIRST colon only, a condition
    # string is free to contain more. A condition rcheevos won't parse
    # is reported rather than raised: it's one bad row in the site's
    # data, not a reason to stop emulating.
    private def activate_achievement(payload : String, task : Tryst::TaskContext(FramePacket),
                                     ra_runtime : Achievements::RARuntime) : Nil
      id, memaddr = payload.split(':', 2)
      ra_runtime.activate(id.to_u32, memaddr || "")
    rescue ex : ArgumentError
      task.send_message("achievement_rejected:#{id}:#{ex.message}")
    end

    # Writes Paths.screenshots_dir/<title>_<timestamp>.png straight from
    # the core (see Core#take_screenshot_to_file) and returns the
    # filename alone (not the full path) - all handle_worker_message's
    # toast needs. mkdir_p/Time.local both belong here rather than on
    # the main thread: the same blocking-syscall guard that pushed
    # ruby's old Tk-Photo screenshot path through App#off_thread applies
    # equally to this worker thread, it's just already off Tk's.
    private def take_screenshot(core : Core, rom_title : String) : {Bool, String}
      dir = Paths.screenshots_dir
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      title = rom_title.empty? ? "gemba" : rom_title
      filename = "#{title}_#{Time.local.to_s("%Y%m%d_%H%M%S")}.png"
      {core.take_screenshot_to_file(File.join(dir, filename)), filename}
    end

    # save_slot/load_slot/screenshot/frame_done, split out for the same
    # reason as #apply_ra_message: keeps #drain_messages' own dispatch
    # under the complexity limit. Returns true when msg was one of ours.
    private def apply_slot_message(msg, task : Tryst::TaskContext(FramePacket), core : Core,
                                   save_states : SaveStateManager, ring : FrameRing,
                                   ra_runtime : Achievements::RARuntime) : Bool
      return false unless msg.is_a?(String)

      if slot = msg.lchop?("save_slot:")
        ok, text = save_states.save_state(core, slot.to_i)
        task.send_message("save_result:#{ok}:#{slot}:#{text}")
      elsif slot = msg.lchop?("load_slot:")
        ok, text = save_states.load_state(core, slot.to_i)
        finish_state_load(task, ra_runtime, ok, slot.to_i, text)
      elsif rom_title = msg.lchop?("screenshot:")
        ok, filename = take_screenshot(core, rom_title)
        task.send_message("screenshot_result:#{ok}:#{filename}")
      elsif payload = msg.lchop?("achievement_screenshot:")
        achievement_id, rom_title = payload.split(':', 2)
        ok, filename = take_screenshot(core, "#{rom_title}_achievement_#{achievement_id}")
        task.send_message("achievement_screenshot_result:#{ok}:#{filename}")
      elsif frame_num = msg.lchop?("frame_done:")
        ring.release(frame_num.to_i)
      else
        return false
      end
      true
    end

    # The input-recording half of the message channel - same split-out
    # shape as #apply_ra_message, same reason. Returns true when msg was
    # one of ours.
    private def apply_input_record_message(msg, task : Tryst::TaskContext(FramePacket), core : Core,
                                           state : WorkerState) : Bool
      return false unless msg.is_a?(String)

      if path = msg.lchop?("input_record_start:")
        start_input_record(path, task, core, state)
      elsif msg == "input_record_stop"
        if recorder = state.input_recorder
          recorder.stop
          state.input_recorder = nil
          task.send_message("input_record_result:stop:#{recorder.frame_count}")
        end
      elsif payload = msg.lchop?("record_start:")
        start_record(payload, task, core, state)
      elsif msg == "record_stop"
        if recorder = state.recorder
          recorder.stop
          state.recorder = nil
          task.send_message("record_result:stop:#{recorder.frame_count}")
        end
      else
        return false
      end
      true
    end

    # "<compression>:<path>" - split on the FIRST colon only, the path
    # is free to contain more. Same failure/duplicate policy as
    # #start_input_record: report, don't raise; ignore a start while
    # one is already running.
    private def start_record(payload : String, task : Tryst::TaskContext(FramePacket),
                             core : Core, state : WorkerState) : Nil
      return if state.recorder

      compression, path = payload.split(':', 2)
      Dir.mkdir_p(File.dirname(path))
      recorder = Recorder.new(path, core.width, core.height, compression: compression.to_i)
      recorder.start
      state.recorder = recorder
      task.send_message("record_result:start:true")
    rescue ex
      task.send_message("record_result:start:false:#{ex.message}")
    end

    # A failed start (most plausibly the anchor save state not writing -
    # a full disk, a permissions problem) is reported, not raised: it's
    # a lost recording, not a reason to stop emulating. A duplicate
    # start while one is already running is silently ignored - the first
    # start's own result message already told the main thread what's on.
    private def start_input_record(path : String, task : Tryst::TaskContext(FramePacket),
                                   core : Core, state : WorkerState) : Nil
      return if state.input_recorder

      Dir.mkdir_p(File.dirname(path))
      recorder = InputRecorder.new(path, core, rom_path: @rom_path)
      recorder.start
      state.input_recorder = recorder
      task.send_message("input_record_result:start:true")
    rescue ex
      task.send_message("input_record_result:start:false:#{ex.message}")
    end

    # Reports a load's outcome and, if memory really did just jump to
    # the saved state, sends every achievement back through rcheevos'
    # priming: one whose condition happens to hold in the loaded memory
    # would otherwise trigger on the very next frame - and be awarded,
    # since the main thread submits any trigger it hasn't seen earned.
    # Hit counts and delta/prior histories go too, same as ruby gemba's
    # reset_runtime after a load. Rewind deliberately doesn't do this
    # (ruby doesn't either): it steps one frame at a time, which the
    # delta tracking copes with.
    private def finish_state_load(task : Tryst::TaskContext(FramePacket), ra_runtime : Achievements::RARuntime,
                                  ok : Bool, slot : Int32, text : String) : Nil
      ra_runtime.reset_all if ok
      task.send_message("load_result:#{ok}:#{slot}:#{text}")
    end

    # Applies every currently-queued message. Returns true for a Stop
    # control message (the caller's cue to break its frame loop) - the
    # save/load-slot and RA dispatch live in their own methods so they
    # don't count against this one's cyclomatic complexity.
    private def drain_messages(task : Tryst::TaskContext(FramePacket), core : Core,
                               save_states : SaveStateManager, state : WorkerState, ring : FrameRing,
                               ra_runtime : Achievements::RARuntime) : Bool
      while msg = task.check_message
        case msg
        when "quick_save"
          ok, text = save_states.quick_save(core)
          task.send_message("save_result:#{ok}:#{save_states.quick_save_slot}:#{text}")
        when "quick_load"
          ok, text = save_states.quick_load(core)
          finish_state_load(task, ra_runtime, ok, save_states.quick_save_slot, text)
        else
          if apply_slot_message(msg, task, core, save_states, ring, ra_runtime)
            # handled
          elsif apply_ra_message(msg, task, ra_runtime)
            # handled
          elsif apply_input_record_message(msg, task, core, state)
            # handled
          elsif state.apply(msg)
            return true
          end
        end
      end
      false
    end
  end
end
