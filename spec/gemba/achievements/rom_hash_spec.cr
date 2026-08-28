require "../../spec_helper"
require "digest/md5"

describe Gemba::Achievements::RomHash do
  it "is a plain whole-file MD5, matching what rcheevos hashes for GBA" do
    path = File.tempname("rom_hash_spec", ".gba")
    begin
      # Deliberately larger than one CHUNK_BYTES read, so the chunked
      # loop is what's actually under test.
      File.write(path, "GBA\x00" * 40_000)
      Gemba::Achievements::RomHash.for_file(path).should eq Digest::MD5.hexdigest(File.read(path))
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "handles a file smaller than one chunk" do
    path = File.tempname("rom_hash_spec_small", ".gba")
    begin
      File.write(path, "tiny")
      Gemba::Achievements::RomHash.for_file(path).should eq Digest::MD5.hexdigest("tiny")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "handles an empty file without hanging" do
    path = File.tempname("rom_hash_spec_empty", ".gba")
    begin
      File.write(path, "")
      Gemba::Achievements::RomHash.for_file(path).should eq Digest::MD5.hexdigest("")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
