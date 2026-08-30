require "../spec_helper"
require "file_utils"
require "digest/crc32"

private def with_tempdir(&)
  dir = File.tempname("rom_patcher_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# ---------------------------------------------------------------------------
# Fixture helpers - build valid binary patch data in-memory, ports of the
# builders in ruby gemba's test_rom_patcher.rb.
# ---------------------------------------------------------------------------

private record IpsRecord, offset : Int32, data : Bytes = Bytes.empty,
  rle_count : Int32 = 0, rle_val : UInt8 = 0_u8

# Build a minimal IPS patch that applies the given records.
private def build_ips(records : Array(IpsRecord)) : Bytes
  io = IO::Memory.new
  io << "PATCH"
  records.each do |rec|
    io.write_byte ((rec.offset >> 16) & 0xFF).to_u8
    io.write_byte ((rec.offset >> 8) & 0xFF).to_u8
    io.write_byte (rec.offset & 0xFF).to_u8
    if rec.rle_count > 0
      io.write_bytes(0_u16, IO::ByteFormat::BigEndian)
      io.write_bytes(rec.rle_count.to_u16, IO::ByteFormat::BigEndian)
      io.write_byte rec.rle_val
    else
      io.write_bytes(rec.data.size.to_u16, IO::ByteFormat::BigEndian)
      io.write(rec.data)
    end
  end
  io << "EOF"
  io.to_slice
end

# Encode a BPS/UPS varint (both encoders are identical; only the
# decoders' bias bookkeeping differs, and this loop matches both).
private def encode_varint(value : Int32) : Bytes
  io = IO::Memory.new
  n = value
  loop do
    x = (n & 0x7f).to_u8
    n >>= 7
    if n == 0
      io.write_byte(0x80_u8 | x)
      break
    end
    io.write_byte(x)
    n -= 1
  end
  io.to_slice
end

# Build a BPS patch using only a TargetRead record (writes literal
# target data) - the simplest valid BPS: ignores source entirely.
private def build_bps(source : Bytes, target : Bytes) : Bytes
  body = IO::Memory.new
  body << "BPS1"
  body.write(encode_varint(source.size))
  body.write(encode_varint(target.size))
  body.write(encode_varint(0)) # metadata_size
  word = ((target.size - 1) << 2) | 1
  body.write(encode_varint(word))
  body.write(target)

  payload = body.to_slice
  footer = IO::Memory.new
  footer.write_bytes(Digest::CRC32.checksum(source), IO::ByteFormat::LittleEndian)
  footer.write_bytes(Digest::CRC32.checksum(target), IO::ByteFormat::LittleEndian)
  footer.write_bytes(Digest::CRC32.checksum(payload), IO::ByteFormat::LittleEndian)
  body.write(footer.to_slice)
  body.to_slice
end

# Build a UPS patch from source -> target: diff hunks of XOR bytes.
private def build_ups(source : Bytes, target : Bytes) : Bytes
  max_size = Math.max(source.size, target.size)
  byte = ->(data : Bytes, i : Int32) { i < data.size ? data[i] : 0_u8 }

  body = IO::Memory.new
  body << "UPS1"
  body.write(encode_varint(source.size))
  body.write(encode_varint(target.size))

  pos = 0
  i = 0
  while i < max_size
    if byte.call(source, i) == byte.call(target, i)
      i += 1
      next
    end
    hunk_start = i
    xor_bytes = IO::Memory.new
    while i < max_size && byte.call(source, i) != byte.call(target, i)
      xor_bytes.write_byte(byte.call(source, i) ^ byte.call(target, i))
      i += 1
    end
    body.write(encode_varint(hunk_start - pos))
    body.write(xor_bytes.to_slice)
    body.write_byte(0_u8)
    pos = hunk_start + xor_bytes.size + 1
  end

  payload = body.to_slice
  footer = IO::Memory.new
  footer.write_bytes(Digest::CRC32.checksum(source), IO::ByteFormat::LittleEndian)
  footer.write_bytes(Digest::CRC32.checksum(target), IO::ByteFormat::LittleEndian)
  footer.write_bytes(Digest::CRC32.checksum(payload), IO::ByteFormat::LittleEndian)
  body.write(footer.to_slice)
  body.to_slice
end

# A small fake ROM - 64 zero bytes, like a blank cartridge header area.
private def blank_rom(size = 64) : Bytes
  Bytes.new(size)
end

describe Gemba::RomPatcher do
  describe ".detect_format" do
    it "recognizes the three magics and rejects everything else" do
      Gemba::RomPatcher.detect_format("PATCHEOF".to_slice).should eq :ips
      Gemba::RomPatcher.detect_format("BPS1\x00".to_slice).should eq :bps
      Gemba::RomPatcher.detect_format("UPS1\x00".to_slice).should eq :ups
      Gemba::RomPatcher.detect_format("JUNK".to_slice).should be_nil
    end
  end

  describe ".safe_out_path" do
    it "returns the path unchanged when nothing collides" do
      with_tempdir do |dir|
        path = File.join(dir, "game.gba")
        Gemba::RomPatcher.safe_out_path(path).should eq path
      end
    end

    it "appends -(2), then -(3), before the extension on collisions" do
      with_tempdir do |dir|
        base = File.join(dir, "game.gba")
        File.write(base, "x")
        Gemba::RomPatcher.safe_out_path(base).should eq File.join(dir, "game-(2).gba")

        File.write(File.join(dir, "game-(2).gba"), "x")
        Gemba::RomPatcher.safe_out_path(base).should eq File.join(dir, "game-(3).gba")
      end
    end
  end

  describe ".patch" do
    it "detects the format, applies, and writes the output file with monotonic progress" do
      with_tempdir do |dir|
        rom_path = File.join(dir, "rom.gba")
        patch_path = File.join(dir, "fix.ips")
        out_path = File.join(dir, "out", "rom-patched.gba")

        File.write(rom_path, blank_rom)
        File.write(patch_path, build_ips([IpsRecord.new(offset: 0, data: Bytes[0xFF, 0xFE, 0xFD, 0xFC])]))

        seen = [] of Float64
        Gemba::RomPatcher.patch(rom_path: rom_path, patch_path: patch_path, out_path: out_path,
          on_progress: ->(pct : Float64) { seen << pct })

        result = File.read(out_path).to_slice
        result[0, 2].should eq Bytes[0xFF, 0xFE]
        result.size.should eq 64

        seen.last.should eq 1.0
        seen.each_cons_pair { |a, b| (b >= a).should be_true }
      end
    end

    it "raises on an unknown patch format" do
      with_tempdir do |dir|
        rom_path = File.join(dir, "rom.gba")
        patch_path = File.join(dir, "bad.xyz")
        File.write(rom_path, "X" * 16)
        File.write(patch_path, "JUNK")
        expect_raises(Gemba::RomPatcher::Error, /Unknown patch format/) do
          Gemba::RomPatcher.patch(rom_path: rom_path, patch_path: patch_path,
            out_path: File.join(dir, "out.gba"))
        end
      end
    end
  end

  describe Gemba::RomPatcher::IPS do
    it "overwrites bytes at the record offset, leaving neighbors alone" do
      patch = build_ips([IpsRecord.new(offset: 4, data: Bytes[0xFF, 0xFE, 0xFD])])
      result = Gemba::RomPatcher::IPS.apply(blank_rom, patch)
      result[0, 4].should eq Bytes.new(4)
      result[4, 3].should eq Bytes[0xFF, 0xFE, 0xFD]
      result[7].should eq 0_u8
    end

    it "fills a region from an RLE record" do
      patch = build_ips([IpsRecord.new(offset: 8, rle_count: 4, rle_val: 0xAB_u8)])
      result = Gemba::RomPatcher::IPS.apply(blank_rom, patch)
      result[8, 4].should eq Bytes[0xAB, 0xAB, 0xAB, 0xAB]
      result[7].should eq 0_u8
      result[12].should eq 0_u8
    end

    it "applies multiple records" do
      patch = build_ips([
        IpsRecord.new(offset: 0, data: Bytes[0x01, 0x02]),
        IpsRecord.new(offset: 10, data: Bytes[0x03, 0x04]),
      ])
      result = Gemba::RomPatcher::IPS.apply(blank_rom, patch)
      result[0, 2].should eq Bytes[0x01, 0x02]
      result[10, 2].should eq Bytes[0x03, 0x04]
    end

    it "extends the ROM when a record writes past its end" do
      patch = build_ips([IpsRecord.new(offset: 8, data: Bytes[0xFF, 0xFF])])
      result = Gemba::RomPatcher::IPS.apply(Bytes.new(4), patch)
      result.size.should eq 10
      result[8, 2].should eq Bytes[0xFF, 0xFF]
    end

    it "returns the ROM unchanged for an empty patch" do
      result = Gemba::RomPatcher::IPS.apply("HELLO".to_slice, build_ips([] of IpsRecord))
      result.should eq "HELLO".to_slice
    end

    it "raises on a truncated patch" do
      patch = build_ips([IpsRecord.new(offset: 0, data: Bytes[0x01])])
      expect_raises(Gemba::RomPatcher::Error, /Truncated/) do
        Gemba::RomPatcher::IPS.apply(blank_rom, patch[0, patch.size - 4])
      end
    end
  end

  describe Gemba::RomPatcher::BPS do
    it "produces the target from a TargetRead patch" do
      source = blank_rom(8)
      target = Bytes[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
      result = Gemba::RomPatcher::BPS.apply(source, build_bps(source, target))
      result.should eq target
    end

    it "raises on a CRC32 mismatch" do
      source = blank_rom(8)
      target = Bytes[0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00]
      patch = build_bps(source, target)
      patch[patch.size - 12] = 0xFF_u8 # corrupt the source CRC
      expect_raises(Gemba::RomPatcher::Error, /CRC32/) do
        Gemba::RomPatcher::BPS.apply(source, patch)
      end
    end

    it "handles identical source and target" do
      source = "GEMBA".to_slice
      result = Gemba::RomPatcher::BPS.apply(source, build_bps(source, source))
      result.should eq source
    end
  end

  describe Gemba::RomPatcher::UPS do
    it "XORs the differing bytes" do
      source = Bytes[0x00, 0x00, 0x00, 0x00]
      target = Bytes[0xFF, 0x00, 0xFF, 0x00]
      result = Gemba::RomPatcher::UPS.apply(source, build_ups(source, target))
      result.should eq target
    end

    it "applies multiple hunks" do
      source = Bytes.new(16)
      target = Bytes.new(16)
      target[0] = 0xAA_u8
      target[8] = 0xBB_u8
      target[15] = 0xCC_u8
      result = Gemba::RomPatcher::UPS.apply(source, build_ups(source, target))
      result.should eq target
    end

    it "raises on a CRC32 mismatch" do
      source = blank_rom(8)
      target = Bytes[0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x00]
      patch = build_ups(source, target)
      patch[patch.size - 12] = 0x00_u8
      patch[patch.size - 11] = 0x00_u8
      expect_raises(Gemba::RomPatcher::Error, /CRC32/) do
        Gemba::RomPatcher::UPS.apply(source, patch)
      end
    end

    it "handles identical source and target" do
      source = Bytes[0x47, 0x45, 0x4D, 0x42, 0x41, 0x00, 0x00, 0x00]
      result = Gemba::RomPatcher::UPS.apply(source, build_ups(source, source))
      result.should eq source
    end

    it "zero-pads the target when the source is shorter" do
      source = Bytes[0x01, 0x02]
      target = Bytes[0x01, 0x03, 0x00, 0x00] # byte 1 differs; 2-3 match the padding
      result = Gemba::RomPatcher::UPS.apply(source, build_ups(source, target))
      result.should eq target
    end

    it "truncates the result when the target is shorter than the source" do
      source = Bytes[0x01, 0x02, 0x03, 0x04]
      target = Bytes[0x01, 0xFF]
      result = Gemba::RomPatcher::UPS.apply(source, build_ups(source, target))
      result.should eq target
    end
  end
end
