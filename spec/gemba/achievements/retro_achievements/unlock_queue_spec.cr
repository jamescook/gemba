require "../../../spec_helper"
require "file_utils"

private alias UnlockQueue = Gemba::Achievements::RetroAchievements::UnlockQueue
private alias FakeRequester = Gemba::Achievements::RetroAchievements::FakeRequester

# Millisecond stand-in for the real 30s/5min schedule - the same
# doubling and cap, fast enough to watch several attempts play out.
private FAST = UnlockQueue::Schedule.new(20.milliseconds, 80.milliseconds, 10)

private record Harness, app : Tryst::App, fake : FakeRequester, queue : UnlockQueue, log_dir : String do
  # Read off Tk's thread, same as every file read MainWindow does -
  # tryst's syscall guard flags a blocking open on it.
  def log : String
    dir = log_dir
    app.off_thread { File.read(Dir.glob(File.join(dir, "gemba-*.log")).first) }
  end

  # Services Tk (and so the queue's after timers) for a while - for
  # asserting that a retry does NOT happen.
  def pump(duration : Time::Span) : Nil
    deadline = Time.monotonic + duration
    while Time.monotonic < deadline
      app.update
      sleep 5.milliseconds
    end
  end
end

# Routes Gemba.log into a fresh file for the block, so the queue's
# lines can be asserted on without the rest of the suite's noise.
private def with_queue(schedule : UnlockQueue::Schedule = FAST, token : String = "tok123", &)
  log_dir = File.tempname("unlock_queue_spec")
  app = Tryst::UI::Session.new(title: "unlock_queue_spec").run_async.app
  previous_logger = Gemba.logger
  logger = app.off_thread { Gemba::SessionLogger.new(log_dir) }
  Gemba.logger = logger

  fake = FakeRequester.new
  backend = Gemba::Achievements::RetroAchievements::Backend.new(app, fake.to_proc)
  queue = UnlockQueue.new(app, backend, schedule) { {"someone", token} }
  begin
    yield Harness.new(app, fake, queue, log_dir)
  ensure
    app.destroy
    logger.close
    Gemba.logger = previous_logger
    FileUtils.rm_rf(log_dir)
  end
end

describe UnlockQueue::Schedule do
  it "doubles from the initial delay up to the ceiling" do
    schedule = UnlockQueue::Schedule::DEFAULT
    schedule.delay_before(2).should eq 30.seconds
    schedule.delay_before(3).should eq 60.seconds
    schedule.delay_before(4).should eq 120.seconds
    schedule.delay_before(5).should eq 240.seconds
    schedule.delay_before(6).should eq 5.minutes
    schedule.delay_before(10).should eq 5.minutes
  end

  it "defaults to ten attempts - about half an hour against a dead server" do
    schedule = UnlockQueue::Schedule::DEFAULT
    schedule.max_attempts.should eq 10
    total = (2..schedule.max_attempts).sum { |attempt| schedule.delay_before(attempt) }
    total.should eq 1950.seconds
  end
end

describe UnlockQueue do
  it "an accepted submission is confirmed straight away and never queued" do
    with_queue do |harness|
      harness.queue.submit(7_u32)
      harness.app.interp.wait_until(5.seconds) { harness.fake.awarded_ids.size == 1 }
      harness.pump(100.milliseconds)

      harness.queue.pending_ids.should be_empty
      harness.fake.awarded_ids.should eq [7_i64]
      harness.log.should contain "[INFO] RA: submitted unlock for achievement 7"
    end
  end

  it "a failed submission is queued and goes through once the site accepts it" do
    with_queue do |harness|
      harness.fake.award_fails = true
      harness.queue.submit(7_u32)
      harness.app.interp.wait_until(5.seconds) { harness.queue.pending_ids == [7_u32] }

      harness.fake.award_fails = false
      harness.app.interp.wait_until(5.seconds) { harness.queue.pending_ids.empty? }
      harness.pump(200.milliseconds)

      # Exactly one retry was needed, and none went out after the
      # site had said yes.
      harness.fake.awarded_ids.should eq [7_i64, 7_i64]
      harness.log.should contain "[INFO] RA: unlock submission failed for achievement 7: FakeRequester: award refused - queued for retry"
      harness.log.should contain "[INFO] RA: retry succeeded for achievement 7 (attempt 2/10)"
    end
  end

  it "reports every failed retry with its attempt number and the site's error" do
    with_queue(UnlockQueue::Schedule.new(10.milliseconds, 40.milliseconds, 3)) do |harness|
      harness.fake.award_fails = true
      harness.queue.submit(7_u32)
      harness.app.interp.wait_until(5.seconds) { harness.fake.awarded_ids.size == 2 }

      harness.log.should contain "[WARN] RA: retry 2/3 failed for achievement 7: FakeRequester: award refused"
    end
  end

  it "gives up after the attempt cap rather than retrying forever" do
    with_queue(UnlockQueue::Schedule.new(10.milliseconds, 40.milliseconds, 3)) do |harness|
      harness.fake.award_fails = true
      harness.queue.submit(7_u32)
      harness.app.interp.wait_until(5.seconds) { harness.fake.awarded_ids.size == 3 && harness.queue.pending_ids.empty? }
      harness.pump(300.milliseconds)

      harness.fake.awarded_ids.should eq [7_i64, 7_i64, 7_i64]
      harness.log.should contain "[ERROR] RA: giving up on achievement 7 after 3 attempts - unlock never confirmed by the site"
    end
  end

  it "#shutdown drops what is still pending, says so, and sends nothing more" do
    with_queue do |harness|
      harness.fake.award_fails = true
      # One at a time: two in-flight first attempts can fail in either
      # order, and the queue keeps them in the order they failed.
      harness.queue.submit(7_u32)
      harness.app.interp.wait_until(5.seconds) { harness.queue.pending_ids == [7_u32] }
      harness.queue.submit(8_u32)
      harness.app.interp.wait_until(5.seconds) { harness.queue.pending_ids == [7_u32, 8_u32] }

      harness.queue.shutdown
      sent = harness.fake.awarded_ids.size
      harness.pump(300.milliseconds)

      harness.queue.pending_ids.should be_empty
      harness.fake.awarded_ids.size.should eq sent
      harness.log.should contain "[WARN] RA: 2 unlock(s) never confirmed - dropped on exit: 7, 8"
    end
  end

  it "#shutdown with nothing pending is silent" do
    with_queue do |harness|
      harness.queue.shutdown
      harness.log.should_not contain "never confirmed"
    end
  end

  it "reads credentials fresh for every attempt, so a re-login reaches the retry" do
    token = "old-token"
    with_queue(token: token) do |harness|
      # The block captured the String value, so swap the queue for one
      # that reads the variable instead.
      backend = Gemba::Achievements::RetroAchievements::Backend.new(harness.app, harness.fake.to_proc)
      queue = UnlockQueue.new(harness.app, backend, FAST) { {"someone", token} }

      harness.fake.award_fails = true
      queue.submit(7_u32)
      harness.app.interp.wait_until(5.seconds) { harness.fake.awarded_ids.size == 1 }

      token = "new-token"
      harness.fake.award_fails = false
      harness.app.interp.wait_until(5.seconds) { queue.pending_ids.empty? }

      awards = harness.fake.requests.select { |request| request["r"]? == "awardachievement" }
      awards.map { |request| request["t"]? }.should eq ["old-token", "new-token"]
    end
  end
end
