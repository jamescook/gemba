require "../spec_helper"

describe Gemba::VirtualKeyboard do
  it "tracks pressed keysyms and forgets released ones" do
    keyboard = Gemba::VirtualKeyboard.new
    keyboard.button?("z").should be_false

    keyboard.press("z")
    keyboard.button?("z").should be_true

    keyboard.release("z")
    keyboard.button?("z").should be_false
  end

  it "releasing a keysym that was never pressed is a no-op" do
    keyboard = Gemba::VirtualKeyboard.new
    keyboard.release("z")
    keyboard.button?("z").should be_false
  end
end
