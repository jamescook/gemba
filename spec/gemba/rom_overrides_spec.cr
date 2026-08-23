require "../spec_helper"
require "file_utils"
require "../../src/gemba/rom_overrides"

private def with_tempdir(&)
  dir = File.tempname("rom_overrides_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Both path and boxart_dir must point into tempdir, never the real
# user's config directory.
private def new_overrides(dir : String, path : String = File.join(dir, "rom_overrides.json")) : Gemba::RomOverrides
  Gemba::RomOverrides.new(path, boxart_dir: File.join(dir, "boxart"))
end

describe Gemba::RomOverrides do
  it "custom_boxart returns nil for an unknown rom_id" do
    with_tempdir do |dir|
      overrides = new_overrides(dir)
      overrides.custom_boxart("AGB-BPEE-DEADBEEF").should be_nil
    end
  end

  it "set_custom_boxart copies the file into the boxart cache dir and returns the dest path" do
    with_tempdir do |dir|
      src = File.join(dir, "my_cover.png")
      File.write(src, "fake png bytes")

      overrides = new_overrides(dir)
      dest = overrides.set_custom_boxart("AGB-BPEE-DEADBEEF", src)

      dest.should eq File.join(dir, "boxart", "AGB-BPEE-DEADBEEF", "custom.png")
      File.read(dest).should eq "fake png bytes"
      overrides.custom_boxart("AGB-BPEE-DEADBEEF").should eq dest
    end
  end

  it "persists across a fresh instance" do
    with_tempdir do |dir|
      path = File.join(dir, "rom_overrides.json")
      src = File.join(dir, "my_cover.jpg")
      File.write(src, "jpeg bytes")

      first = new_overrides(dir, path)
      dest = first.set_custom_boxart("AGB-BPEE-DEADBEEF", src)

      reloaded = new_overrides(dir, path)
      reloaded.custom_boxart("AGB-BPEE-DEADBEEF").should eq dest
    end
  end

  it "preserves other fields already stored under a rom_id" do
    with_tempdir do |dir|
      path = File.join(dir, "rom_overrides.json")
      File.write(path, %({"AGB-BPEE-DEADBEEF": {"some_future_field": "keep me"}}))
      src = File.join(dir, "my_cover.png")
      File.write(src, "png bytes")

      overrides = new_overrides(dir, path)
      overrides.set_custom_boxart("AGB-BPEE-DEADBEEF", src)

      raw = JSON.parse(File.read(path))
      raw["AGB-BPEE-DEADBEEF"]["some_future_field"].as_s.should eq "keep me"
      raw["AGB-BPEE-DEADBEEF"]["custom_boxart"].as_s?.should_not be_nil
    end
  end

  it "a second set_custom_boxart for the same rom_id replaces the override" do
    with_tempdir do |dir|
      src1 = File.join(dir, "cover1.png")
      src2 = File.join(dir, "cover2.png")
      File.write(src1, "first")
      File.write(src2, "second")

      overrides = new_overrides(dir)
      overrides.set_custom_boxart("AGB-BPEE-DEADBEEF", src1)
      dest2 = overrides.set_custom_boxart("AGB-BPEE-DEADBEEF", src2)

      overrides.custom_boxart("AGB-BPEE-DEADBEEF").should eq dest2
      File.read(dest2).should eq "second"
    end
  end
end
