# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "gemba/headless"

class TestLogging < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("gemba-logs-test")
    @logger = Gemba::SessionLogger.new(dir: @dir, level: :info)
  end

  def teardown
    Gemba.logger = nil
    FileUtils.rm_rf(@dir)
  end

  # -- lazy file creation --

  def test_no_file_before_first_log
    assert_empty Dir.glob(File.join(@dir, "*.log"))
  end

  def test_file_created_on_first_log
    @logger.log(:info) { "hello" }
    logs = Dir.glob(File.join(@dir, "*.log"))
    assert_equal 1, logs.length
  end

  def test_file_named_by_date
    @logger.log(:info) { "hello" }
    logs = Dir.glob(File.join(@dir, "*.log"))
    assert_match(/gemba-\d{4}-\d{2}-\d{2}\.log/, File.basename(logs.first))
  end

  # -- level filtering --

  def test_filters_below_level
    @logger.log(:debug) { "should not appear" }
    assert_empty Dir.glob(File.join(@dir, "*.log")),
      "Debug message should not create log file at info level"
  end

  def test_allows_at_level
    @logger.log(:info) { "visible" }
    content = File.read(Dir.glob(File.join(@dir, "*.log")).first)
    assert_includes content, "visible"
  end

  def test_allows_above_level
    @logger.log(:error) { "bad thing" }
    content = File.read(Dir.glob(File.join(@dir, "*.log")).first)
    assert_includes content, "bad thing"
  end

  def test_debug_level_allows_debug
    logger = Gemba::SessionLogger.new(dir: @dir, level: :debug)
    logger.log(:debug) { "debug msg" }
    content = File.read(Dir.glob(File.join(@dir, "*.log")).first)
    assert_includes content, "debug msg"
  end

  # -- log format --

  def test_log_format
    @logger.log(:info) { "test message" }
    content = File.read(Dir.glob(File.join(@dir, "*.log")).first)
    assert_match(/\d{2}:\d{2}:\d{2}\.\d{3} \[INFO\] test message/, content)
  end

  # -- auto-prune --

  def test_prune_keeps_max_files
    # Create 30 fake log files
    30.times do |i|
      File.write(File.join(@dir, "gemba-2026-01-#{format('%02d', i + 1)}.log"), "old")
    end

    # New logger prunes on init
    Gemba::SessionLogger.new(dir: @dir, level: :info)

    remaining = Dir.glob(File.join(@dir, "gemba-*.log"))
    assert_equal Gemba::SessionLogger::MAX_LOG_FILES, remaining.length
  end

  def test_prune_keeps_newest
    30.times do |i|
      File.write(File.join(@dir, "gemba-2026-01-#{format('%02d', i + 1)}.log"), "old")
    end

    Gemba::SessionLogger.new(dir: @dir, level: :info)

    remaining = Dir.glob(File.join(@dir, "gemba-*.log")).sort
    # Should keep the last 25 (days 06-30)
    assert_equal "gemba-2026-01-06.log", File.basename(remaining.first)
    assert_equal "gemba-2026-01-30.log", File.basename(remaining.last)
  end

  def test_prune_no_op_when_under_limit
    3.times do |i|
      File.write(File.join(@dir, "gemba-2026-01-#{format('%02d', i + 1)}.log"), "ok")
    end

    Gemba::SessionLogger.new(dir: @dir, level: :info)
    assert_equal 3, Dir.glob(File.join(@dir, "gemba-*.log")).length
  end

  # -- module interface --

  def test_gemba_log_module_method
    Gemba.logger = Gemba::SessionLogger.new(dir: @dir, level: :info)
    Gemba.log(:info) { "module test" }
    content = File.read(Dir.glob(File.join(@dir, "*.log")).first)
    assert_includes content, "module test"
  end

  def test_gemba_logger_setter
    custom = Gemba::SessionLogger.new(dir: @dir, level: :warn)
    Gemba.logger = custom
    assert_same custom, Gemba.logger
  end
end
