require "../spec_helper"

private def xbgr(r : UInt8, g : UInt8, b : UInt8) : Slice(UInt32)
  Slice(UInt32).new(1) { (b.to_u32 << 16) | (g.to_u32 << 8) | r.to_u32 }
end

describe Gemba::FramePainter do
  it "converts XBGR8888 to ARGB8888 bytes with no effects enabled" do
    painter = Gemba::FramePainter.new
    out = painter.paint(xbgr(10_u8, 20_u8, 30_u8))
    # byte 0 blue, 1 green, 2 red, 3 alpha
    out.should eq Bytes[30_u8, 20_u8, 10_u8, 255_u8]
  end

  it "converts a full frame's worth of pixels in order" do
    painter = Gemba::FramePainter.new
    buffer = Slice(UInt32).new(4) { |i| xbgr(i.to_u8, 0_u8, 0_u8)[0] }
    out = painter.paint(buffer)
    out.size.should eq 16
    out[2].should eq 0_u8
    out[6].should eq 1_u8
    out[10].should eq 2_u8
    out[14].should eq 3_u8
  end

  it "#color_correction= changes the output for a non-edge pixel" do
    plain = Gemba::FramePainter.new.paint(xbgr(128_u8, 96_u8, 64_u8))

    corrected_painter = Gemba::FramePainter.new
    corrected_painter.color_correction = true
    corrected = corrected_painter.paint(xbgr(128_u8, 96_u8, 64_u8))

    corrected.should_not eq plain
  end

  it "#color_correction is deterministic - the cached LUT gives the same answer every call" do
    painter = Gemba::FramePainter.new
    painter.color_correction = true
    first = painter.paint(xbgr(200_u8, 150_u8, 50_u8))
    second = painter.paint(xbgr(200_u8, 150_u8, 50_u8))
    first.should eq second
  end

  it "#frame_blending mixes the first frame against black, then against itself" do
    painter = Gemba::FramePainter.new
    painter.frame_blending = true

    # #paint reuses (mutates in place) the same output buffer every call
    # now - snapshot with .dup before painting again, or this would
    # compare a buffer against itself.
    first = painter.paint(xbgr(200_u8, 200_u8, 200_u8)).dup
    # Blended 50/50 with a black (0) previous frame - roughly half brightness.
    first[2].should be < 150_u8

    second = painter.paint(xbgr(200_u8, 200_u8, 200_u8))
    # Now blending against the (already-blended) previous frame of the
    # same color converges toward full brightness rather than staying dim.
    second[2].should be > first[2]
  end

  it "#reset! drops the previous frame so blending restarts against black" do
    painter = Gemba::FramePainter.new
    painter.frame_blending = true
    painter.paint(xbgr(200_u8, 200_u8, 200_u8))

    painter.reset!
    restarted = painter.paint(xbgr(200_u8, 200_u8, 200_u8))
    restarted[2].should be < 150_u8
  end
end
