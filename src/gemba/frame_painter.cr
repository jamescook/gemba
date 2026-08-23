module Gemba
  # Converts mGBA's native video buffer to bytes Tryst::SDL::Texture#update
  # accepts, with two optional pixel-level effects (color_correction,
  # frame_blending). Not part of Gemba::Core: both effects operate purely
  # on the XBGR buffer Core#video_buffer already hands out and run on the
  # main thread, needing no cross-thread signaling to EmulationWorker.
  #
  # color_correction ports gemba_core_ext.c's Pokefan531/Color Mangler LUT
  # (gamma + channel-crosstalk correction approximating the GBA LCD's real
  # look) verbatim; frame_blending ports its 50/50 blend-with-previous-frame
  # (the classic GBA LCD ghosting effect games were designed around).
  class FramePainter
    # mGBA's color_t (mCOLOR_XBGR8): byte 0 red, 1 green, 2 blue, 3 unused
    # padding. SDL_PIXELFORMAT_ARGB8888 wants, in memory on a little-endian
    # machine, byte 0 blue, 1 green, 2 red, 3 alpha - the swap below.
    TARGET_GAMMA  =  2.2
    DARKEN_SCREEN =  1.0
    DISPLAY_GAMMA =  2.2
    LUM           = 0.94
    INPUT_GAMMA   = TARGET_GAMMA + DARKEN_SCREEN

    property? color_correction : Bool = false
    property? frame_blending : Bool = false

    @lut : Slice(UInt32)?
    @prev_frame : Slice(UInt32)?
    @out : Bytes?

    # Converts one frame of XBGR8888 pixels (Core#video_buffer's own
    # layout) into ARGB8888 bytes, applying whichever effects are
    # currently enabled. The returned Bytes is a reusable buffer (see
    # #output_buffer) mutated in place every call - safe for
    # Texture#update (which copies synchronously) but NOT safe to hold
    # past the next #paint call.
    def paint(xbgr : Slice(UInt32)) : Bytes
      lut = color_correction? ? lut_table : nil
      prev = frame_blending? ? prev_frame(xbgr.size) : nil
      out = output_buffer(xbgr.size)

      xbgr.each_with_index do |native, index|
        argb = 0xFF000000_u32 | ((native & 0xFF) << 16) | (native & 0xFF00) | ((native & 0xFF0000) >> 16)
        argb = lut[lut_index(argb)] if lut

        if prev
          blended = ((argb & 0xFEFEFEFE_u32) >> 1) + ((prev[index] & 0xFEFEFEFE_u32) >> 1) +
                    (argb & prev[index] & 0x01010101_u32)
          prev[index] = argb
          argb = blended
        end

        offset = index * 4
        out[offset] = (argb & 0xFF).to_u8
        out[offset + 1] = ((argb >> 8) & 0xFF).to_u8
        out[offset + 2] = ((argb >> 16) & 0xFF).to_u8
        out[offset + 3] = ((argb >> 24) & 0xFF).to_u8
      end

      out
    end

    # Drops the previous-frame buffer frame_blending mixes against - call
    # after loading a new ROM (or a save state) so the first frame doesn't
    # blend against a stale frame from before it. The color-correction LUT
    # is left alone: it depends only on gamma constants, not ROM state.
    def reset! : Nil
      @prev_frame = nil
    end

    private def prev_frame(size : Int32) : Slice(UInt32)
      current = @prev_frame
      return current if current && current.size == size

      # Zero-initialized, matching gemba-core's own calloc'd prev_frame -
      # the very first blended frame mixes against black, not the frame
      # itself.
      buffer = Slice(UInt32).new(size, 0_u32)
      @prev_frame = buffer
      buffer
    end

    # Reallocates only when pixel_count changes (a resolution switch,
    # e.g. GB/GBC vs GBA) - same reuse-unless-resized idiom as #prev_frame
    # above.
    private def output_buffer(pixel_count : Int32) : Bytes
      needed = pixel_count * 4
      current = @out
      return current if current && current.size == needed

      buffer = Bytes.new(needed)
      @out = buffer
      buffer
    end

    private def lut_index(argb : UInt32) : Int32
      r5 = ((argb >> 16) & 0xFF) >> 3
      g5 = ((argb >> 8) & 0xFF) >> 3
      b5 = (argb & 0xFF) >> 3
      ((r5 << 10) | (g5 << 5) | b5).to_i32
    end

    private def lut_table : Slice(UInt32)
      @lut ||= build_lut
    end

    # The GBA LCD has a non-standard gamma (~3.2) and channel cross-talk;
    # games were designed with exaggerated colors to compensate. This LUT
    # maps raw ARGB8888 (quantized to 5 bits per channel, since the GBA
    # only ever outputs 15-bit RGB555) to corrected values approximating
    # the original LCD's appearance. 32x32x32 entries, built once and
    # cached (a 128KB table, same size and one-time cost as the C ext's
    # own static array).
    #
    # Reference: libretro gba-color.glsl (public domain), matching
    # gemba-core's own build_gba_color_lut exactly (Pokefan531 mixing
    # matrix).
    private def build_lut : Slice(UInt32)
      lut = Slice(UInt32).new(32 * 32 * 32)

      32.times do |red_index|
        32.times do |green_index|
          32.times do |blue_index|
            r = ((red_index / 31.0) ** INPUT_GAMMA * LUM).clamp(0.0, 1.0)
            g = ((green_index / 31.0) ** INPUT_GAMMA * LUM).clamp(0.0, 1.0)
            b = ((blue_index / 31.0) ** INPUT_GAMMA * LUM).clamp(0.0, 1.0)

            nr = (0.82 * r + 0.125 * g + 0.195 * b).clamp(0.0, 1.0)
            ng = (0.24 * r + 0.665 * g + 0.075 * b).clamp(0.0, 1.0)
            nb = (-0.06 * r + 0.21 * g + 0.73 * b).clamp(0.0, 1.0)

            # Float#to_u8 overflows on some fractional values just under
            # 256.0 (a Crystal boundary quirk, confirmed directly:
            # 255.4.to_u8 raises but 255.4.to_i.to_u8 doesn't) - going
            # through Int32 first avoids it.
            or8 = (nr ** (1.0 / DISPLAY_GAMMA) * 255.0 + 0.5).to_i.clamp(0, 255).to_u8
            og8 = (ng ** (1.0 / DISPLAY_GAMMA) * 255.0 + 0.5).to_i.clamp(0, 255).to_u8
            ob8 = (nb ** (1.0 / DISPLAY_GAMMA) * 255.0 + 0.5).to_i.clamp(0, 255).to_u8

            lut[(red_index << 10) | (green_index << 5) | blue_index] =
              0xFF000000_u32 | (or8.to_u32 << 16) | (og8.to_u32 << 8) | ob8.to_u32
          end
        end
      end

      lut
    end
  end
end
