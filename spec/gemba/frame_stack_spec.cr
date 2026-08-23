require "../spec_helper"

private class FakeFrame
  include Gemba::Frame

  getter shown = 0
  getter hidden = 0
  getter cleaned_up = 0

  def show : Nil
    @shown += 1
  end

  def hide : Nil
    @hidden += 1
  end

  def cleanup : Nil
    @cleaned_up += 1
  end
end

describe Gemba::FrameStack do
  it "starts inactive with no current frame" do
    stack = Gemba::FrameStack.new
    stack.active?.should be_false
    stack.current.should be_nil
    stack.current_frame.should be_nil
  end

  it "#push shows the new frame without hiding anything (nothing was on top)" do
    stack = Gemba::FrameStack.new
    picker = FakeFrame.new
    stack.push(:picker, picker)

    stack.current.should eq :picker
    stack.current_frame.should be(picker)
    picker.shown.should eq 1
  end

  it "#push hides the previous top before showing the new one" do
    stack = Gemba::FrameStack.new
    picker = FakeFrame.new
    emulator = FakeFrame.new
    stack.push(:picker, picker)
    stack.push(:emulator, emulator)

    stack.current.should eq :emulator
    picker.hidden.should eq 1
    emulator.shown.should eq 1
    stack.size.should eq 2
  end

  it "#pop hides the top and re-shows the previous frame" do
    stack = Gemba::FrameStack.new
    picker = FakeFrame.new
    emulator = FakeFrame.new
    stack.push(:picker, picker)
    stack.push(:emulator, emulator)

    stack.pop
    stack.current.should eq :picker
    emulator.hidden.should eq 1
    picker.shown.should eq 2 # once on push, once re-shown by pop
  end

  it "#pop on a single-entry stack empties it" do
    stack = Gemba::FrameStack.new
    picker = FakeFrame.new
    stack.push(:picker, picker)
    stack.pop

    stack.active?.should be_false
    stack.current.should be_nil
  end

  it "#replace_current swaps the frame under the same name without changing depth" do
    stack = Gemba::FrameStack.new
    first_rom = FakeFrame.new
    second_rom = FakeFrame.new
    stack.push(:emulator, first_rom)
    stack.replace_current(second_rom)

    stack.size.should eq 1
    stack.current.should eq :emulator
    stack.current_frame.should be(second_rom)
    first_rom.hidden.should eq 1
    second_rom.shown.should eq 1
  end
end
