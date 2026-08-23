require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("config_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Gemba::Config do
  it "defaults match ruby gemba's own GLOBAL_DEFAULTS for a fresh file" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      config.scale.should eq 3
      config.volume.should eq 100
      config.muted?.should be_false
      config.keep_aspect_ratio?.should be_true
      config.pixel_filter.should eq "nearest"
      config.integer_scale?.should be_false
      config.color_correction?.should be_false
      config.frame_blending?.should be_false
      config.locale.should eq "auto"
      config.picker_view.should eq "grid"
    end
  end

  it "#save! persists every setter, reloaded by a fresh instance" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      config = Gemba::Config.new(path)
      config.scale = 2
      config.volume = 42
      config.muted = true
      config.keep_aspect_ratio = false
      config.pixel_filter = "linear"
      config.integer_scale = true
      config.color_correction = true
      config.frame_blending = true
      config.locale = "ja"
      config.picker_view = "list"
      config.save!

      reloaded = Gemba::Config.new(path)
      reloaded.scale.should eq 2
      reloaded.volume.should eq 42
      reloaded.muted?.should be_true
      reloaded.keep_aspect_ratio?.should be_false
      reloaded.pixel_filter.should eq "linear"
      reloaded.integer_scale?.should be_true
      reloaded.color_correction?.should be_true
      reloaded.frame_blending?.should be_true
      reloaded.locale.should eq "ja"
      reloaded.picker_view.should eq "list"
    end
  end

  it "#scale= clamps to 1..4" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      config.scale = 99
      config.scale.should eq 4
      config.scale = -1
      config.scale.should eq 1
    end
  end

  it "quick_save_slot/save_state_backup?/save_state_debounce default and persist" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      config = Gemba::Config.new(path)
      config.quick_save_slot.should eq 1
      config.save_state_backup?.should be_true
      config.save_state_debounce.should eq 3.0

      config.quick_save_slot = 4
      config.save_state_backup = false
      config.save_state_debounce = 1.5
      config.save!

      reloaded = Gemba::Config.new(path)
      reloaded.quick_save_slot.should eq 4
      reloaded.save_state_backup?.should be_false
      reloaded.save_state_debounce.should eq 1.5
    end
  end

  it "#quick_save_slot= clamps to 1..10" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      config.quick_save_slot = 99
      config.quick_save_slot.should eq 10
      config.quick_save_slot = -1
      config.quick_save_slot.should eq 1
    end
  end

  it "#save_state_debounce reads a whole-number JSON value written without a decimal point" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"global": {"save_state_debounce": 3}, "gamepads": {}, "hotkeys": {}, "recent_roms": []}))
      Gemba::Config.new(path).save_state_debounce.should eq 3.0
    end
  end

  it "#mappings/#set_mapping round-trip per-GUID button bindings, replacing any old input on the same button" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      config.mappings("keyboard").should be_empty

      config.set_mapping("keyboard", "a", "z")
      config.set_mapping("keyboard", "b", "x")
      config.mappings("keyboard").should eq({"a" => "z", "b" => "x"})

      config.set_mapping("keyboard", "a", "k")
      config.mappings("keyboard").should eq({"a" => "k", "b" => "x"})
    end
  end

  it "#dead_zone/#set_dead_zone round-trip per-GUID, clamped to 0..50" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      config.dead_zone("abc123").should eq 25

      config.set_dead_zone("abc123", 99)
      config.dead_zone("abc123").should eq 50
      config.set_dead_zone("abc123", -1)
      config.dead_zone("abc123").should eq 0
    end
  end

  it "#hotkeys/#set_hotkey round-trip both plain and modifier-combo hotkeys" do
    with_tempdir do |dir|
      config = Gemba::Config.new(File.join(dir, "settings.json"))
      config.hotkeys.should be_empty

      config.set_hotkey("quit", "F1")
      config.set_hotkey("rewind", ["Shift", "Tab"])

      config.hotkeys["quit"].as_s.should eq "F1"
      config.hotkeys["rewind"].as_a.map(&.as_s).should eq ["Shift", "Tab"]
    end
  end

  it "#reload! discards unsaved in-memory changes and re-reads disk" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      config = Gemba::Config.new(path)
      config.scale = 2
      config.save!

      config.scale = 4
      config.reload!
      config.scale.should eq 2
    end
  end

  # Ruby's settings.json has fields this port doesn't understand
  # (gamepad maps, recent_roms, RA tokens); #save! must preserve them.
  it "#save! preserves JSON fields this class doesn't know about" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"global": {"scale": 3, "ra_username": "someone"}, "gamepads": {"abc123": {"a": "Return"}}, "recent_roms": ["/roms/foo.gba"]}))

      config = Gemba::Config.new(path)
      config.scale = 4
      config.save!

      raw = JSON.parse(File.read(path))
      raw["global"]["ra_username"].as_s.should eq "someone"
      raw["global"]["scale"].as_i.should eq 4
      raw["gamepads"]["abc123"]["a"].as_s.should eq "Return"
      raw["recent_roms"].as_a.should eq ["/roms/foo.gba"]
    end
  end
end
