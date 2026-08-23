require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("keyboard_map_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Gemba::KeyboardMap do
  it "#mask is Button::None with no device attached" do
    map = Gemba::KeyboardMap.new
    map.mask.should eq Gemba::Button::None
  end

  it "#mask reflects the default bindings for whatever the device holds" do
    keyboard = Gemba::VirtualKeyboard.new
    map = Gemba::KeyboardMap.new
    map.device = keyboard

    keyboard.press("z")
    keyboard.press("Right")
    map.mask.should eq(Gemba::Button::A | Gemba::Button::Right)

    keyboard.release("z")
    map.mask.should eq Gemba::Button::Right
  end

  it "#set rebinds a button to a new key, clearing its old binding" do
    map = Gemba::KeyboardMap.new
    map.set(Gemba::Button::A, "k")

    keyboard = Gemba::VirtualKeyboard.new
    map.device = keyboard
    keyboard.press("k")
    map.mask.should eq Gemba::Button::A

    keyboard.release("k")
    keyboard.press("z")
    map.mask.should eq Gemba::Button::None
  end

  it "#set clears any other key already bound to the same button" do
    map = Gemba::KeyboardMap.new
    map.set(Gemba::Button::A, "k")
    map.labels[Gemba::Button::A].should eq "k"
    map.labels.values.count("z").should eq 0
  end

  it "#reset! restores the default bindings" do
    map = Gemba::KeyboardMap.new
    map.set(Gemba::Button::A, "k")
    map.reset!
    map.labels[Gemba::Button::A].should eq "z"
  end

  it "#labels maps each bound Button to its keysym" do
    map = Gemba::KeyboardMap.new
    labels = map.labels
    labels[Gemba::Button::A].should eq "z"
    labels[Gemba::Button::Start].should eq "Return"
  end

  it "#supports_deadzone? is false" do
    Gemba::KeyboardMap.new.supports_deadzone?.should be_false
  end

  it "#load_config falls back to defaults when config has nothing saved" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      map = Gemba::KeyboardMap.new
      map.set(Gemba::Button::A, "k")

      map.load_config(config)
      map.labels[Gemba::Button::A].should eq "z"
    end
  end

  it "#save_to_config then #load_config round-trips custom bindings" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      map = Gemba::KeyboardMap.new
      map.set(Gemba::Button::A, "k")
      map.save_to_config(config)

      fresh = Gemba::KeyboardMap.new
      fresh.load_config(config)
      fresh.labels[Gemba::Button::A].should eq "k"
    end
  end

  it "#reload! re-reads config from disk before rebinding" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      config = Gemba::Config.new(path)
      map = Gemba::KeyboardMap.new
      map.set(Gemba::Button::A, "k")
      map.save_to_config(config)
      config.save!

      other_view = Gemba::Config.new(path)
      other_view.set_mapping(Gemba::Config::KEYBOARD_GUID, "a", "j")
      other_view.save!

      map.reload!(config)
      map.labels[Gemba::Button::A].should eq "j"
    end
  end
end
