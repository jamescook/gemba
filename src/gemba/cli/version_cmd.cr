module Gemba
  module CLI
    # `gemba version` - prints the version and exits; never touches
    # Tk/SDL at runtime.
    class VersionCmd
      record Plan, version : String

      def initialize(@dry_run : Bool = false, @io : IO = STDOUT)
      end

      def call : Plan
        @io.puts "gemba #{Gemba::VERSION}" unless @dry_run
        Plan.new(version: Gemba::VERSION)
      end
    end
  end
end
