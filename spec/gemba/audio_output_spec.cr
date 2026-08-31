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

  # Muting drops the stream's gain to 0.0 rather than stopping the
  # queue, so the samples still go in - EmulationWorker paces off
  # #fill_ratio, and a muted run must pace exactly like an unmuted one.
  it "#muted= silences without changing the queued byte count" do
    muted = Gemba::AudioOutput.new
    muted.muted = true
    samples = Slice(Int16).new(4410 * 2, 1000_i16)
    muted.queue(samples)
    muted.fill_ratio.should be > 0.0
    muted.@stream.gain.should eq 0.0_f32
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

  # #queue hands SDL a zero-copy reinterpret of the caller's slice at
  # EVERY volume, since the stream's gain does the scaling - so there is
  # no scaled path to allocate for, and no warm-up needed to prove it.
  it "#queue allocates nothing, at any volume and muted" do
    output = Gemba::AudioOutput.new
    output.volume = 0.5
    samples = Slice(Int16).new(4410 * 2, 1000_i16)

    GC.collect
    before = GC.stats.total_bytes
    50.times { output.queue(samples) }
    (GC.stats.total_bytes - before).should eq 0

    output.muted = true
    GC.collect
    before_muted = GC.stats.total_bytes
    50.times { output.queue(samples) }
    (GC.stats.total_bytes - before_muted).should eq 0

    output.destroy
  end

  # Mute and volume both drive one stream gain, so the order they are
  # set in matters: muting must not lose the volume underneath it, and
  # unmuting must restore that volume rather than jumping to 1.0.
  it "alternating volume/mute keeps the two in the right order" do
    output = Gemba::AudioOutput.new
    samples = Slice(Int16).new(4410 * 2, 1000_i16)

    output.volume = 1.0
    output.queue(samples)
    output.@stream.gain.should eq 1.0_f32

    output.volume = 0.5
    output.queue(samples)
    output.@stream.gain.should be_close(0.5, 0.0001)

    output.muted = true
    output.queue(samples)
    output.@stream.gain.should eq 0.0_f32
    # The volume underneath is remembered, not overwritten by the mute.
    output.volume.should eq 0.5

    # Setting volume while muted stays silent rather than un-muting.
    output.volume = 0.75
    output.@stream.gain.should eq 0.0_f32

    output.muted = false
    output.queue(samples)
    output.@stream.gain.should be_close(0.75, 0.0001)

    output.fill_ratio.should be > 0.0
    output.destroy
  end
end
