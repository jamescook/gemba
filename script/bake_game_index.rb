#!/usr/bin/env ruby
# frozen_string_literal: true

# Parse No-Intro DAT files (from metadat/no-intro/) and produce a game index
# mapping game_code → canonical game name as JSON.
#
# The no-intro DAT format uses bare 4-char serials (e.g. "BPEE"), while mGBA's
# core.game_code returns platform-prefixed codes (e.g. "AGB-BPEE"). This script
# adds the appropriate prefix.
#
# Prerequisites:
#   ruby script/fetch_nointro_dat.rb
#
# Usage:
#   ruby script/bake_game_index.rb
#
# Output:
#   lib/gemba/data/gba_games.json      (game_code → name, serial-based)
#   lib/gemba/data/gb_games.json
#   lib/gemba/data/gbc_games.json
#   lib/gemba/data/gba_md5.json        (md5 → name, for all platforms)
#   lib/gemba/data/gb_md5.json
#   lib/gemba/data/gbc_md5.json

require "json"
require "fileutils"

DAT_DIR  = File.expand_path("../../tmp/dat", __FILE__)
DATA_DIR = File.expand_path("../../lib/gemba/data", __FILE__)

# Parse a no-intro DAT file.
# Format:
#   game (
#     name "Pokemon - Emerald Version (USA, Europe)"
#     region "USA"
#     serial "BPEE"
#     rom ( name "..." size N crc XXXXXXXX md5 YYYYYYYY sha1 ZZZZZZZZ serial "BPEE" )
#   )
# Returns array of hashes: { name:, region:, serial: (may be nil), md5: (may be nil) }
def parse_nointro_dat(path)
  entries = []
  current_name = nil
  current_region = nil
  current_serial = nil

  File.foreach(path) do |line|
    line.strip!
    if line =~ /^name "(.+)"$/
      current_name = $1
    elsif line =~ /^region "(.+)"$/
      current_region = $1
    elsif line =~ /^serial "(.+)"$/
      current_serial = $1
    elsif line =~ /^rom \(/
      # Extract md5 from rom line: md5 AABBCCDD...
      md5 = line[/\bmd5 ([0-9A-Fa-f]{32})\b/, 1]&.downcase
      # Also grab serial from rom line if not already set at game level
      rom_serial = line[/\bserial "([^"]+)"/, 1]
      serial = current_serial || rom_serial
      entries << { name: current_name, region: current_region, serial: serial, md5: md5 } if current_name
    elsif line == ")"
      current_name = nil
      current_region = nil
      current_serial = nil
    end
  end

  entries
end

FileUtils.mkdir_p(DATA_DIR)

# platform prefix that mGBA uses, and the DAT filename
systems = {
  gba: { prefix: "AGB", dat: "Nintendo - Game Boy Advance.dat" },
  gb:  { prefix: "DMG", dat: "Nintendo - Game Boy.dat" },
  gbc: { prefix: "CGB", dat: "Nintendo - Game Boy Color.dat" },
}

systems.each do |platform, info|
  dat_path = File.join(DAT_DIR, info[:dat])

  unless File.exist?(dat_path)
    warn "SKIP: #{dat_path} not found (run script/fetch_nointro_dat.rb first)"
    next
  end

  puts "Parsing #{info[:dat]} ..."
  raw_entries = parse_nointro_dat(dat_path)
  puts "  #{raw_entries.size} raw entries"

  # Build serial map: "AGB-BPEE" => "Pokemon - Emerald Version (USA, Europe)"
  # When multiple regions share a serial, prefer USA > World > Europe > first seen.
  by_code = {}
  raw_entries.each do |entry|
    next unless entry[:serial]
    key = "#{info[:prefix]}-#{entry[:serial]}"
    existing = by_code[key]
    region = entry[:region] || ""

    if existing.nil?
      by_code[key] = entry[:name]
    elsif region.include?("USA") && !existing.include?("(USA")
      by_code[key] = entry[:name]
    elsif region.include?("World") && !existing.include?("(USA") && !existing.include?("(World")
      by_code[key] = entry[:name]
    end
  end

  puts "  #{by_code.size} unique game codes"

  json_path = File.join(DATA_DIR, "#{platform}_games.json")
  File.write(json_path, JSON.generate(by_code.sort.to_h))
  puts "  #{json_path} (#{File.size(json_path)} bytes)"

  # Build MD5 map: lowercase md5 => canonical name
  # Prefer USA > World > Europe > first seen when multiple regions share an MD5 (unlikely).
  by_md5 = {}
  raw_entries.each do |entry|
    next unless entry[:md5]
    existing = by_md5[entry[:md5]]
    region = entry[:region] || ""

    if existing.nil?
      by_md5[entry[:md5]] = entry[:name]
    elsif region.include?("USA") && !existing.include?("(USA")
      by_md5[entry[:md5]] = entry[:name]
    end
  end

  puts "  #{by_md5.size} unique MD5s"

  md5_path = File.join(DATA_DIR, "#{platform}_md5.json")
  File.write(md5_path, JSON.generate(by_md5.sort.to_h))
  puts "  #{md5_path} (#{File.size(md5_path)} bytes)"
end

puts "\nDone."
