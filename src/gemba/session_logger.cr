require "./paths"

module Gemba
  # Assigned once at startup (MainWindow builds the logger through
  # App#off_thread). Deliberately NOT lazily created on first #log:
  # SessionLogger.new opens a file, and doing that implicitly from
  # whatever call site logged first would put a blocking open on Tk's
  # thread. Unset means logging is a no-op, which is what specs and
  # any non-MainWindow entry point get.
  class_property logger : SessionLogger? = nil

  def self.log(level : SessionLogger::Level = SessionLogger::Level::Info, &block : -> String) : Nil
    @@logger.try(&.log(level, &block))
  end

  # Rotating daily log file, ported from ruby gemba's SessionLogger
  # (same filename shape, line format and retention, so existing logs
  # stay readable across the port).
  #
  # Opens its file eagerly in #initialize, which is why callers build it
  # through App#off_thread - see MainWindow's own construction of
  # BoxartFetcher/RomOverrides for the same pattern. Every #log call
  # after that writes to the already-open fd, which never reaches
  # Fiber.syscall at all (see tryst's syscall_guard.cr) and so is safe
  # to call directly from Tk's thread.
  class SessionLogger
    MAX_LOG_FILES = 25

    enum Level
      Debug
      Info
      Warn
      Error
    end

    getter log_dir : String

    def initialize(@log_dir : String = Paths.logs_dir, @level : Level = Level::Info)
      Dir.mkdir_p(@log_dir)
      prune
      @file = File.open(File.join(@log_dir, "gemba-#{Time.local.to_s("%Y-%m-%d")}.log"), "a")
      @file.sync = true
    end

    # Block form so a filtered-out message never builds its string.
    def log(level : Level = Level::Info, &block : -> String) : Nil
      return if level < @level
      @file.puts("#{Time.local.to_s("%H:%M:%S.%L")} [#{level.to_s.upcase}] #{block.call}")
    end

    def close : Nil
      @file.close unless @file.closed?
    end

    private def prune : Nil
      logs = Dir.glob(File.join(@log_dir, "gemba-*.log")).sort!
      excess = logs.size - MAX_LOG_FILES
      return unless excess > 0
      logs.first(excess).each { |path| File.delete(path) }
    end
  end
end
