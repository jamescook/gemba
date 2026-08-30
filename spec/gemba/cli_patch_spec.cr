require "../spec_helper"
require "file_utils"
require "digest/crc32"

private def with_tempdir(&)
  dir = File.tempname("cli_patch_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# One normal record at the given offset - the smallest useful IPS patch.
private def write_ips(path : String, offset : Int32, data : Bytes) : Nil
  io = IO::Memory.new
  io << "PATCH"
  io.write_byte ((offset >> 16) & 0xFF).to_u8
  io.write_byte ((offset >> 8) & 0xFF).to_u8
  io.write_byte (offset & 0xFF).to_u8
  io.write_bytes(data.size.to_u16, IO::ByteFormat::BigEndian)
  io.write(data)
  io << "EOF"
  File.write(path, io.to_slice)
end

describe Gemba::CLI::Patch do
  describe "parse (dry run)" do
    it "takes ROM and PATCH positionals and computes the default output beside the ROM" do
      plan = Gemba::CLI.run(["patch", "game.gba", "fix.ips"], dry_run: true).as(Gemba::CLI::Patch::Plan)
      plan.rom.to_s.should end_with "/game.gba"
      plan.patch.to_s.should end_with "/fix.ips"
      plan.out_path.to_s.should end_with "/game-patched.gba"
      plan.format.should be_nil
    end

    it "-o overrides the output path" do
      plan = Gemba::CLI.run(["patch", "-o", "patched/out.gba", "game.gba", "fix.ips"],
        dry_run: true).as(Gemba::CLI::Patch::Plan)
      plan.out_path.to_s.should end_with "/patched/out.gba"
    end

    it "--format maps to a symbol; an unknown value raises" do
      plan = Gemba::CLI.run(["patch", "--format", "UPS", "game.gba", "fix.ups"],
        dry_run: true).as(Gemba::CLI::Patch::Plan)
      plan.format.should eq :ups

      expect_raises(Gemba::CLI::Error, /unknown patch format/) do
        Gemba::CLI.run(["patch", "--format", "xyz", "game.gba", "fix.xyz"], dry_run: true)
      end
    end

    it "patch -h prints its usage" do
      io = IO::Memory.new
      plan = Gemba::CLI.run(["patch", "-h"], io: io).as(Gemba::CLI::Patch::Plan)
      plan.help.should be_true
      io.to_s.should contain "Usage: gemba patch [options] ROM_FILE PATCH_FILE"
    end

    it "missing positionals raise" do
      expect_raises(Gemba::CLI::Error, /ROM_FILE and PATCH_FILE are required/) do
        Gemba::CLI.run(["patch"], dry_run: true)
      end
      expect_raises(Gemba::CLI::Error, /required/) do
        Gemba::CLI.run(["patch", "only_rom.gba"], dry_run: true)
      end
    end
  end

  describe "execution" do
    it "applies an IPS patch end to end; a second run appends -(2) instead of overwriting" do
      with_tempdir do |dir|
        rom = File.join(dir, "game.gba")
        File.write(rom, Bytes.new(64))
        patch = File.join(dir, "fix.ips")
        write_ips(patch, 4, Bytes[0xFF, 0xFE])

        io = IO::Memory.new
        Gemba::CLI.run(["patch", rom, patch], io: io)

        out_path = File.join(dir, "game-patched.gba")
        result = File.read(out_path).to_slice
        expected = Bytes.new(64)
        expected[4] = 0xFF_u8
        expected[5] = 0xFE_u8
        result.should eq expected
        Digest::CRC32.checksum(result).should eq Digest::CRC32.checksum(expected)
        io.to_s.should contain "Written: #{out_path}"

        # Second run: the existing output survives untouched.
        Gemba::CLI.run(["patch", rom, patch], io: io)
        File.read(out_path).to_slice.should eq expected
        second = File.join(dir, "game-patched-(2).gba")
        File.read(second).to_slice.should eq expected
        io.to_s.should contain "Written: #{second}"
      end
    end

    it "--format applies an IPS patch despite a meaningless extension, and forcing the wrong one fails" do
      with_tempdir do |dir|
        rom = File.join(dir, "game.gba")
        File.write(rom, Bytes.new(32))
        patch = File.join(dir, "fix.dat") # extension says nothing
        write_ips(patch, 0, Bytes[0xAB])

        io = IO::Memory.new
        Gemba::CLI.run(["patch", "--format", "ips", rom, patch], io: io)
        File.read(File.join(dir, "game-patched.gba")).to_slice[0].should eq 0xAB_u8

        # The exact failure depends on how the wrong parser trips over
        # the bytes (truncated varint here) - what matters is that it
        # surfaces as a CLI error, not silence or a crash.
        expect_raises(Gemba::CLI::Error) do
          Gemba::CLI.run(["patch", "--format", "ups", "-o", File.join(dir, "forced.gba"),
                          rom, patch], io: io)
        end
      end
    end

    it "reports missing files and unknown patch data as CLI errors" do
      with_tempdir do |dir|
        rom = File.join(dir, "game.gba")
        patch = File.join(dir, "fix.ips")
        io = IO::Memory.new

        expect_raises(Gemba::CLI::Error, /ROM file not found/) do
          Gemba::CLI.run(["patch", rom, patch], io: io)
        end

        File.write(rom, Bytes.new(16))
        expect_raises(Gemba::CLI::Error, /Patch file not found/) do
          Gemba::CLI.run(["patch", rom, patch], io: io)
        end

        File.write(patch, "JUNKDATA")
        expect_raises(Gemba::CLI::Error, /Unknown patch format/) do
          Gemba::CLI.run(["patch", rom, patch], io: io)
        end
      end
    end
  end
end
