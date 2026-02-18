#!/usr/bin/env ruby

# Generates a minimal valid GBC ROM for testing gemba.
#
# Identical to the GB ROM except the CGB flag at 0x143 is set to 0xC0
# (GBC only), causing mGBA to detect it as a Game Boy Color ROM.
#
# GBC cartridge header reference:
#   https://gbdev.io/pandocs/The_Cartridge_Header.html
#
# Usage:
#   ruby scripts/generate_test_gbc_rom.rb
#
# Output:
#   test/fixtures/test.gbc

rom = "\x00".b * 32768  # 32 KB minimum ROM

# 0x100..0x103: Entry point — NOP then JP 0x0150
rom[0x100] = "\x00".b        # NOP
rom[0x101, 3] = "\xC3\x50\x01".b  # JP 0x0150

# 0x104..0x133: Nintendo logo (required for boot validation)
nintendo_logo = [
  0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B,
  0x03, 0x73, 0x00, 0x83, 0x00, 0x0C, 0x00, 0x0D,
  0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
  0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99,
  0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC,
  0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
].pack("C*")
rom[0x104, 48] = nintendo_logo

# 0x134..0x142: Title (15 bytes, padded with NUL)
rom[0x134, 15] = "GEMBAGBC\x00\x00\x00\x00\x00\x00\x00".b

# 0x143: CGB flag — 0xC0 = GBC only
rom.setbyte(0x143, 0xC0)

# 0x147: Cartridge type — 0x00 = ROM ONLY
rom.setbyte(0x147, 0x00)

# 0x148: ROM size — 0x00 = 32 KB (2 banks)
rom.setbyte(0x148, 0x00)

# 0x149: RAM size — 0x00 = no RAM
rom.setbyte(0x149, 0x00)

# 0x14A: Destination code — 0x01 = non-Japanese
rom.setbyte(0x14A, 0x01)

# 0x14D: Header checksum — sum of bytes 0x134..0x14C
# chk = 0; for i in 0x134..0x14C: chk = chk - rom[i] - 1
chk = 0
(0x134..0x14C).each { |i| chk = (chk - rom.getbyte(i) - 1) & 0xFF }
rom.setbyte(0x14D, chk)

# 0x150: Program start — HALT loop
rom[0x150] = "\x76".b          # HALT
rom[0x151] = "\x18".b          # JR
rom[0x152] = "\xFC".b          # offset -4 (back to HALT)

out = File.expand_path("../test/fixtures/test.gbc", __dir__)
File.binwrite(out, rom)
puts "Wrote #{rom.bytesize} bytes to #{out}"
