require "../spec_helper"

describe Gemba::AudioOutput do
  # spec_helper.cr forces SDL's dummy audio driver so every test runs
  # for real, everywhere, with nothing skipped; allow_silent: true is
  # AudioOutput's own production fallback for a genuinely audio-less
  # machine (see Tryst::SDL::AudioStream#silent?).
  it "constructs without raising, even with no real audio device" do
    output = Gemba::AudioOutput.new
    output.destroy
  end

  it "#fill_ratio is 0.0 before anything is queued" do
    output = Gemba::AudioOutput.new
    output.fill_ratio.should eq 0.0
    output.destroy
  end

  it "#queue raises the fill ratio, #reset! drops it back to 0.0" do
    output = Gemba::AudioOutput.new
    samples = Slice(Int16).new(4410 * 2, 1000_i16) # ~50ms of loud-ish stereo noise
    output.queue(samples)
    output.fill_ratio.should be > 0.0

    output.reset!
    output.fill_ratio.should eq 0.0
    output.destroy
  end

  it "#muted= silences without changing the queued byte count" do
    muted = Gemba::AudioOutput.new
    muted.muted = true
    samples = Slice(Int16).new(4410 * 2, 1000_i16)
    muted.queue(samples)
    muted.fill_ratio.should be > 0.0
    muted.destroy
  end

  it "#volume= clamps to 0.0..1.0" do
    output = Gemba::AudioOutput.new
    output.volume = 1.5
    output.volume.should eq 1.0
    output.volume = -0.5
    output.volume.should eq 0.0
    output.destroy
  end

  it "#queue with an empty slice is a no-op" do
    output = Gemba::AudioOutput.new
    output.queue(Slice(Int16).empty)
    output.fill_ratio.should eq 0.0
    output.destroy
  end

  # #queue's scaled/muted paths reuse one scratch buffer instead of
  # allocating a fresh one every frame - this is the actual perf fix
  # under test. Warms the scratch buffer at this frame size first, then
  # measures a steady run of same-size frames.
  it "#queue allocates nothing at steady frame size, scaled or muted" do
    output = Gemba::AudioOutput.new
    output.volume = 0.5
    samples = Slice(Int16).new(4410 * 2, 1000_i16)

    output.queue(samples) # warm up (first call at this size may allocate)
    GC.collect
    before = GC.stats.total_bytes
    50.times { output.queue(samples) }
    after = GC.stats.total_bytes
    (after - before).should eq 0

    output.muted = true
    output.queue(samples) # warm up the muted path too
    GC.collect
    before_muted = GC.stats.total_bytes
    50.times { output.queue(samples) }
    after_muted = GC.stats.total_bytes
    (after_muted - before_muted).should eq 0

    output.destroy
  end

  # Volume/mute alternating on the SAME AudioOutput (so the same reused
  # scratch buffer is involved every time) shouldn't misbehave or crash -
  # guards against the reused buffer leaking stale content across calls
  # with different settings.
  it "alternating volume/mute on the same instance keeps queueing correctly" do
    output = Gemba::AudioOutput.new
    samples = Slice(Int16).new(4410 * 2, 1000_i16)

    output.volume = 1.0
    output.queue(samples)
    output.volume = 0.5
    output.queue(samples)
    output.muted = true
    output.queue(samples)
    output.muted = false
    output.volume = 1.0
    output.queue(samples)

    output.fill_ratio.should be > 0.0
    output.destroy
  end
end
