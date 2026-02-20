# frozen_string_literal: true

# Minimal Core stub — no mGBA dependency, just a programmable memory map.
# Used by achievement backend tests to simulate bus reads without a real ROM.
class FakeCore
  def initialize
    @mem = Hash.new(0)
  end

  # Write a byte into the fake memory map.
  # @param address [Integer] GBA address
  # @param value   [Integer] 0..255
  def poke(address, value)
    @mem[address] = value & 0xFF
  end

  # Reads back what was poked (or 0 for anything not explicitly written).
  def bus_read8(address)
    @mem[address]
  end

  def destroyed?
    false
  end
end
