require "../spec_helper"
require "file_utils"

private def with_log_dir(&)
  dir = File.tempname("session_logger_spec")
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def log_contents(dir : String) : String
  File.read(Dir.glob(File.join(dir, "gemba-*.log")).first)
end

describe Gemba::SessionLogger do
  it "writes HH:MM:SS.mmm [LEVEL] message lines, matching ruby gemba's format" do
    with_log_dir do |dir|
      logger = Gemba::SessionLogger.new(dir)
      logger.log { "hello" }
      logger.log(Gemba::SessionLogger::Level::Warn) { "careful" }
      logger.close

      lines = log_contents(dir).lines
      lines.size.should eq 2
      lines[0].should match(/^\d{2}:\d{2}:\d{2}\.\d{3} \[INFO\] hello$/)
      lines[1].should match(/^\d{2}:\d{2}:\d{2}\.\d{3} \[WARN\] careful$/)
    end
  end

  it "filters out messages below the configured level" do
    with_log_dir do |dir|
      logger = Gemba::SessionLogger.new(dir, Gemba::SessionLogger::Level::Warn)
      logger.log(Gemba::SessionLogger::Level::Debug) { "noise" }
      logger.log(Gemba::SessionLogger::Level::Info) { "also noise" }
      logger.log(Gemba::SessionLogger::Level::Error) { "kept" }
      logger.close

      contents = log_contents(dir)
      contents.should_not contain "noise"
      contents.should contain "kept"
    end
  end

  it "never evaluates a filtered-out message's block" do
    with_log_dir do |dir|
      logger = Gemba::SessionLogger.new(dir, Gemba::SessionLogger::Level::Error)
      called = false
      logger.log(Gemba::SessionLogger::Level::Debug) { called = true; "expensive" }
      logger.close

      called.should be_false
    end
  end

  it "names the file for today's date" do
    with_log_dir do |dir|
      logger = Gemba::SessionLogger.new(dir)
      logger.close
      expected = "gemba-#{Time.local.to_s("%Y-%m-%d")}.log"
      File.exists?(File.join(dir, expected)).should be_true
    end
  end

  it "prunes to the newest MAX_LOG_FILES on construction" do
    with_log_dir do |dir|
      Dir.mkdir_p(dir)
      30.times { |i| File.write(File.join(dir, "gemba-2020-01-#{(i + 1).to_s.rjust(2, '0')}.log"), "old") }

      logger = Gemba::SessionLogger.new(dir)
      logger.close

      remaining = Dir.glob(File.join(dir, "gemba-*.log")).sort!
      # 25 kept from the 30 seeded, plus today's freshly-opened file.
      remaining.size.should eq Gemba::SessionLogger::MAX_LOG_FILES + 1
      remaining.should_not contain File.join(dir, "gemba-2020-01-01.log")
      remaining.should contain File.join(dir, "gemba-2020-01-30.log")
    end
  end

  it "Gemba.log is a no-op when no logger has been assigned" do
    previous = Gemba.logger
    Gemba.logger = nil
    begin
      Gemba.log { "goes nowhere" }
    ensure
      Gemba.logger = previous
    end
  end

  it "Gemba.log routes through an assigned logger" do
    with_log_dir do |dir|
      previous = Gemba.logger
      logger = Gemba::SessionLogger.new(dir)
      Gemba.logger = logger
      begin
        Gemba.log { "via module helper" }
        log_contents(dir).should contain "via module helper"
      ensure
        logger.close
        Gemba.logger = previous
      end
    end
  end
end

describe Gemba::Achievements::RetroAchievements::Backend do
  it ".redact hides the password and token but keeps everything else" do
    redacted = Gemba::Achievements::RetroAchievements::Backend.redact(
      {"r" => "login2", "u" => "someone", "p" => "hunter2", "t" => "tok123"})

    redacted.should contain "r=login2"
    redacted.should contain "u=someone"
    redacted.should_not contain "hunter2"
    redacted.should_not contain "tok123"
    redacted.should contain "p=[redacted]"
    redacted.should contain "t=[redacted]"
  end
end
