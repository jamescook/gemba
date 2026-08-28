require "digest/md5"

module Gemba
  module Achievements
    # The ROM identifier RetroAchievements looks games up by.
    #
    # GBA is one of the consoles rcheevos hashes with its generic
    # whole-file path (hash.c's rc_hash_whole_file, reached via the
    # RC_CONSOLE_GAMEBOY_ADVANCE case) - a plain MD5 of the file's bytes
    # with no header stripping or platform-specific fixups, so this
    # needs no rcheevos call to reproduce.
    module RomHash
      # rcheevos caps its own read at MAX_BUFFER_SIZE and hashes only
      # that much of a larger file. Matched here so an oversized file
      # still produces the same hash it would there, even though a real
      # GBA ROM (32MB ceiling) never reaches it.
      MAX_BYTES = 64 * 1024 * 1024

      CHUNK_BYTES = 65536

      def self.for_file(path : String) : String
        digest = Digest::MD5.new
        remaining = Math.min(File.size(path).to_i64, MAX_BYTES.to_i64)

        File.open(path) do |file|
          buffer = Bytes.new(CHUNK_BYTES)
          while remaining > 0
            read = file.read(buffer[0, Math.min(remaining, CHUNK_BYTES).to_i32])
            break if read == 0
            digest << buffer[0, read]
            remaining -= read
          end
        end

        digest.hexfinal
      end
    end
  end
end
