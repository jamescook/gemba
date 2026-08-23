require "tryst-sdl"

module Gemba
  # The FPS counter (top-right) and fast-forward/turbo indicator
  # (top-left), drawn directly over the game frame with no background
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

    # FF label inset top-left of `dest`; FPS inset top-right.
    def draw(dest : Tryst::SDL::Rect, show_fps : Bool = true, show_ff : Bool = false) : Nil
      if show_ff && (ff = @ff_texture)
        copy_cropped(ff, dest.x + 4, dest.y + 4)
      end

      if show_fps && (fps = @fps_texture)
        copy_cropped(fps, dest.x + dest.w - fps.width - 6, dest.y + 4)
      end
    end

    def destroy : Nil
      self.fps = nil
      self.ff_label = nil
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
