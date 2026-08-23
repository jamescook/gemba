require "./core"
require "./button"

module Gemba
  # A headless, dev-only probe over a GBA ROM - wraps a Core and hands
  # back plain Crystal data (pixels as {r, g, b}, memory as integers,
  # audio as an energy number, a whole-frame #snapshot) so a test can
  # see exactly what a frame contains with no UI in the way. Translated
  # straight from ruby-gba/gemba-core's own GembaCore::Probe.
  #
  # ```
  # probe = Gemba::Probe.new("game.gba")
  # probe.step(6)        # advance 6 frames
  # probe.pixel(120, 80) # => {255_u8, 0_u8, 0_u8}
  # probe.snapshot       # => {frame: 6, width: 240, ...}
  # probe.close
  # ```
  class Probe
    # Native pixels are 4 bytes each: byte 0 red, 1 green, 2 blue, 3
    # unused padding (mGBA's XBGR8 color_t, little-endian) - matches
    # Core#video_buffer's own Slice(UInt32) layout exactly.
    BYTES_PER_PIXEL = 4

    getter width : Int32
    getter height : Int32
    getter frames_run : Int32

    def initialize(rom_path : String)
      @core = Core.new(rom_path)
      @width = @core.width
      @height = @core.height
      @frames_run = 0
      @pixels = Slice(UInt32).empty
      @prev_pixels = Slice(UInt32).empty
      @last_audio = Slice(Int16).empty
    end

    # Advances the emulation by `n` frames, holding `keys` for each.
    # keys: a Button, or several OR'd together (Button::A | Button::B),
    # a raw bitmask Int, or nil for no input.
    def step(n : Int32 = 1, keys : (Button | Int32)? = nil) : self
      ensure_open!
      mask = keys_mask(keys)
      audio = [] of Int16
      n.times do
        @core.keys = mask
        @core.run_frame
        audio.concat(@core.audio_buffer.to_a)
        @frames_run += 1
      end
      @last_audio = Slice(Int16).new(audio.to_unsafe, audio.size)
      @prev_pixels = @pixels
      @pixels = @core.video_buffer.dup
      self
    end

    # The colour at (x, y) on the current frame as {red, green, blue},
    # each 0..255. Raises until at least one #step has run.
    def pixel(x : Int32, y : Int32) : {UInt8, UInt8, UInt8}
      px = pixels!
      validate_coords!(x, y)
      word = px[(y * @width) + x]
      bytes = pointerof(word).as(UInt8*)
      {bytes[0], bytes[1], bytes[2]}
    end

    def black?(x : Int32, y : Int32) : Bool
      pixel(x, y) == {0_u8, 0_u8, 0_u8}
    end

    def read8(address : UInt32) : UInt8
      ensure_open!
      @core.bus_read8(address)
    end

    def read16(address : UInt32) : UInt16
      ensure_open!
      @core.bus_read16(address)
    end

    def read32(address : UInt32) : UInt32
      ensure_open!
      @core.bus_read32(address)
    end

    # A rough loudness of the audio drained during the last #step: mean
    # square of the 16-bit samples (0 when silent) - "did the speaker
    # do anything this step" without decoding the waveform.
    def audio_energy : Float64
      return 0.0 if @last_audio.empty?

      sum = @last_audio.sum { |sample| sample.to_f64 * sample.to_f64 }
      sum / @last_audio.size
    end

    def silent?(threshold : Float64 = 1.0) : Bool
      audio_energy <= threshold
    end

    def lit_pixels : Int32
      pixels!.count { |pixel| pixel != 0_u32 }
    end

    # Number of pixels that changed between the previous frame and the
    # current one. 0 before two frames have run.
    def changed_pixels : Int32
      return 0 if @pixels.empty? || @prev_pixels.empty?

      @pixels.zip(@prev_pixels).count { |(a, b)| a != b }
    end

    # A plain-Hash summary of where the ROM is right now.
    def snapshot : Hash(Symbol, Int32 | String | Float64)
      {
        :frame          => @frames_run,
        :width          => @width,
        :height         => @height,
        :title          => title,
        :lit_pixels     => lit_pixels,
        :changed_pixels => changed_pixels,
        :audio_energy   => audio_energy,
      }
    end

    def title : String
      ensure_open!
      @core.title
    end

    def close : Nil
      @core.destroy unless @core.destroyed?
    end

    def closed? : Bool
      @core.destroyed?
    end

    private def keys_mask(keys : (Button | Int32)?) : UInt32
      case keys
      in Nil    then 0_u32
      in Int32  then keys.to_u32
      in Button then keys.value.to_u32
      end
    end

    private def pixels! : Slice(UInt32)
      raise "no frame yet - call #step before reading pixels" if @pixels.empty?
      @pixels
    end

    private def ensure_open! : Nil
      raise "probe has been closed" if @core.destroyed?
    end

    private def validate_coords!(x : Int32, y : Int32) : Nil
      return if x.in?(0...@width) && y.in?(0...@height)

      raise ArgumentError.new("(#{x}, #{y}) is off-screen (#{@width}x#{@height})")
    end
  end
end
