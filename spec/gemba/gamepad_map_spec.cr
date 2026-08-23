require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("gamepad_map_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Duplicated from tryst-sdl; spec-only code can't be shared across shards.
private def with_virtual_gamepad(&)
  id = Tryst::SDL::Gamepad.attach_virtual
  gamepad = Tryst::SDL::Gamepad.open(id)
  begin
    yield gamepad
  ensure
    gamepad.destroy
    Tryst::SDL::Gamepad.detach_virtual
  end
end

describe Gemba::GamepadMap do
  it "#mask is Button::None with no device attached" do
    map = Gemba::GamepadMap.new
    map.mask.should eq Gemba::Button::None
  end

  it "#set rebinds a button to a new gamepad button, clearing its old binding" do
    map = Gemba::GamepadMap.new
    map.set(Gemba::Button::A, :x)
    map.labels[Gemba::Button::A].should eq :x
    map.labels.values.count(:a).should eq 0
  end

  it "#reset! restores the default bindings and dead zone" do
    map = Gemba::GamepadMap.new
    map.set(Gemba::Button::A, :x)
    map.dead_zone = 500

    map.reset!
    map.labels[Gemba::Button::A].should eq :a
    map.dead_zone.should eq Gemba::GamepadMap::DEFAULT_DEAD_ZONE
  end

  it "#labels maps each bound Button to its gamepad button" do
    labels = Gemba::GamepadMap.new.labels
    labels[Gemba::Button::A].should eq :a
    labels[Gemba::Button::Start].should eq :start
  end

  it "#supports_deadzone? is true" do
    Gemba::GamepadMap.new.supports_deadzone?.should be_true
  end

  it "#dead_zone_pct reports the dead zone as a percentage of full travel" do
    map = Gemba::GamepadMap.new
    map.dead_zone_pct.should eq 24

    map.dead_zone = 0
    map.dead_zone_pct.should eq 0
  end

  it "#load_config/#save_to_config are no-ops with no device attached" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      map = Gemba::GamepadMap.new
      map.set(Gemba::Button::A, :x)

      map.load_config(config)
      map.labels[Gemba::Button::A].should eq :x

      map.save_to_config(config)
      config.mappings("abc123").should be_empty
    end
  end

  it "#save_to_config then #load_config round-trips bindings + dead zone, keyed by the device's own GUID" do
    with_tempdir do |dir|
      with_virtual_gamepad do |gamepad|
        config = Gemba::Config.new(File.join(dir, "settings.json"))
        map = Gemba::GamepadMap.new
        map.device = gamepad
        map.set(Gemba::Button::A, :x)
        map.dead_zone = 4000
        map.save_to_config(config)

        fresh = Gemba::GamepadMap.new
        fresh.device = gamepad
        fresh.load_config(config)
        fresh.labels[Gemba::Button::A].should eq :x
        fresh.dead_zone_pct.should eq map.dead_zone_pct
      end
    end
  end

  it "#reload! re-reads config from disk before rebinding" do
    with_tempdir do |dir|
      with_virtual_gamepad do |gamepad|
        path = File.join(dir, "settings.json")
        config = Gemba::Config.new(path)
        map = Gemba::GamepadMap.new
        map.device = gamepad
        map.save_to_config(config)
        config.save!

        other_view = Gemba::Config.new(path)
        other_view.set_mapping(gamepad.guid, "a", "y")
        other_view.save!

        map.reload!(config)
        map.labels[Gemba::Button::A].should eq :y
      end
    end
  end
end
