require "../spec_helper"

private FILL_ROM = File.join(__DIR__, "..", "fixtures", "fill.gba")

describe Gemba::Probe do
  it "boots a ROM headless and reports its title/size" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.title.should eq "FILL"
    probe.width.should eq 240
    probe.height.should eq 160
    probe.close
  end

  it "#step advances frames and #pixel reads the resulting frame" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.step(6)
    probe.frames_run.should eq 6
    probe.pixel(0, 0).should eq({255_u8, 0_u8, 0_u8})
    probe.pixel(120, 80).should eq({255_u8, 0_u8, 0_u8})
    probe.black?(0, 0).should be_false
    probe.close
  end

  it "#pixel raises before any #step has run" do
    probe = Gemba::Probe.new(FILL_ROM)
    expect_raises(Exception, /no frame yet/) { probe.pixel(0, 0) }
    probe.close
  end

  it "#pixel raises on off-screen coordinates" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.step
    expect_raises(ArgumentError, /off-screen/) { probe.pixel(240, 0) }
    expect_raises(ArgumentError, /off-screen/) { probe.pixel(0, 160) }
    expect_raises(ArgumentError, /off-screen/) { probe.pixel(-1, 0) }
    probe.close
  end

  it "#step accepts a Button, several OR'd together, or a raw bitmask" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.step(2, keys: Gemba::Button::Right)
    probe.step(2, keys: Gemba::Button::A | Gemba::Button::B)
    probe.step(2, keys: Gemba::Button::Start)
    probe.step(2)
    probe.frames_run.should eq 8
    probe.close
  end

  it "#lit_pixels counts every non-black pixel on a full-red-screen ROM" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.step
    probe.lit_pixels.should eq 240 * 160
    probe.close
  end

  it "#changed_pixels is 0 before two frames, and 0 once the screen settles" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.changed_pixels.should eq 0
    probe.step
    probe.changed_pixels.should eq 0 # first frame, no prior to compare

    # fill.gba's frame 1 is mid-init; step past it to reach steady state.
    probe.step(2)
    probe.step
    probe.changed_pixels.should eq 0
    probe.close
  end

  it "#audio_energy is 0.0 before any #step" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.audio_energy.should eq 0.0
    probe.silent?.should be_true
    probe.close
  end

  it "#snapshot summarizes frame/size/title/pixels/audio in one Hash" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.step(3)
    snap = probe.snapshot
    snap[:frame].should eq 3
    snap[:width].should eq 240
    snap[:height].should eq 160
    snap[:title].should eq "FILL"
    snap[:lit_pixels].should eq 240 * 160
    probe.close
  end

  it "#close is idempotent and #closed? reflects it" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.closed?.should be_false
    probe.close
    probe.closed?.should be_true
    probe.close # no raise
  end

  it "raises once closed" do
    probe = Gemba::Probe.new(FILL_ROM)
    probe.close
    expect_raises(Exception, /closed/) { probe.step }
    expect_raises(Exception, /closed/) { probe.read8(0) }
  end

  it "raises ArgumentError for a ROM that doesn't exist" do
    expect_raises(ArgumentError) { Gemba::Probe.new("/nonexistent/path.gba") }
  end
end
