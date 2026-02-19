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
#   lib/gemba/data/gba_games.json
#   lib/gemba/data/gb_games.json
#   lib/gemba/data/gbc_games.json

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
#     rom ( ... )
#   )
def parse_nointro_dat(path)
  entries = []
  current_name = nil
  current_region = nil

  File.foreach(path) do |line|
    line.strip!
    if line =~ /^name "(.+)"$/
      current_name = $1
    elsif line =~ /^region "(.+)"$/
      current_region = $1
    elsif line =~ /^serial "(.+)"$/
      serial = $1
      if current_name && !serial.empty?
        entries << { serial: serial, name: current_name, region: current_region }
      end
    elsif line == ")"
      current_name = nil
      current_region = nil
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

  # Build map: "AGB-BPEE" => "Pokemon - Emerald Version (USA, Europe)"
  # When multiple regions share a serial, prefer USA > World > Europe > first seen.
  by_code = {}
  raw_entries.each do |entry|
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
end

puts "\nDone."
