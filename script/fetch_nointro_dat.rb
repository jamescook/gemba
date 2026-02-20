#!/usr/bin/env ruby
# frozen_string_literal: true

# Fetch No-Intro DAT files from libretro-database for GBA/GB/GBC.
# Uses the metadat/no-intro/ path which has better coverage than metadat/serial/.
#
# Usage:
#   ruby script/fetch_nointro_dat.rb
#
# Output:
#   tmp/dat/Nintendo - Game Boy Advance.dat
#   tmp/dat/Nintendo - Game Boy.dat
#   tmp/dat/Nintendo - Game Boy Color.dat

require "net/http"
require "uri"
require "fileutils"

REPO = "libretro/libretro-database"
BRANCH = "master"
DAT_DIR = File.expand_path("../../tmp/dat", __FILE__)

SYSTEMS = {
  "Nintendo - Game Boy Advance" => "metadat/no-intro/Nintendo - Game Boy Advance.dat",
  "Nintendo - Game Boy"         => "metadat/no-intro/Nintendo - Game Boy.dat",
  "Nintendo - Game Boy Color"   => "metadat/no-intro/Nintendo - Game Boy Color.dat",
}

FileUtils.mkdir_p(DAT_DIR)

SYSTEMS.each do |label, path|
  puts "Downloading #{label} ..."

  encoded = path.split("/").map { |seg| URI.encode_www_form_component(seg).gsub("+", "%20") }.join("/")
  url = "https://raw.githubusercontent.com/#{REPO}/#{BRANCH}/#{encoded}"
  uri = URI(url)
  response = Net::HTTP.get_response(uri)

  if response.is_a?(Net::HTTPSuccess)
    out_path = File.join(DAT_DIR, File.basename(path))
    File.write(out_path, response.body)
    lines = response.body.lines.size
    bytes = response.body.bytesize
    puts "  Saved #{out_path} (#{lines} lines, #{bytes} bytes)"
  else
    warn "  FAILED: HTTP #{response.code} for #{url}"
  end
end

puts "\nDone. DAT files in #{DAT_DIR}"
