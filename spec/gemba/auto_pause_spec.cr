require "../spec_helper"

describe Gemba::AutoPause do
  it "the first hold pauses and the matching release resumes" do
    auto = Gemba::AutoPause.new

    auto.hold(:modal, paused_now: false).should be_true
    auto.active?.should be_true
    auto.release(:modal).should be_true
    auto.active?.should be_false
  end

  it "only the last of several overlapping reasons resumes" do
    auto = Gemba::AutoPause.new

    auto.hold(:modal, paused_now: false).should be_true
    # Switching away with Settings already open must not pause twice...
    auto.hold(:focus_loss, paused_now: true).should be_false
    # ...and switching back must not resume out from under the modal.
    auto.release(:focus_loss).should be_false
    auto.held?(:modal).should be_true

    auto.release(:modal).should be_true
  end

  it "never resumes a game the user had paused themselves" do
    auto = Gemba::AutoPause.new

    auto.hold(:focus_loss, paused_now: true).should be_false
    auto.release(:focus_loss).should be_false
  end

  it "re-holding a reason already held changes nothing" do
    auto = Gemba::AutoPause.new

    auto.hold(:menu, paused_now: false).should be_true
    auto.hold(:menu, paused_now: false).should be_false
    auto.reasons.size.should eq 1

    auto.release(:menu).should be_true
  end

  it "releasing a reason that was never held is a no-op" do
    auto = Gemba::AutoPause.new

    auto.release(:focus_loss).should be_false

    auto.hold(:modal, paused_now: false).should be_true
    # A Deactivate with no matching Activate mustn't resume the modal's
    # own pause.
    auto.release(:focus_loss).should be_false
    auto.active?.should be_true
  end

  it "a manual pause during an auto-pause doesn't survive the release" do
    auto = Gemba::AutoPause.new

    auto.hold(:modal, paused_now: false).should be_true
    # paused_now is only read for the FIRST reason - by now it can't
    # tell a fresh user pause apart from the auto-pause in effect, so
    # the release still resumes. Same behaviour the single-boolean
    # version this replaced had.
    auto.hold(:menu, paused_now: true).should be_false
    auto.release(:menu).should be_false
    auto.release(:modal).should be_true
  end
end
