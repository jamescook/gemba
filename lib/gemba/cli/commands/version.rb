# frozen_string_literal: true

require 'gemba/version'

module Gemba
  class CLI
    module Commands
      class Version
        def initialize(argv, dry_run: false)
          @dry_run = dry_run
        end

        def call
          result = { command: :version, version: Gemba::VERSION }
          return result if @dry_run

          puts "gemba #{Gemba::VERSION}"
        end
      end
    end
  end
end
