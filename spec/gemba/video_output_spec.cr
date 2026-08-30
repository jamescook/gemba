require "../spec_helper"

# True if any pixel in the top-right corner (where HudOverlay draws the
# FPS counter) differs from a flat `background` gray - cheap, position-
# independent way to confirm something actually drew there without
# having to know an exact glyph pixel.
private def top_right_changed?(output : Gemba::VideoOutput, background : UInt8) : Bool
  output.viewport.renderer.read_pixels do |pixels|
    (4...30).each do |y|
      (pixels.width - 100...pixels.width - 4).each do |x|
        c = pixels[x, y]
        return true if c.r != background || c.g != background || c.b != background
      end
    end
  end
  false
end

describe Gemba::VideoOutput do
  it "presents a frame and scales it into the viewport, integer-scaled and centered" do
    app = Tryst::App.new(title: "video_output_spec_1")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 3)

    red = 0x000000FF_u32 # XBGR8: byte0 red=0xFF, rest 0
    video = Slice(UInt32).new(240 * 160, red)
    # #draw, not #present: SDL double-buffers, so reading back AFTER a
    # present sees the other (not-yet-drawn-into) buffer rather than
    # what was just shown - see VideoOutput#draw's own doc comment.
    output.draw(video)

    output.viewport.renderer.read_pixels do |pixels|
      got = pixels[(pixels.width * 0.5).to_i, (pixels.height * 0.5).to_i]
      got.r.should be > 200
      got.g.should be < 60
    end

    output.destroy
    app.destroy
  end

  it "#filter rejects anything other than :nearest/:linear" do
    app = Tryst::App.new(title: "video_output_spec_2")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 1)

    expect_raises(ArgumentError, /nearest.*linear/) { output.filter = :bilinear }

    output.destroy
    app.destroy
  end

  it "#color_correction=/#frame_blending= toggle FramePainter's own flags" do
    app = Tryst::App.new(title: "video_output_spec_3")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 1)

    output.color_correction?.should be_false
    output.color_correction = true
    output.color_correction?.should be_true

    output.frame_blending?.should be_false
    output.frame_blending = true
    output.frame_blending?.should be_true

    output.destroy
    app.destroy
  end

  it "#show_toast draws over the frame after #redraw, #hide_toast removes it" do
    app = Tryst::App.new(title: "video_output_spec_5")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 3)

    red = 0x000000FF_u32 # XBGR8: byte0 red=0xFF, rest 0
    video = Slice(UInt32).new(240 * 160, red)
    output.draw(video)

    # Bottom-center, where ToastOverlay positions its box - bright red
    # before any toast is showing.
    output.viewport.renderer.read_pixels do |pixels|
      before = pixels[(pixels.width * 0.5).to_i, pixels.height - 20]
      before.r.should be > 200
    end

    output.show_toast("Paused", permanent: true)
    output.redraw # not #present - see #redraw's own doc comment on why

    # The toast's box is translucent (ToastOverlay::FILL's alpha), not
    # fully opaque - it should visibly darken the red behind it without
    # blacking it out completely. Pins the actual bug this spec caught:
    # ToastOverlay#draw originally never set the renderer's draw blend
    # mode, so FILL's alpha was silently ignored (SDL_SetRenderDrawColor's
    # alpha is a no-op without it) and the box drew fully opaque instead.
    # A wide-but-bounded range rather than an exact value: this is a
    # visual effect, not a value this test should pin to the pixel.
    output.viewport.renderer.read_pixels do |pixels|
      during = pixels[(pixels.width * 0.5).to_i, pixels.height - 20]
      during.r.should be > 100
      during.r.should be < 220
    end

    output.hide_toast
    output.redraw

    output.viewport.renderer.read_pixels do |pixels|
      after = pixels[(pixels.width * 0.5).to_i, pixels.height - 20]
      after.r.should be > 200
    end

    output.destroy
    app.destroy
  end

  it "#show_fps_text draws after #redraw, #hide_fps_text removes it" do
    app = Tryst::App.new(title: "video_output_spec_7")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 3)

    gray = 0x00646464_u32 # r=g=b=100
    video = Slice(UInt32).new(240 * 160, gray)
    output.draw(video)
    top_right_changed?(output, 100_u8).should be_false

    output.show_fps_text("60.0 fps")
    output.redraw
    top_right_changed?(output, 100_u8).should be_true

    output.hide_fps_text
    output.redraw
    top_right_changed?(output, 100_u8).should be_false

    output.destroy
    app.destroy
  end

  it "#show_fps= false hides the counter even if #show_fps_text was already called" do
    app = Tryst::App.new(title: "video_output_spec_8")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 3)

    gray = 0x00646464_u32
    video = Slice(UInt32).new(240 * 160, gray)
    output.draw(video)
    output.show_fps_text("60.0 fps")
    output.redraw
    top_right_changed?(output, 100_u8).should be_true

    output.show_fps = false
    output.redraw
    top_right_changed?(output, 100_u8).should be_false

    output.destroy
    app.destroy
  end

  it "#show_ff_label draws top-left after #redraw, #hide_ff_label removes it" do
    app = Tryst::App.new(title: "video_output_spec_9")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 3)

    gray = 0x00646464_u32
    video = Slice(UInt32).new(240 * 160, gray)
    # show_ff: true, matching how EmulatorFrame actually calls this while
    # turbo is engaged (VideoOutput#present(video, show_ff: @turbo)) - a
    # label with no show_ff draws nothing, by design (see HudOverlay#draw).
    output.draw(video, show_ff: true)

    output.viewport.renderer.read_pixels do |pixels|
      before = pixels[10, 10]
      before.r.should eq 100
    end

    output.show_ff_label(">> MAX")
    output.redraw

    changed = false
    output.viewport.renderer.read_pixels do |pixels|
      (4...30).each do |y|
        (4...100).each do |x|
          c = pixels[x, y]
          changed = true if c.r != 100 || c.g != 100 || c.b != 100
        end
      end
    end
    changed.should be_true

    output.hide_ff_label
    output.redraw
    output.viewport.renderer.read_pixels do |pixels|
      after = pixels[10, 10]
      after.r.should eq 100
    end

    output.destroy
    app.destroy
  end

  # FramePainter#paint reuses (mutates in place) its output buffer every
  # call for performance - #last_frame_argb must not hand that live
  # buffer straight to a caller that might still be holding it (a
  # screenshot, a save-state thumbnail) when the NEXT frame overwrites
  # it. Pins the actual fix: a snapshot taken after the first #draw must
  # still show that frame's colors after a second, different #draw.
  it "#last_frame_argb returns a snapshot a later #draw can't mutate out from under it" do
    app = Tryst::App.new(title: "video_output_spec_10")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 1)

    red = 0x000000FF_u32  # XBGR8: byte0 red=0xFF, rest 0
    blue = 0x00FF0000_u32 # XBGR8: byte2 blue=0xFF, rest 0

    output.draw(Slice(UInt32).new(240 * 160, red))
    snapshot = output.last_frame_argb
    raise "expected a snapshot after #draw" unless snapshot
    # ARGB8888 bytes: 0 blue, 1 green, 2 red, 3 alpha (see FramePainter#paint).
    snapshot[0].should eq 0_u8
    snapshot[2].should eq 0xFF_u8

    output.draw(Slice(UInt32).new(240 * 160, blue))

    snapshot[0].should eq 0_u8
    snapshot[2].should eq 0xFF_u8

    fresh = output.last_frame_argb
    raise "expected a fresh snapshot after the second #draw" unless fresh
    fresh[0].should eq 0xFF_u8
    fresh[2].should eq 0_u8

    output.destroy
    app.destroy
  end

  it "#redraw before any #draw is a no-op" do
    app = Tryst::App.new(title: "video_output_spec_6")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 1)

    output.redraw # would raise if it touched a never-drawn texture/renderer state

    output.destroy
    app.destroy
  end

  it "#reset! rebuilds the texture when the resolution changes" do
    app = Tryst::App.new(title: "video_output_spec_4")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 1)

    video = Slice(UInt32).new(160 * 144, 0_u32)
    output.reset!(160, 144)
    output.present(video) # would raise if the texture were still 240x160

    output.destroy
    app.destroy
  end

  # The root going away (every MainWindow spec's teardown, and closing
  # the app) takes the viewport's frame with it; tryst-sdl's Viewport
  # releases its SDL window on its own then. #destroy afterwards is the
  # order every caller that never got round to it ends up in, so it has
  # to be a clean no-op, not a raise.
  it "#destroy after the root window has already gone is a no-op" do
    app = Tryst::App.new(title: "video_output_spec_5")
    app.show
    output = Gemba::VideoOutput.new(app, native_width: 240, native_height: 160, scale: 1)

    app.destroy
    output.viewport.destroyed?.should be_true

    output.destroy
    output.destroy # idempotent
    output.destroyed?.should be_true
  end
end
