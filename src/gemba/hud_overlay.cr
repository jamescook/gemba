require "tryst-sdl"

module Gemba
  # The FPS counter (top-right), fast-forward/turbo indicator
  # (top-left) and the recording indicator dots (green while inputs are
  # being recorded to a .gir; the .grec video recorder's red one will
  # join it), drawn directly over the game frame with no background
  # box.
  #
  # White text through an inverse blend: wherever a text pixel is
  # opaque, the destination colour gets INVERTED rather than blended,
  # which keeps a small persistent corner label readable over any game
  # content without a background box.
  class HudOverlay
    INVERSE_BLEND = Tryst::SDL::BlendMode.compose(
      Tryst::SDL::BlendFactor::OneMinusDstColor, Tryst::SDL::BlendFactor::OneMinusSrcAlpha,
      Tryst::SDL::BlendOperation::Add,
      Tryst::SDL::BlendFactor::Zero, Tryst::SDL::BlendFactor::One, Tryst::SDL::BlendOperation::Add)

    @fps_texture : Tryst::SDL::Texture?
    @ff_texture : Tryst::SDL::Texture?
    @crop_h : Int32

    def initialize(@renderer : Tryst::SDL::Renderer, @font : Tryst::SDL::Font)
      ascent = @font.ascent
      full_h = @font.measure("p")[1]
      @crop_h = {ascent + (full_h - ascent) // 2, full_h - 1}.min
    end

    def fps_visible? : Bool
      !@fps_texture.nil?
    end

    def ff_visible? : Bool
      !@ff_texture.nil?
    end

    # Pass nil to hide.
    def fps=(text : String?) : Nil
      @fps_texture.try(&.destroy)
      @fps_texture = text ? build_texture(text) : nil
    end

    # Pass nil to hide.
    def ff_label=(text : String?) : Nil
      @ff_texture.try(&.destroy)
      @ff_texture = text ? build_texture(text) : nil
    end

    # Same geometry as ruby gemba's draw_filled_circle call sites: dot
    # centers at dest + (12, 12), radius 5, the video-recording red one
    # first and the input-recording green one shifted right of it when
    # both are on. Opaque rather than ruby's alpha-200 - close enough
    # visually, and it keeps the renderer's blend-mode state untouched.
    INPUT_RECORD_COLOR = Tryst::SDL::Color.new(30, 180, 30)
    DOT_RADIUS         =  5
    DOT_INSET          = 12

    # FF label inset top-left of `dest`; FPS inset top-right; recording
    # dots top-left too (ruby overlaps them with the FF label the same
    # way - rare, and the inverse-blend text stays readable over a dot).
    def draw(dest : Tryst::SDL::Rect, show_fps : Bool = true, show_ff : Bool = false,
             show_input_record : Bool = false) : Nil
      if show_ff && (ff = @ff_texture)
        copy_cropped(ff, dest.x + 4, dest.y + 4)
      end

      if show_fps && (fps = @fps_texture)
        copy_cropped(fps, dest.x + dest.w - fps.width - 6, dest.y + 4)
      end

      if show_input_record
        draw_filled_circle(dest.x + DOT_INSET, dest.y + DOT_INSET, DOT_RADIUS, INPUT_RECORD_COLOR)
      end
    end

    def destroy : Nil
      self.fps = nil
      self.ff_label = nil
    end

    # Scanline fill, one 1px-tall rect per row - the same technique
    # ruby's own draw_filled_circle uses, and all the renderer's
    # rect/line primitives need.
    private def draw_filled_circle(cx : Number, cy : Number, radius : Int32, color : Tryst::SDL::Color) : Nil
      (-radius..radius).each do |offset_y|
        span = Math.sqrt((radius * radius - offset_y * offset_y).to_f).to_i
        @renderer.fill_rect(cx - span, cy + offset_y, span * 2 + 1, 1, color: color)
      end
    end

    private def build_texture(text : String) : Tryst::SDL::Texture
      texture = @font.render_text(text, Tryst::SDL::Color::WHITE)
      texture.blend_mode = INVERSE_BLEND
      texture
    end

    # Crop to ascent + partial descender to avoid alpha-fringe
    # artifacts under inverse blend.
    private def copy_cropped(texture : Tryst::SDL::Texture, x : Number, y : Number) : Nil
      @renderer.copy(texture,
        src: Tryst::SDL::Rect.new(0, 0, texture.width, @crop_h),
        dest: Tryst::SDL::Rect.new(x, y, texture.width, @crop_h))
    end
  end
end
