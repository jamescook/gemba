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

    property? muted : Bool = false
    getter volume : Float64

    @stream : Tryst::SDL::AudioStream
    @started : Bool
    @scratch : Slice(Int16) = Slice(Int16).empty

    def initialize
      @stream = Tryst::SDL::AudioStream.new(
        Tryst::SDL::AudioSpec.new(format: Tryst::SDL::AudioFormat::S16LE, channels: CHANNELS, freq: SAMPLE_RATE),
        allow_silent: true)
      @volume = 1.0
      @started = false
    end

    # 0.0..1.0. Applied by scaling samples before they're queued - SDL's
    # own per-stream gain would be simpler, but AudioStream doesn't
    # expose one yet.
    def volume=(value : Float64) : Float64
      @volume = value.clamp(0.0, 1.0)
    end

    # Buffers before playback starts, to avoid underrun on the first
    # (likely tiny) chunk.
    def queue(samples : Slice(Int16)) : Nil
      return if samples.empty?

      bytes = scaled_bytes(samples)
      @stream.queue(bytes)

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

    private def scaled_bytes(samples : Slice(Int16)) : Bytes
      # volume == 1.0 (the overwhelmingly common case) needs no scaling
      # at all - queue a zero-copy reinterpret of the input directly.
      # Safe because SDL_PutAudioStreamData (AudioStream#queue) copies
      # the bytes out synchronously before returning.
      if @volume >= 1.0 && !muted?
        return Bytes.new(samples.to_unsafe.as(UInt8*), samples.size * 2)
      end

      buffer = scratch_buffer(samples.size)
      if muted?
        buffer.fill(0_i16)
      else
        samples.each_with_index { |sample, i| buffer[i] = (sample * @volume).to_i16 }
      end
      Bytes.new(buffer.to_unsafe.as(UInt8*), buffer.size * 2)
    end

    # Reused scratch buffer (grown to the largest frame seen) to avoid
    # a per-frame allocation.
    private def scratch_buffer(sample_count : Int32) : Slice(Int16)
      current = @scratch
      return current if current.size == sample_count

      buffer = Slice(Int16).new(sample_count)
      @scratch = buffer
      buffer
    end
  end
end
