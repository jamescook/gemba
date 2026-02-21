# frozen_string_literal: true

# Smoke test for release: require the installed gem, verify version,
# load a test ROM, and run one frame.
#
# Usage: ruby scripts/smoke_test.rb <expected_version> <rom_path>

expected_version = ARGV[0] || abort("Usage: ruby #{$PROGRAM_NAME} <version> <rom_path>")
rom_path = ARGV[1] || abort("Usage: ruby #{$PROGRAM_NAME} <version> <rom_path>")

require "gemba"
require "gemba/version"

actual = Gemba::VERSION
abort "Version mismatch: expected #{expected_version}, got #{actual}" unless actual == expected_version

require "gemba/headless"
Gemba::HeadlessPlayer.open(rom_path) { |p| p.step(1) }

puts "release:smoke OK — gemba #{actual} loaded, 1 frame ran"
