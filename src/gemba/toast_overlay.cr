require "tryst-sdl"

module Gemba
  # A transient (or permanent, e.g. "Paused") on-screen text notification,
  # drawn centered at the bottom of the video area - ported from ruby
  # gemba's own lib/gemba/toast_overlay.rb.
  #
  # The rounded-corner background is a pure-Crystal scanline fill (see
  # #draw_rounded_rect) rather than ruby's C-generated anti-aliased
  # bitmap - no C helper in this port, and the corners are NOT
  # anti-aliased (a hard edge between rounded and square, same
  # trade-off gemba's own recording-indicator circles already accept -
  # see draw_filled_circle in ruby's emulator_frame.rb for the identical
  # scanline-fill idea applied to a full circle instead of a rect's
  # corners).
  class ToastOverlay
    PAD_X    = 14
    PAD_Y    =  8
    RADIUS   =  8
    BORDER_W =  2

    # Same near-black-with-a-blue-tint fill and blue-grey border colours
    # ruby's C toast_background generator uses (non-premultiplied, for
    # SDL_BLENDMODE_BLEND) - but NOT the same fill alpha. Confirmed
    # directly (measured actual blended pixels via #read_pixels): ruby's
    # own 180/255 fill alpha blends correctly, but a near-black fill at
    # 70% opacity still reads as solidly opaque over anything but a
    # bright background, since the result stays well under 50 brightness
    # either way. Dropped to 95/255 (~37%) so the game underneath is
    # unambiguously visible through the panel - a deliberate deviation
    # from ruby's literal constant, not a mechanism bug.
    FILL   = Tryst::SDL::Color.new(20, 20, 28, 95)
    BORDER = Tryst::SDL::Color.new(100, 110, 140, 210)

    @text_texture : Tryst::SDL::Texture?
    @box_w = 0
    @box_h = 0
    @permanent = false
    @expires_at : Time::Instant?

    def initialize(@renderer : Tryst::SDL::Renderer, @font : Tryst::SDL::Font, @duration : Float64 = 1.5)
    end

    def visible? : Bool
      !@text_texture.nil?
    end

    # permanent: true keeps it up until #hide is called explicitly -
    # what a "Paused" indicator wants.
    def show(message : String, duration : Float64? = nil, permanent : Bool = false) : Nil
      hide

      texture = @font.render_text(message, Tryst::SDL::Color::WHITE)
      @text_texture = texture
      @box_w = texture.width + PAD_X * 2
      @box_h = texture.height + PAD_Y * 2
      @permanent = permanent
      @expires_at = permanent ? nil : Time.instant + (duration || @duration).seconds
    end

    # Removes the current toast (if any) and frees its texture. Safe to
    # call with nothing showing.
    def hide : Nil
      @text_texture.try(&.destroy)
      @text_texture = nil
    end

    # Draws the toast bottom-center of `dest`, 12px from its bottom edge -
    # a no-op once nothing is showing, or once a non-permanent toast's
    # duration has elapsed (which also clears it).
    def draw(dest : Tryst::SDL::Rect) : Nil
      texture = @text_texture
      return unless texture

      expires = @expires_at
      if !@permanent && expires && Time.instant >= expires
        hide
        return
      end

      box_x = dest.x + (dest.w - @box_w) / 2
      box_y = dest.y + dest.h - 12 - @box_h

      # SDL_SetRenderDrawColor's alpha is a no-op unless the draw blend
      # mode is explicitly set to something that reads it - confirmed
      # directly (SDL's own SDL_SetRenderDrawColor doc: "usually
      # SDL_ALPHA_OPAQUE... use SDL_SetRenderDrawBlendMode to specify how
      # the alpha channel is used"). Without this, the fill's alpha drew
      # as fully opaque instead of translucent.
      @renderer.blend_mode = Tryst::SDL::BlendMode::Blend
      draw_panel(box_x, box_y)
      @renderer.copy(texture, dest: Tryst::SDL::Rect.new(
        box_x + PAD_X, box_y + PAD_Y, texture.width, texture.height))
    end

    def destroy : Nil
      hide
    end

    # Draws the border ring and the fill as non-overlapping segments, one
    # fill_rect per row. NOT "draw a border rect, then a smaller fill
    # rect on top of it": confirmed directly (measured actual blended
    # pixels) that double-composites the fill on top of the border's own
    # already-blended result rather than the raw background underneath -
    # two partial-alpha draws stacked compound into something far more
    # opaque than either alone, which is why an earlier version of this
    # method still looked nearly solid despite FILL's alpha being well
    # under 50%. Every pixel here gets exactly one fill_rect call.
    private def draw_panel(box_x : Number, box_y : Number) : Nil
      (0...@box_h).each do |row|
        outer_inset = corner_inset(row, @box_h, RADIUS)
        outer_left = box_x + outer_inset
        outer_right = box_x + @box_w - outer_inset

        if row < BORDER_W || row >= @box_h - BORDER_W
          # Pure border band - the inner (fill) rect doesn't reach this
          # row at all, so the whole span is the border colour.
          @renderer.fill_rect(outer_left, box_y + row, outer_right - outer_left, 1, BORDER)
          next
        end

        inner_row = row - BORDER_W
        inner_h = @box_h - 2 * BORDER_W
        inner_radius = RADIUS - BORDER_W
        inner_inset = corner_inset(inner_row, inner_h, inner_radius)
        inner_left = box_x + BORDER_W + inner_inset
        inner_right = box_x + @box_w - BORDER_W - inner_inset

        @renderer.fill_rect(outer_left, box_y + row, inner_left - outer_left, 1, BORDER) if inner_left > outer_left
        @renderer.fill_rect(inner_left, box_y + row, inner_right - inner_left, 1, FILL)
        @renderer.fill_rect(inner_right, box_y + row, outer_right - inner_right, 1, BORDER) if outer_right > inner_right
      end
    end

    private def corner_inset(row : Int32, h : Int32, radius : Int32) : Int32
      dy =
        if row < radius
          radius - row - 1
        elsif row >= h - radius
          row - (h - radius)
        end
      return 0 unless dy

      dx = Math.sqrt({radius.to_f64**2 - dy.to_f64**2, 0.0}.max).to_i
      radius - dx
    end
  end
end
