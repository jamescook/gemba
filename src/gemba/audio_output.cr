require "tryst-sdl"

module Gemba
  # The audio half of the EmulatorFrame equivalent: queues
  # Core#audio_buffer's interleaved stereo Int16 samples into a real
  # Tryst::SDL::AudioStream, with volume/mute and the queue-fill fraction
  # EmulationWorker's dynamic-rate pacing needs (see its own class
  # comment for why that crosses threads as a reported number rather
  # than the worker reading this object directly - it lives on the main
  # thread, same as everything else built on Tryst::SDL).
  class AudioOutput
    SAMPLE_RATE = 44100
    CHANNELS    =     2
    # ~50ms of audio - deep enough that a delivery hiccup doesn't
    # audibly underrun, shallow enough that pausing doesn't leave
    # several seconds of stale sound queued.
    TARGET_QUEUE_BYTES = (SAMPLE_RATE * CHANNELS * 2 * 0.05).to_i

    # Not `property?`: the generated setter would leave the stream's gain
    # untouched, and muting has to re-apply it - see #apply_gain.
    getter? muted : Bool = false
    getter volume : Float64

    @stream : Tryst::SDL::AudioStream
    @started : Bool

    def initialize
      @stream = Tryst::SDL::AudioStream.new(
        Tryst::SDL::AudioSpec.new(format: Tryst::SDL::AudioFormat::S16LE, channels: CHANNELS, freq: SAMPLE_RATE),
        allow_silent: true)
      @volume = 1.0
      @started = false
    end

    # 0.0..1.0, handed straight to SDL as the stream's gain rather than
    # scaled into the samples here - SDL applies it during the format
    # conversion it is already doing on the way to the device.
    def volume=(value : Float64) : Float64
      @volume = value.clamp(0.0, 1.0)
      apply_gain
      @volume
    end

    # Silences output without stopping the queue: the samples still go
    # in, so #fill_ratio keeps reporting real queue depth and
    # EmulationWorker's dynamic-rate pacing is unaffected by muting.
    def muted=(value : Bool) : Bool
      @muted = value
      apply_gain
      value
    end

    # Buffers before playback starts, to avoid underrun on the first
    # (likely tiny) chunk.
    def queue(samples : Slice(Int16)) : Nil
      return if samples.empty?

      # A zero-copy reinterpret, at every volume: the stream's own gain
      # does the scaling, so nothing has to be rewritten first. Safe
      # because SDL_PutAudioStreamData (AudioStream#queue) copies the
      # bytes out synchronously before returning.
      @stream.queue(Bytes.new(samples.to_unsafe.as(UInt8*), samples.size * 2))

      unless @started
        if @stream.queued_bytes >= TARGET_QUEUE_BYTES
          @stream.resume
          @started = true
        end
      end
    end

    # How full the queue is, 0.0..1.0 against TARGET_QUEUE_BYTES*2 (a
    # ceiling somewhat above the target so normal fluctuation around the
    # target doesn't pin the ratio at 1.0) - feeds EmulationWorker's
    # dynamic-rate pacing formula.
    def fill_ratio : Float64
      (@stream.queued_bytes.to_f64 / (TARGET_QUEUE_BYTES * 2)).clamp(0.0, 1.0)
    end

    def pause : Nil
      @stream.pause
    end

    def resume : Nil
      return if @stream.queued_bytes == 0
      @stream.resume
    end

    # Prevents old audio from bleeding into a new ROM or save state.
    def reset! : Nil
      @stream.clear
      @started = false
    end

    def destroy : Nil
      @stream.destroy
    end

    # Mute wins over volume while it is on, and the volume underneath is
    # remembered rather than overwritten, so unmuting restores it.
    private def apply_gain : Nil
      @stream.gain = muted? ? 0.0 : @volume
    end
  end
end
