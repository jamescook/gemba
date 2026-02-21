# frozen_string_literal: true

require 'optparse'

module Gemba
  class CLI
    module Commands
      class Patch
        def initialize(argv, dry_run: false)
          @argv = argv
          @dry_run = dry_run
        end

        def call
          options = parse

          if options[:help]
            puts options[:parser] unless @dry_run
            return { command: :patch, help: true }
          end

          unless options[:rom] && options[:patch]
            $stderr.puts "gemba patch: ROM_FILE and PATCH_FILE are required"
            $stderr.puts options[:parser]
            return { command: :patch, error: :missing_args }
          end

          rom_path   = options[:rom]
          patch_path = options[:patch]
          out_path   = if options[:output]
                         options[:output]
                       else
                         ext  = File.extname(rom_path)
                         base = rom_path.chomp(ext)
                         "#{base}-patched#{ext}"
                       end

          result = { command: :patch, rom: rom_path, patch: patch_path, out: out_path }
          return result if @dry_run

          require "gemba/rom_patcher"
          require "gemba/rom_patcher/ips"
          require "gemba/rom_patcher/bps"
          require "gemba/rom_patcher/ups"

          safe_out = RomPatcher.safe_out_path(out_path)
          puts "Patching #{File.basename(rom_path)} with #{File.basename(patch_path)}…"
          RomPatcher.patch(rom_path: rom_path, patch_path: patch_path, out_path: safe_out)
          puts "Written: #{safe_out}"
        end

        def parse
          options = {}
          argv = @argv.dup

          parser = OptionParser.new do |o|
            o.banner = "Usage: gemba patch [options] ROM_FILE PATCH_FILE"
            o.separator ""
            o.separator "Apply an IPS, BPS, or UPS patch to a ROM file."
            o.separator ""
            o.separator "The output file is written to --output or, by default, next to the ROM."
            o.separator "If the output path already exists, -(2), -(3) etc. are appended."
            o.separator ""

            o.on("-o", "--output PATH", "Output ROM path") { |v| options[:output] = File.expand_path(v) }
            o.on("-h", "--help", "Show this help") { options[:help] = true }
          end

          parser.parse!(argv)
          options[:rom]   = File.expand_path(argv[0]) if argv[0]
          options[:patch] = File.expand_path(argv[1]) if argv[1]
          options[:parser] = parser
          options
        end
      end
    end
  end
end
