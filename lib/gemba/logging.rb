# frozen_string_literal: true

require 'logger'
require_relative 'config'

module Gemba
  # Session logger that writes to the user config logs/ directory.
  # File and directory are created lazily on first write.
  class SessionLogger
    MAX_LOG_FILES = 25
    LEVELS = { debug: Logger::DEBUG, info: Logger::INFO,
               warn: Logger::WARN, error: Logger::ERROR }.freeze

    # @param dir [String] log directory (default: Config.default_logs_dir)
    # @param level [Symbol] minimum log level (:debug, :info, :warn, :error)
    def initialize(dir: nil, level: :info)
      @dir = dir
      @level = LEVELS.fetch(level, Logger::INFO)
      @logger = nil
      prune
    end

    # Log a message at the given level. Uses block form to avoid
    # allocating the message string when the level is filtered.
    # @param level [Symbol] :debug, :info, :warn, :error
    def log(level, &block)
      severity = LEVELS.fetch(level, Logger::INFO)
      return if severity < @level

      ensure_logger
      @logger.add(severity, nil, 'gemba', &block)
    end

    # @return [String] resolved log directory
    def log_dir
      @dir ||= Config.default_logs_dir
    end

    private

    def ensure_logger
      return if @logger

      FileUtils.mkdir_p(log_dir)
      path = File.join(log_dir, "gemba-#{Time.now.strftime('%Y-%m-%d')}.log")
      @logger = Logger.new(path)
      @logger.level = @level
      @logger.formatter = proc { |sev, time, _prog, msg|
        "#{time.strftime('%H:%M:%S.%L')} [#{sev}] #{msg}\n"
      }
    end

    def prune
      dir = log_dir
      return unless File.directory?(dir)

      logs = Dir.glob(File.join(dir, 'gemba-*.log')).sort
      excess = logs.length - MAX_LOG_FILES
      return unless excess > 0

      logs.first(excess).each { |f| File.delete(f) }
    end
  end

  # Log a message. Lazily initializes the session logger.
  # @param level [Symbol] :debug, :info, :warn, :error
  # @example Gemba.log(:info) { "ROM loaded" }
  def self.log(level = :info, &block)
    logger.log(level, &block)
  end

  # @return [Gemba::SessionLogger]
  def self.logger
    @logger ||= SessionLogger.new
  end

  # Override the logger (useful for tests).
  # @param val [Gemba::SessionLogger, nil]
  def self.logger=(val)
    @logger = val
  end
end
