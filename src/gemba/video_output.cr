require "tryst-sdl"
require "./frame_painter"
require "./toast_overlay"
require "./hud_overlay"

module Gemba
  # The video half of the EmulatorFrame equivalent: a streaming texture
  # at the platform's native resolution, drawn scaled
  # into a Tryst::SDL::Viewport with optional integer-scaling/aspect
  # lock and nearest-vs-bilinear filtering. Color correction and frame
  # blending are FramePainter's job (see its own doc comment for why
  # that isn't Core's).
  #
  # Owns the Viewport (and therefore the Tk frame it lives in) - a
  # caller wanting fullscreen toggles the WINDOW's own -fullscreen
  # attribute instead (see MainWindow), since that's a toplevel concern,
  # not a viewport one.
  class VideoOutput
    getter viewport : Tryst::SDL::Viewport
    getter painter : FramePainter
    getter native_width : Int32
    getter native_height : Int32

    @last_frame_argb : Bytes?

    property? integer_scale : Bool = true
    property? keep_aspect_ratio : Bool = true

    # Whether the FPS counter draws at all - a persisted user preference
    # (Config#show_fps?), unlike show_ff below which tracks turbo state
    # itself rather than a preference.
    getter? show_fps : Bool = true

    # Whether the input-recording indicator (HudOverlay's green dot,
    # top-left) draws - set by EmulatorFrame while a .gir recording is
    # confirmed running. A plain property rather than a per-#draw
    # argument (the way show_ff is passed) so #redraw reproduces it
    # unchanged with no caller involvement.
    property? input_recording_dot : Bool = false

    # The .grec video-recording indicator (red dot) - same arrangement.
    property? recording_dot : Bool = false

    # The same font every toast/HUD overlay in this port draws with -
    # bundled at gemba/assets, same file ruby gemba ships (JetBrains Mono,
    # SIL OFL - freely redistributable).
    FONT_PATH = File.expand_path("../../assets/JetBrainsMonoNL-Regular.ttf", __DIR__)

    @texture : Tryst::SDL::Texture
    @font : Tryst::SDL::Font
    @toast : ToastOverlay
    @hud : HudOverlay

    # Whether the LAST #draw/#present was told turbo was engaged -
    # remembered so #redraw (no new frame data) can reproduce it rather
    # than silently dropping the indicator.
    @show_ff = false
    @destroyed = false

    def initialize(app : Tryst::App, parent : String? = nil,
                   native_width : Int32 = 240, native_height : Int32 = 160, scale : Int32 = 3)
      @native_width = native_width
      @native_height = native_height
      @painter = FramePainter.new
      @viewport = Tryst::SDL::Viewport.new(app, parent: parent,
        width: native_width * scale, height: native_height * scale, vsync: false)
      @texture = @viewport.renderer.create_texture(native_width, native_height,
        Tryst::SDL::Texture::Access::Streaming)
      @font = @viewport.renderer.load_font(FONT_PATH, 14)
      @toast = ToastOverlay.new(@viewport.renderer, @font)
      @hud = HudOverlay.new(@viewport.renderer, @font)
      self.filter = :nearest
    end

    # Shows a transient (or, with permanent: true, persistent) message
    # centered at the bottom of the video area - what a "Paused" badge or
    # a "State saved" notification draws through.
    def show_toast(message : String, duration : Float64? = nil, permanent : Bool = false) : Nil
      @toast.show(message, duration: duration, permanent: permanent)
    end

    def hide_toast : Nil
      @toast.hide
    end

    # false hides the counter outright, no matter what text was last
    # set - true doesn't immediately show one, since the text itself
    # only refreshes once every EmulatorFrame::FPS_INTERVAL.
    def show_fps=(enabled : Bool) : Bool
      @show_fps = enabled
      hide_fps_text unless enabled
      enabled
    end

    # Sets the FPS counter's text (top-right). Callers only need this
    # while #show_fps? is true.
    def show_fps_text(text : String) : Nil
      @hud.fps = text
    end

    def hide_fps_text : Nil
      @hud.fps = nil
    end

    def show_ff_label(text : String) : Nil
      @hud.ff_label = text
    end

    def hide_ff_label : Nil
      @hud.ff_label = nil
    end

    # :nearest for crisp pixel art (the default - what a GBA's own
    # pixels look like), :linear to soften it.
    def filter=(mode : Symbol) : Symbol
      case mode
      when :nearest then @texture.scale_mode = Tryst::SDL::ScaleMode::Nearest
      when :linear  then @texture.scale_mode = Tryst::SDL::ScaleMode::Linear
      else
        raise ArgumentError.new("filter must be :nearest or :linear, got #{mode.inspect}")
      end
      mode
    end

    # The last frame #draw actually painted (post color-correction/
    # frame-blending), ARGB8888 bytes ready for a Tk photo image - what a
    # screenshot or a save-state thumbnail should show, matching ruby
    # gemba's own screenshot path (which reads through the same
    # effects-aware Core#video_buffer_argb the live display uses, not a
    # separately-computed raw frame). nil until the first #draw.
    #
    # A fresh copy every call, not the live buffer FramePainter#paint
    # mutates in place each frame - #take_screenshot holds onto this
    # across an #off_thread hop, a real yield point another frame can
    # land during.
    def last_frame_argb : Bytes?
      @last_frame_argb.try(&.dup)
    end

    def color_correction=(enabled : Bool) : Bool
      @painter.color_correction = enabled
    end

    def color_correction? : Bool
      @painter.color_correction?
    end

    def frame_blending=(enabled : Bool) : Bool
      @painter.frame_blending = enabled
    end

    def frame_blending? : Bool
      @painter.frame_blending?
    end

    # Call when a new ROM loads: drops frame_blending's stale previous
    # frame, and rebuilds the texture if this platform's resolution
    # differs from what's currently allocated (GB/GBC vs GBA).
    def reset!(width : Int32, height : Int32) : Nil
      @painter.reset!
      return if width == @native_width && height == @native_height

      @native_width = width
      @native_height = height
      old_texture = @texture
      @texture = @viewport.renderer.create_texture(width, height, Tryst::SDL::Texture::Access::Streaming)
      old_texture.destroy
    end

    # Paints, uploads and draws one frame, scaled/letterboxed per
    # #integer_scale?/#keep_aspect_ratio?, then presents it to the
    # screen. #draw is the same thing minus the final present - split
    # out so a test can inspect what got drawn via #read_pixels: SDL
    # double-buffers, so reading back AFTER a present sees the other
    # (not-yet-drawn-into) buffer rather than what was just shown,
    # confirmed directly against this renderer's own real backend.
    def present(video : Slice(UInt32), show_ff : Bool = false) : Nil
      draw(video, show_ff: show_ff)
      present
    end

    # Flips whatever #draw/#redraw last painted into the back buffer to
    # the screen, with no new painting of its own - the second half of
    # #present(video), split out so #redraw (which paints but does not
    # present - see its own doc comment on why) can share it.
    def present : Nil
      @viewport.renderer.present
    end

    def draw(video : Slice(UInt32), show_ff : Bool = false) : Nil
      @show_ff = show_ff
      bytes = @painter.paint(video)
      @last_frame_argb = bytes
      @texture.update(bytes)
      dest = dest_rect

      renderer = @viewport.renderer
      renderer.clear(Tryst::SDL::Color::BLACK)
      renderer.copy(@texture, dest: dest)
      @hud.draw(dest, show_fps: show_fps?, show_ff: @show_ff,
        show_input_record: input_recording_dot?, show_record: recording_dot?)
      @toast.draw(dest)
    end

    # Re-paints the last frame #draw painted, with no new emulation data -
    # for when only an overlay (the pause toast) changed and nothing new
    # has arrived from the core, e.g. right after
    # #show_toast(permanent: true) while paused: the emulation loop (and
    # so #draw/#present themselves) does not run again until resumed, so
    # without this the toast would never actually reach the screen.
    # A no-op before the first #draw - nothing painted yet to re-show.
    #
    # Deliberately does NOT #present, mirroring #draw - callers that need
    # this to actually reach the screen call #present afterward. Kept
    # separate so a test can #read_pixels right after #redraw: reading
    # back right after a real #present is unreliable, since SDL
    # double-buffers and a read-back racing the swap can see the OTHER,
    # not-yet-drawn-into buffer (confirmed directly, see #draw's own
    # comment for the same caveat).
    def redraw : Nil
      bytes = @last_frame_argb
      return unless bytes

      dest = dest_rect
      renderer = @viewport.renderer
      @texture.update(bytes)
      renderer.clear(Tryst::SDL::Color::BLACK)
      renderer.copy(@texture, dest: dest)
      @hud.draw(dest, show_fps: show_fps?, show_ff: @show_ff,
        show_input_record: input_recording_dot?, show_record: recording_dot?)
      @toast.draw(dest)
    end

    # Idempotent. Also fine to call after Tk has already destroyed the
    # viewport's frame (a root-window destroy does): the Viewport
    # releases its SDL window on its own then, and SDL frees a
    # renderer's textures/fonts with the renderer - this just settles
    # the Crystal-side state.
    def destroy : Nil
      return if @destroyed
      @destroyed = true

      @hud.destroy
      @toast.destroy
      @font.destroy
      @texture.destroy
      @viewport.destroy
    end

    def destroyed? : Bool
      @destroyed
    end

    private def dest_rect : Tryst::SDL::Rect
      out_w = @viewport.width
      out_h = @viewport.height
      return Tryst::SDL::Rect.new(0, 0, out_w, out_h) unless keep_aspect_ratio?

      scale = [out_w.to_f64 / @native_width, out_h.to_f64 / @native_height].min
      scale = scale.floor if integer_scale? && scale >= 1.0

      dest_w = (@native_width * scale).to_i
      dest_h = (@native_height * scale).to_i
      Tryst::SDL::Rect.new((out_w - dest_w) // 2, (out_h - dest_h) // 2, dest_w, dest_h)
    end
  end
end
