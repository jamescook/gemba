require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("rom_library_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Gemba::RomLibrary do
  it "starts empty when no file exists yet" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.all.should be_empty
    end
  end

  it "#remember adds an entry, persisted for a fresh instance" do
    with_tempdir do |dir|
      path = File.join(dir, "rom_library.json")
      library = Gemba::RomLibrary.new(path)
      library.remember("Space Blast", "/roms/space_blast.gba", "2026-01-01T00:00:00Z")

      reloaded = Gemba::RomLibrary.new(path)
      reloaded.all.size.should eq 1
      reloaded.all.first.title.should eq "Space Blast"
      reloaded.all.first.path.should eq "/roms/space_blast.gba"
    end
  end

  it "#remember upserts by path rather than duplicating" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Space Blast", "/roms/space_blast.gba", "2026-01-01T00:00:00Z")
      library.remember("Space Blast (renamed)", "/roms/space_blast.gba", "2026-01-02T00:00:00Z")

      library.all.size.should eq 1
      library.all.first.title.should eq "Space Blast (renamed)"
    end
  end

  it "#all sorts most-recently-played first" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")
      library.remember("Space Blast", "/roms/space_blast.gba", "2026-01-02T00:00:00Z")

      library.all.map(&.title).should eq ["Space Blast", "Fill"]
    end
  end

  it "#remove deletes the entry at path, persisted for a fresh instance" do
    with_tempdir do |dir|
      path = File.join(dir, "rom_library.json")
      library = Gemba::RomLibrary.new(path)
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")
      library.remember("Space Blast", "/roms/space_blast.gba", "2026-01-02T00:00:00Z")

      library.remove("/roms/fill.gba")

      library.all.map(&.path).should eq ["/roms/space_blast.gba"]
      Gemba::RomLibrary.new(path).all.map(&.path).should eq ["/roms/space_blast.gba"]
    end
  end

  it "#remove is a no-op for a path with no entry" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")

      library.remove("/roms/never_opened.gba")

      library.all.map(&.path).should eq ["/roms/fill.gba"]
    end
  end

  it "a fresh entry has no rom_id/game_code until #update_identity runs" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Space Blast", "/roms/space_blast.gba", "2026-01-01T00:00:00Z")

      entry = library.all.first
      entry.rom_id.should eq ""
      entry.game_code.should eq ""
    end
  end

  it "#update_identity patches rom_id/game_code onto the entry at path, persisted for a fresh instance" do
    with_tempdir do |dir|
      path = File.join(dir, "rom_library.json")
      library = Gemba::RomLibrary.new(path)
      library.remember("Space Blast", "/roms/space_blast.gba", "2026-01-01T00:00:00Z")
      library.update_identity("/roms/space_blast.gba", "AGB-BPEE", 0xDEADBEEF_u32)

      reloaded = Gemba::RomLibrary.new(path)
      entry = reloaded.all.first
      entry.game_code.should eq "AGB-BPEE"
      entry.rom_id.should eq "AGB-BPEE-DEADBEEF"
      entry.title.should eq "Space Blast"
    end
  end

  it "#update_identity is a no-op for a path with no #remember'd entry" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.update_identity("/roms/never_opened.gba", "AGB-BPEE", 0xDEADBEEF_u32)

      library.all.should be_empty
    end
  end

  it "RomLibrary.rom_id sanitizes game_code and hex-formats the checksum, matching SaveStateManager's directory naming" do
    Gemba::RomLibrary.rom_id("AGB-BPEE", 0xDEADBEEF_u32).should eq "AGB-BPEE-DEADBEEF"
    Gemba::RomLibrary.rom_id("AGB/weird:code", 0xA_u32).should eq "AGB_weird_code-0000000A"
  end
end
