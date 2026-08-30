require "option_parser"
require "../rom_patcher"

module Gemba
  module CLI
    # `gemba patch` - apply an IPS/BPS/UPS patch to a ROM, headless,
    # through the same RomPatcher the patcher window uses. Ruby's
    # contract: two positionals, -o for the output path, default output
    # next to the ROM as NAME-patched.EXT, and an existing output never
    # overwritten (-(2), -(3)... appended). The format comes from the
    # patch file's magic bytes; --format forces one (not in ruby - the
    # extension tells you nothing and the magic everything, but the
    # override costs nothing for odd files).
    class Patch
      record Plan,
        rom : String? = nil, patch : String? = nil, out_path : String? = nil,
        format : Symbol? = nil, help : Bool = false

      FORMATS = {"ips" => :ips, "bps" => :bps, "ups" => :ups}

      def initialize(@argv : Array(String), @dry_run : Bool = false, @io : IO = STDOUT)
      end

      def call : Plan
        plan = parse

        if plan.help
          @io.puts @parser unless @dry_run
          return plan
        end

        rom = plan.rom
        patch = plan.patch
        raise Error.new("gemba patch: ROM_FILE and PATCH_FILE are required") unless rom && patch
        return plan if @dry_run

        raise Error.new("ROM file not found: #{rom}") unless File.exists?(rom)
        raise Error.new("Patch file not found: #{patch}") unless File.exists?(patch)

        safe_out = RomPatcher.safe_out_path(plan.out_path.as(String))
        @io.puts "Patching #{File.basename(rom)} with #{File.basename(patch)}..."
        begin
          RomPatcher.patch(rom_path: rom, patch_path: patch, out_path: safe_out, format: plan.format)
        rescue ex : RomPatcher::Error
          raise Error.new(ex.message)
        end
        @io.puts "Written: #{safe_out}"
        plan
      end

      private def parse : Plan
        output = nil.as(String?)
        format = nil.as(Symbol?)
        help = false
        positionals = [] of String

        parser = OptionParser.new do |opts|
          opts.banner = <<-BANNER
            Usage: gemba patch [options] ROM_FILE PATCH_FILE

            Apply an IPS, BPS, or UPS patch to a ROM file.

            The output file is written to --output or, by default, next to
            the ROM as NAME-patched.EXT. If the output path already exists,
            -(2), -(3) etc. are appended - nothing is ever overwritten.
            BANNER
          opts.on("-o PATH", "--output PATH", "Output ROM path") { |value| output = File.expand_path(value) }
          opts.on("--format FORMAT", "Force ips/bps/ups instead of magic-byte detection") do |value|
            format = FORMATS[value.downcase]? ||
                     raise Error.new("gemba patch: unknown patch format #{value.inspect} (expected ips, bps or ups)")
          end
          opts.on("-h", "--help", "Show this help") { help = true }
          opts.unknown_args { |before_dash, after_dash| positionals = before_dash + after_dash }
          opts.invalid_option do |flag|
            @io.puts "gemba patch: unknown option #{flag}"
            help = true
          end
        end
        @parser = parser
        parser.parse(@argv.dup)

        rom = positionals[0]?.try { |path| File.expand_path(path) }
        patch = positionals[1]?.try { |path| File.expand_path(path) }
        Plan.new(rom: rom, patch: patch, out_path: default_out(rom, output), format: format, help: help)
      end

      # --output wins; otherwise NAME-patched.EXT beside the ROM,
      # ruby's own default.
      private def default_out(rom : String?, output : String?) : String?
        return output if output
        return unless rom
        ext = File.extname(rom)
        rom.rchop(ext) + "-patched" + ext
      end

      @parser : OptionParser?
    end
  end
end
