module Gemba
  # The two hot helpers under the .grec pipeline - ruby gemba implements
  # both in its C extension (Gemba.xor_delta/Gemba.count_changed_pixels);
  # plain Crystal loops over UInt32 words are the equivalent here.
  #
  # XOR is the whole compression idea: a GBA frame rarely changes much
  # between two frames, so current XOR previous is mostly zero bytes,
  # which zlib then squashes - and the transform is its own inverse, so
  # the decoder runs the exact same function to reconstruct.
  module FrameDelta
    # XORs `current` against `previous` word-by-word into `dest`. All
    # three must be the same size; dest may alias neither input.
    def self.xor_into(dest : Slice(UInt32), current : Slice(UInt32), previous : Slice(UInt32)) : Nil
      raise ArgumentError.new("size mismatch") unless dest.size == current.size && dest.size == previous.size

      dest.size.times { |i| dest.to_unsafe[i] = current.to_unsafe[i] ^ previous.to_unsafe[i] }
    end

    # How many pixels (32-bit words) of a delta are nonzero - the
    # per-frame change_pct byte the .grec format stores comes from this.
    def self.count_changed_pixels(delta : Slice(UInt32)) : Int32
      count = 0
      delta.each { |word| count += 1 unless word.zero? }
      count
    end
  end
end
