# frozen_string_literal: true

require "minitest/autorun"
require "zlib"
require "stringio"

# Bootstrap Zeitwerk autoloading without Tk/SDL2.
require_relative "../lib/gemba/headless"

class TestRomPatcher < Minitest::Test

  # ---------------------------------------------------------------------------
  # Fixture helpers — build valid binary patch data in-memory
  # ---------------------------------------------------------------------------

  # Build a minimal IPS patch that applies the given records.
  # records: [{offset:, data:}] or [{offset:, rle_count:, rle_val:}]
  def build_ips(records)
    io = StringIO.new.tap { |s| s.binmode }
    io.write("PATCH")
    records.each do |rec|
      off = rec[:offset]
      io.write([off >> 16, (off >> 8) & 0xFF, off & 0xFF].pack("CCC"))
      if rec[:rle_count]
        io.write([0, rec[:rle_count]].pack("nn"))
        io.write([rec[:rle_val]].pack("C"))
      else
        io.write([rec[:data].bytesize].pack("n"))
        io.write(rec[:data].b)
      end
    end
    io.write("EOF")
    io.string.b
  end

  # Encode a BPS varint (byuu's additive-shift encoding).
  def bps_varint(n)
    out = "".b
    loop do
      x = n & 0x7f
      n >>= 7
      if n == 0
        out << (0x80 | x).chr
        break
      end
      out << x.chr
      n -= 1
    end
    out
  end

  # Build a BPS patch using only TargetRead records (writes literal target data).
  # Simplest valid BPS: ignores source entirely, just emits target bytes.
  def build_bps(source, target)
    source = source.b
    target = target.b
    body = StringIO.new.tap { |s| s.binmode }
    body.write("BPS1")
    body.write(bps_varint(source.bytesize))
    body.write(bps_varint(target.bytesize))
    body.write(bps_varint(0))           # metadata_size = 0
    # One TargetRead record covering the entire target
    word = ((target.bytesize - 1) << 2) | 1
    body.write(bps_varint(word))
    body.write(target)
    payload = body.string.b
    src_crc   = Zlib.crc32(source)
    tgt_crc   = Zlib.crc32(target)
    patch_crc = Zlib.crc32(payload)
    payload + [src_crc, tgt_crc, patch_crc].pack("VVV")
  end

  # Encode a UPS varint (simple bitshift encoding).
  def ups_varint(n)
    out = "".b
    loop do
      x = n & 0x7f
      n >>= 7
      if n == 0
        out << (0x80 | x).chr
        break
      end
      out << x.chr
    end
    out
  end

  # Build a UPS patch from source → target.
  def build_ups(source, target)
    source = source.b
    target = target.b
    max_size = [source.bytesize, target.bytesize].max

    # Collect diff hunks: each is {start:, xor_bytes:}
    hunks = []
    i = 0
    while i < max_size
      s = source.getbyte(i) || 0
      t = target.getbyte(i) || 0
      if s != t
        hunk_start = i
        xor_bytes  = "".b
        while i < max_size
          s = source.getbyte(i) || 0
          t = target.getbyte(i) || 0
          break if s == t
          xor_bytes << (s ^ t).chr
          i += 1
        end
        hunks << { start: hunk_start, xor_bytes: xor_bytes }
      else
        i += 1
      end
    end

    # Build body
    body = StringIO.new.tap { |s| s.binmode }
    body.write("UPS1")
    body.write(ups_varint(source.bytesize))
    body.write(ups_varint(target.bytesize))

    pos = 0
    hunks.each do |h|
      skip = h[:start] - pos
      body.write(ups_varint(skip))
      body.write(h[:xor_bytes])
      body.write("\x00")
      pos = h[:start] + h[:xor_bytes].bytesize + 1
    end

    payload = body.string.b
    src_crc   = Zlib.crc32(source)
    tgt_crc   = Zlib.crc32(target)
    patch_crc = Zlib.crc32(payload)
    payload + [src_crc, tgt_crc, patch_crc].pack("VVV")
  end

  # A small fake ROM — 64 zero bytes, like a blank cartridge header area.
  def blank_rom(size = 64)
    "\x00".b * size
  end

  # ---------------------------------------------------------------------------
  # RomPatcher (dispatcher)
  # ---------------------------------------------------------------------------

  def test_detect_format_ips
    patch = "PATCH" + "EOF"
    assert_equal :ips, Gemba::RomPatcher.detect_format(patch)
  end

  def test_detect_format_bps
    patch = "BPS1\x00"
    assert_equal :bps, Gemba::RomPatcher.detect_format(patch)
  end

  def test_detect_format_ups
    patch = "UPS1\x00"
    assert_equal :ups, Gemba::RomPatcher.detect_format(patch)
  end

  def test_detect_format_unknown
    assert_nil Gemba::RomPatcher.detect_format("JUNK")
  end

  def test_safe_out_path_no_collision
    path = "/tmp/nonexistent_gemba_test_#{Process.pid}.gba"
    assert_equal path, Gemba::RomPatcher.safe_out_path(path)
  end

  def test_safe_out_path_collision
    Dir.mktmpdir do |dir|
      base = File.join(dir, "game.gba")
      File.write(base, "x")
      result = Gemba::RomPatcher.safe_out_path(base)
      assert_equal File.join(dir, "game-(2).gba"), result
    end
  end

  def test_safe_out_path_multiple_collisions
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "game.gba"),     "x")
      File.write(File.join(dir, "game-(2).gba"), "x")
      result = Gemba::RomPatcher.safe_out_path(File.join(dir, "game.gba"))
      assert_equal File.join(dir, "game-(3).gba"), result
    end
  end

  def test_patch_dispatches_to_ips
    Dir.mktmpdir do |dir|
      rom_path   = File.join(dir, "rom.gba")
      patch_path = File.join(dir, "fix.ips")
      out_path   = File.join(dir, "rom-patched.gba")

      source = blank_rom
      File.binwrite(rom_path, source)
      File.binwrite(patch_path, build_ips([{ offset: 0, data: "\xFF\xFE\xFD\xFC" }]))

      Gemba::RomPatcher.patch(rom_path: rom_path, patch_path: patch_path, out_path: out_path)
      result = File.binread(out_path)
      assert_equal "\xFF".b, result[0, 1]
      assert_equal "\xFE".b, result[1, 1]
    end
  end

  def test_patch_raises_on_unknown_format
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "rom.gba"),   "X" * 16)
      File.binwrite(File.join(dir, "bad.xyz"),   "JUNK")
      assert_raises(RuntimeError) do
        Gemba::RomPatcher.patch(
          rom_path:   File.join(dir, "rom.gba"),
          patch_path: File.join(dir, "bad.xyz"),
          out_path:   File.join(dir, "out.gba")
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # IPS
  # ---------------------------------------------------------------------------

  def test_ips_overwrites_bytes_at_offset
    source = blank_rom
    patch  = build_ips([{ offset: 4, data: "\xFF\xFE\xFD" }])
    result = Gemba::RomPatcher::IPS.apply(source, patch)
    assert_equal "\x00".b * 4, result[0, 4], "bytes before offset unchanged"
    assert_equal "\xFF\xFE\xFD".b, result[4, 3], "patch bytes applied"
    assert_equal "\x00".b, result[7, 1], "bytes after patch unchanged"
  end

  def test_ips_rle_record_fills_region
    source = blank_rom
    patch  = build_ips([{ offset: 8, rle_count: 4, rle_val: 0xAB }])
    result = Gemba::RomPatcher::IPS.apply(source, patch)
    assert_equal "\xAB".b * 4, result[8, 4]
    assert_equal "\x00".b, result[7, 1], "byte before RLE unchanged"
    assert_equal "\x00".b, result[12, 1], "byte after RLE unchanged"
  end

  def test_ips_multiple_records
    source = blank_rom
    patch  = build_ips([
      { offset: 0,  data: "\x01\x02" },
      { offset: 10, data: "\x03\x04" },
    ])
    result = Gemba::RomPatcher::IPS.apply(source, patch)
    assert_equal "\x01\x02".b, result[0, 2]
    assert_equal "\x03\x04".b, result[10, 2]
  end

  def test_ips_extends_rom_if_patch_exceeds_size
    source = "\x00".b * 4
    patch  = build_ips([{ offset: 8, data: "\xFF\xFF" }])
    result = Gemba::RomPatcher::IPS.apply(source, patch)
    assert result.bytesize >= 10, "ROM extended to fit patch"
    assert_equal "\xFF\xFF".b, result[8, 2]
  end

  def test_ips_empty_patch_returns_rom_unchanged
    source = "HELLO".b
    patch  = build_ips([])
    result = Gemba::RomPatcher::IPS.apply(source, patch)
    assert_equal source, result
  end

  # ---------------------------------------------------------------------------
  # BPS
  # ---------------------------------------------------------------------------

  def test_bps_target_read_produces_correct_output
    source = blank_rom(8)
    target = "\x11\x22\x33\x44\x55\x66\x77\x88".b
    patch  = build_bps(source, target)
    result = Gemba::RomPatcher::BPS.apply(source, patch)
    assert_equal target, result
  end

  def test_bps_crc_mismatch_raises
    source = blank_rom(8)
    target = "\xDE\xAD\xBE\xEF\x00\x00\x00\x00".b
    patch  = build_bps(source, target)
    # Corrupt the source CRC (bytes -12..-9)
    bad_patch = patch.dup.b
    bad_patch[-12] = "\xFF".b
    err = assert_raises(RuntimeError) { Gemba::RomPatcher::BPS.apply(source, bad_patch) }
    assert_match(/CRC32/, err.message)
  end

  def test_bps_identical_source_and_target
    source = "GEMBA".b
    target = "GEMBA".b
    patch  = build_bps(source, target)
    result = Gemba::RomPatcher::BPS.apply(source, patch)
    assert_equal target, result
  end

  # ---------------------------------------------------------------------------
  # UPS
  # ---------------------------------------------------------------------------

  def test_ups_xors_differing_bytes
    source = "\x00\x00\x00\x00".b
    target = "\xFF\x00\xFF\x00".b
    patch  = build_ups(source, target)
    result = Gemba::RomPatcher::UPS.apply(source, patch)
    assert_equal target, result
  end

  def test_ups_multiple_hunks
    source = "\x00" * 16
    target = source.dup.b
    target.setbyte(0,  0xAA)
    target.setbyte(8,  0xBB)
    target.setbyte(15, 0xCC)
    patch  = build_ups(source.b, target)
    result = Gemba::RomPatcher::UPS.apply(source.b, patch)
    assert_equal target, result
  end

  def test_ups_crc_mismatch_raises
    source = blank_rom(8)
    target = "\xCA\xFE\xBA\xBE\x00\x00\x00\x00".b
    patch  = build_ups(source, target)
    bad_patch = patch.dup.b
    bad_patch[-12] = "\x00".b
    bad_patch[-11] = "\x00".b
    err = assert_raises(RuntimeError) { Gemba::RomPatcher::UPS.apply(source, bad_patch) }
    assert_match(/CRC32/, err.message)
  end

  def test_ups_identical_source_and_target
    source = "GEMBA\x00\x00\x00".b
    target = source.dup
    patch  = build_ups(source, target)
    result = Gemba::RomPatcher::UPS.apply(source, patch)
    assert_equal target, result
  end

  def test_ups_pads_target_when_source_is_shorter
    # target_size > source_size — result zero-pads to target_size
    source = "\x01\x02".b
    target = "\x01\x03\x00\x00".b  # byte 1 differs; bytes 2-3 are 0 (matching padding)
    patch  = build_ups(source, target)
    result = Gemba::RomPatcher::UPS.apply(source, patch)
    assert_equal target, result
  end

  # ---------------------------------------------------------------------------
  # ZIP ROM input
  # ---------------------------------------------------------------------------

  def test_patch_with_zip_rom_produces_gba_output
    require 'zip'
    Dir.mktmpdir do |dir|
      # Build a tiny ROM and wrap it in a zip
      rom_data   = blank_rom
      zip_path   = File.join(dir, "game.zip")
      patch_path = File.join(dir, "fix.ips")
      out_path   = File.join(dir, "game-patched.gba")

      Zip::OutputStream.open(zip_path) do |zos|
        zos.put_next_entry("game.gba")
        zos.write(rom_data)
      end

      File.binwrite(patch_path, build_ips([{ offset: 0, data: "\xFF\xFE" }]))

      resolved = Gemba::RomResolver.resolve(zip_path)
      Gemba::RomPatcher.patch(rom_path: resolved, patch_path: patch_path, out_path: out_path)

      assert File.exist?(out_path), "expected output at #{out_path}"
      assert_equal ".gba", File.extname(out_path)
      assert_equal "\xFF".b, File.binread(out_path, 1)
    end
  end
end
