require "../spec_helper"
require "file_utils"

# A KeySource #held? can poll without any real Tk/SDL widget behind it -
# just a Set of raw keysyms, matching Viewport#key_down?'s own lowercase
# vocabulary ("tab", "shift_l", "iso_left_tab").
private class FakeKeySource
  include Gemba::KeySource

  def initialize(@down : Set(String) = Set(String).new)
  end

  def button?(key : String) : Bool
    @down.includes?(key.downcase)
  end
end

private def with_tempdir(&)
  dir = File.tempname("hotkey_map_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Gemba::HotkeyMap do
  it "#key_for returns the default hotkey for an action" do
    map = Gemba::HotkeyMap.new
    map.key_for(:quit).should eq "q"
    map.key_for(:rewind).should eq ["Shift", "Tab"]
  end

  it "#action_for matches a plain keysym with no modifiers" do
    map = Gemba::HotkeyMap.new
    map.action_for("q").should eq :quit
    map.action_for("q", Set{"Control"}).should be_nil
  end

  it "#action_for matches a keysym plus its required modifiers, order-independent" do
    map = Gemba::HotkeyMap.new
    map.action_for("o", Set{"Control"}).should eq :open_rom
    map.action_for("Tab", Set{"Shift"}).should eq :rewind
    map.action_for("Tab").should eq :fast_forward
  end

  it "#action_for returns nil for a keysym with no bound action" do
    Gemba::HotkeyMap.new.action_for("z").should be_nil
  end

  it "#set rebinds an action, clearing any other action bound to the same hotkey" do
    map = Gemba::HotkeyMap.new
    map.set(:quit, "F1")
    map.key_for(:quit).should eq "F1"
    map.action_for("q").should be_nil
    map.action_for("F1").should eq :quit
  end

  it "#set normalizes modifier order" do
    map = Gemba::HotkeyMap.new
    map.set(:pause, ["Alt", "Control", "p"])
    map.key_for(:pause).should eq ["Control", "Alt", "p"]
  end

  it "#reset! restores the default bindings" do
    map = Gemba::HotkeyMap.new
    map.set(:quit, "F1")
    map.reset!
    map.key_for(:quit).should eq "q"
  end

  it "#labels returns the full action -> hotkey map" do
    Gemba::HotkeyMap.new.labels[:quit].should eq "q"
  end

  it "#load_config leaves the current (default) bindings alone when config has nothing saved" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      map = Gemba::HotkeyMap.new

      map.load_config(config)
      map.key_for(:quit).should eq "q"
    end
  end

  it "#save_to_config then #load_config round-trips both plain and modifier-combo hotkeys" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      map = Gemba::HotkeyMap.new
      map.set(:quit, "F1")
      map.set(:pause, ["Alt", "Control", "p"])
      map.save_to_config(config)

      fresh = Gemba::HotkeyMap.new
      fresh.load_config(config)
      fresh.key_for(:quit).should eq "F1"
      fresh.key_for(:pause).should eq ["Control", "Alt", "p"]
    end
  end

  it "#reload! re-reads config from disk before rebinding" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      config = Gemba::Config.new(path)
      map = Gemba::HotkeyMap.new
      map.set(:quit, "F1")
      map.save_to_config(config)
      config.save!

      other_view = Gemba::Config.new(path)
      other_view.set_hotkey("quit", "F2")
      other_view.save!

      map.reload!(config)
      map.key_for(:quit).should eq "F2"
    end
  end

  describe ".normalize" do
    it "passes a plain String through unchanged" do
      Gemba::HotkeyMap.normalize("F5").should eq "F5"
    end

    it "sorts an Array hotkey's modifiers into canonical order" do
      Gemba::HotkeyMap.normalize(["Alt", "Shift", "Control", "s"]).should eq ["Control", "Shift", "Alt", "s"]
    end

    it "collapses a single-element Array to a plain String" do
      Gemba::HotkeyMap.normalize(["Tab"]).should eq "Tab"
    end
  end

  describe ".display_name" do
    it "returns a plain String as-is" do
      Gemba::HotkeyMap.display_name("F5").should eq "F5"
    end

    it "renders modifiers with display names joined by +" do
      Gemba::HotkeyMap.display_name(["Control", "s"]).should eq "Ctrl+S"
    end
  end

  describe ".normalize_keysym" do
    it "maps ISO_Left_Tab back to Tab" do
      Gemba::HotkeyMap.normalize_keysym("ISO_Left_Tab").should eq "Tab"
    end

    it "maps Shift+number aliases back to the base digit" do
      Gemba::HotkeyMap.normalize_keysym("exclam").should eq "1"
    end

    it "lowercases a bare uppercase letter" do
      Gemba::HotkeyMap.normalize_keysym("A").should eq "a"
    end

    it "passes an unrecognized keysym through unchanged" do
      Gemba::HotkeyMap.normalize_keysym("F5").should eq "F5"
    end
  end

  describe ".modifier_key?" do
    it "is true for a modifier keysym" do
      Gemba::HotkeyMap.modifier_key?("Control_L").should be_true
    end

    it "is false for a non-modifier keysym" do
      Gemba::HotkeyMap.modifier_key?("a").should be_false
    end
  end

  describe ".normalize_modifier" do
    it "normalizes a left/right variant to its canonical name" do
      Gemba::HotkeyMap.normalize_modifier("Shift_R").should eq "Shift"
    end

    it "returns nil for a non-modifier keysym" do
      Gemba::HotkeyMap.normalize_modifier("a").should be_nil
    end
  end

  describe "#held?" do
    it "is true when the plain key is held (no modifiers)" do
      map = Gemba::HotkeyMap.new
      map.held?(:quit, FakeKeySource.new(Set{"q"})).should be_true
      map.held?(:quit, FakeKeySource.new(Set(String).new)).should be_false
    end

    it "is true when a modifier-combo hotkey's key and every modifier side are held" do
      map = Gemba::HotkeyMap.new
      map.set(:pause, ["Control", "p"])
      map.held?(:pause, FakeKeySource.new(Set{"p", "control_l"})).should be_true
      map.held?(:pause, FakeKeySource.new(Set{"p", "control_r"})).should be_true
      map.held?(:pause, FakeKeySource.new(Set{"p"})).should be_false
    end

    it "matches Shift-Tab's default rewind binding via the raw ISO_Left_Tab keysym X11 actually delivers" do
      map = Gemba::HotkeyMap.new
      map.held?(:rewind, FakeKeySource.new(Set{"iso_left_tab", "shift_l"})).should be_true
      map.held?(:rewind, FakeKeySource.new(Set{"tab", "shift_l"})).should be_true
      map.held?(:rewind, FakeKeySource.new(Set{"iso_left_tab"})).should be_false # Shift released
    end

    it "is false for a Symbol with no bound hotkey at all" do
      map = Gemba::HotkeyMap.new
      map.held?(:not_a_real_action, FakeKeySource.new(Set{"q"})).should be_false
    end
  end

  describe ".modifiers_from_state" do
    it "decodes a Tk event state bitmask into modifier names" do
      Gemba::HotkeyMap.modifiers_from_state(0).should eq Set(String).new
      Gemba::HotkeyMap.modifiers_from_state(1).should eq Set{"Shift"}
      Gemba::HotkeyMap.modifiers_from_state(5).should eq Set{"Shift", "Control"}
    end
  end
end
