require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("main_window_achievements_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def new_window(dir : String, &requester : Hash(String, String) -> {JSON::Any?, Bool}) : Gemba::MainWindow
  Gemba::MainWindow.new(
    rom_library_path: File.join(dir, "rom_library.json"),
    config_path: File.join(dir, "settings.json"),
    gamepad_polling: false,
    ra_requester: requester,
  )
end

describe Gemba::MainWindow do
  describe "RetroAchievements login wiring" do
    it "a successful login persists username/token and updates the Achievements tab" do
      with_tempdir do |dir|
        window = new_window(dir) { |_params| {JSON.parse(%({"Success":true,"Token":"tok123"})), true} }
        begin
          window.show_settings
          window.settings_window.select_achievements_tab

          window.events.ra_login_requested.emit("someone", "hunter2")
          window.app.interp.wait_until(5.seconds) { window.config.ra_token == "tok123" }

          window.config.ra_username.should eq "someone"
          window.config.ra_token.should eq "tok123"
        ensure
          window.app.destroy
        end
      end
    end

    it "a failed login leaves Config untouched" do
      with_tempdir do |dir|
        window = new_window(dir) { |_params| {JSON.parse(%({"Success":false,"Error":"Invalid User/Password combination."})), true} }
        begin
          window.events.ra_login_requested.emit("someone", "wrong")
          window.app.interp.wait_until(5.seconds) { window.settings_window.achievements_tab.feedback_text == "Invalid User/Password combination." }

          window.config.ra_token.should eq ""
          window.config.ra_username.should eq ""
        ensure
          window.app.destroy
        end
      end
    end

    it "logout clears the token but keeps the username" do
      with_tempdir do |dir|
        window = new_window(dir) { |_params| {JSON.parse(%({"Success":true,"Token":"tok123"})), true} }
        begin
          window.events.ra_login_requested.emit("someone", "hunter2")
          window.app.interp.wait_until(5.seconds) { window.config.ra_token == "tok123" }

          window.events.ra_logout_requested.emit
          window.config.ra_token.should eq ""
          window.config.ra_username.should eq "someone"
        ensure
          window.app.destroy
        end
      end
    end

    it "reset clears both username and token" do
      with_tempdir do |dir|
        window = new_window(dir) { |_params| {JSON.parse(%({"Success":true,"Token":"tok123"})), true} }
        begin
          window.events.ra_login_requested.emit("someone", "hunter2")
          window.app.interp.wait_until(5.seconds) { window.config.ra_token == "tok123" }

          window.events.ra_reset_requested.emit
          window.config.ra_token.should eq ""
          window.config.ra_username.should eq ""
        ensure
          window.app.destroy
        end
      end
    end
  end
end

private FILL_ROM = File.join(__DIR__, "..", "fixtures", "fill.gba")

# Keeps Tk and the spawned request/worker-message fibers serviced for
# a while - for asserting that something does NOT happen, where there
# is nothing to wait_until on.
private def pump(window : Gemba::MainWindow, duration : Time::Span) : Nil
  deadline = Time.monotonic + duration
  while Time.monotonic < deadline
    window.app.update
    sleep 20.milliseconds
  end
end

# #stop only sends the worker a Stop message - asynchronous, per
# BackgroundWork#close - so it has to be awaited via #done? before
# destroying the app out from under it. Skipping this raced the
# worker's per-frame evaluation against Tk/SDL viewport teardown often
# enough to segfault under Docker/Xvfb - not a flake, reproduced every
# time a window spec ran after any other window in the same process.
private def stop_worker_then_destroy(window : Gemba::MainWindow) : Nil
  if worker = window.worker
    worker.stop
    window.app.interp.wait_until(5.seconds) { worker.done? }
  end
  window.app.destroy
end

private def index_of(fake : Gemba::Achievements::RetroAchievements::FakeRequester, r : String) : Int32
  fake.requests.index { |request| request["r"]? == r } || -1
end

private def ra_window(dir : String, fake : Gemba::Achievements::RetroAchievements::FakeRequester,
                      retry_schedule = Gemba::Achievements::RetroAchievements::UnlockQueue::Schedule::DEFAULT) : Gemba::MainWindow
  window = Gemba::MainWindow.new(
    rom_library_path: File.join(dir, "rom_library.json"),
    config_path: File.join(dir, "settings.json"),
    gamepad_polling: false,
    ra_requester: fake.to_proc,
    ra_retry_schedule: retry_schedule,
  )
  window.config.ra_enabled = true
  window.config.ra_rich_presence = false
  window.config.ra_screenshot_on_unlock = false
  window.config.ra_username = "someone"
  window.config.ra_token = "tok123"
  window
end

# A hit-count target - met after N frames whatever the ROM keeps at
# that address; see ra_runtime_spec's note on rcheevos' WAITING state.
private def fake_achievement(id : Int64, title : String, frames : Int32 = 30) : JSON::Any
  Gemba::Achievements::RetroAchievements::FakeRequester.achievement(id, "0xH0000>=0.#{frames}.", title: title)
end

describe Gemba::MainWindow do
  describe "rich presence" do
    # Orchestration only: hash -> gameid -> patch -> first ping. That
    # the string is really evaluated from live memory is covered in
    # emulation_worker_spec, without a window rendering for ~4s.
    it "a ROM load resolves the game against RA and starts the ping heartbeat" do
      with_tempdir do |dir|
        fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
          game_id: 515_i64, script: "Display:\nIWRAM0 @Number(0xH0000)")

        window = Gemba::MainWindow.new(
          rom_library_path: File.join(dir, "rom_library.json"),
          config_path: File.join(dir, "settings.json"),
          gamepad_polling: false,
          ra_requester: fake.to_proc,
        )

        begin
          window.config.ra_enabled = true
          window.config.ra_rich_presence = true
          window.config.ra_username = "someone"
          window.config.ra_token = "tok123"

          window.load_rom(FILL_ROM)

          window.app.interp.wait_until(10.seconds) do
            fake.requests.any? { |request| request["r"]? == "ping" }
          end

          fake.requests.any? { |request| request["r"]? == "gameid" }.should be_true
          fake.requests.any? { |request| request["r"]? == "patch" && request["g"]? == "515" }.should be_true
          # Heartbeat starts immediately rather than one full interval
          # later, so the site shows the session right away.
          fake.requests.any? { |request| request["r"]? == "ping" && request["g"]? == "515" }.should be_true
        ensure
          # #stop only sends the worker a Stop message - asynchronous,
          # per BackgroundWork#close - so it has to be awaited via
          # #done? (same pattern emulation_worker_spec.cr uses
          # everywhere) before destroying the app out from under it.
          # Skipping this raced the worker's per-frame rich-presence
          # sampling against Tk/SDL viewport teardown often enough to
          # segfault under Docker/Xvfb - not a flake, reproduced every
          # time this test ran after any other window in the same
          # process.
          if worker = window.worker
            worker.stop
            window.app.interp.wait_until(5.seconds) { worker.done? }
          end
          window.app.destroy
        end
      end
    end

    it "stays off when the rich presence switch is disabled, while achievements still load" do
      with_tempdir do |dir|
        fake = Gemba::Achievements::RetroAchievements::FakeRequester.new

        window = Gemba::MainWindow.new(
          rom_library_path: File.join(dir, "rom_library.json"),
          config_path: File.join(dir, "settings.json"),
          gamepad_polling: false,
          ra_requester: fake.to_proc,
        )

        begin
          window.config.ra_enabled = true
          window.config.ra_rich_presence = false
          window.config.ra_username = "someone"
          window.config.ra_token = "tok123"

          window.load_rom(FILL_ROM)
          window.app.interp.wait_until(10.seconds) do
            fake.requests.any? { |request| request["r"]? == "unlocks" }
          end
          pump(window, 500.milliseconds)

          fake.requests.any? { |request| request["r"]? == "ping" }.should be_false
        ensure
          # See the "starts the ping heartbeat" test above: #stop is
          # async, so it has to be awaited via #done? before destroying
          # the app out from under the worker.
          if worker = window.worker
            worker.stop
            window.app.interp.wait_until(5.seconds) { worker.done? }
          end
          window.app.destroy
        end
      end
    end
  end
end

describe Gemba::MainWindow do
  describe "achievement unlocks" do
    it "awards a triggered achievement exactly once, after unlocks are known, and never one already earned" do
      with_tempdir do |dir|
        fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
          game_id: 515_i64, script: nil,
          achievements: [fake_achievement(1_i64, "Thirty frames"), fake_achievement(2_i64, "Already mine")],
          unlocked: [2_i64])
        window = ra_window(dir, fake)

        begin
          window.load_rom(FILL_ROM)
          window.app.interp.wait_until(15.seconds) { !fake.awarded_ids.empty? }
          # Both conditions are identical and both would have fired by
          # now if #2 had been activated too.
          pump(window, 1.second)

          fake.awarded_ids.should eq [1_i64]
          award = fake.requests.find { |request| request["r"]? == "awardachievement" }.should_not be_nil
          award["a"].should eq "1"
          award["h"].should eq "0"
          award["u"].should eq "someone"

          # The site is asked in this order, and nothing is activated
          # (so nothing can trigger) until the unlocks reply is in.
          index_of(fake, "gameid").should be < index_of(fake, "patch")
          index_of(fake, "patch").should be < index_of(fake, "unlocks")
          index_of(fake, "unlocks").should be < index_of(fake, "awardachievement")

          by_id = window.ra_achievements.to_h { |achievement| {achievement.id, achievement} }
          by_id[1_u32].earned?.should be_true
          by_id[2_u32].earned?.should be_true
          by_id[1_u32].title.should eq "Thirty frames"

          # No rich presence, no heartbeat - achievements alone don't ping.
          fake.requests.any? { |request| request["r"]? == "ping" }.should be_false
        ensure
          stop_worker_then_destroy(window)
        end
      end
    end

    it "activates nothing when the unlocks reply fails - it cannot tell what is already earned" do
      with_tempdir do |dir|
        fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
          game_id: 515_i64, script: nil, achievements: [fake_achievement(1_i64, "Would fire", frames: 5)])
        fake.unlocks_fail = true
        window = ra_window(dir, fake)

        begin
          window.load_rom(FILL_ROM)
          window.app.interp.wait_until(15.seconds) { index_of(fake, "unlocks") >= 0 }
          pump(window, 1.second)

          fake.awarded_ids.should be_empty
          window.ra_achievements.should be_empty
        ensure
          stop_worker_then_destroy(window)
        end
      end
    end

    it "keeps an unlock the site refused and resubmits it until the site accepts" do
      with_tempdir do |dir|
        fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
          game_id: 515_i64, script: nil, achievements: [fake_achievement(1_i64, "Refused", frames: 5)])
        fake.award_fails = true
        window = ra_window(dir, fake, Gemba::Achievements::RetroAchievements::UnlockQueue::Schedule.new(50.milliseconds, 200.milliseconds, 10))

        begin
          window.load_rom(FILL_ROM)
          window.app.interp.wait_until(15.seconds) { window.ra_pending_unlocks == [1_u32] }

          # Marked earned locally regardless - the player DID earn it;
          # only the site's record is missing, and the queue keeps
          # after that.
          window.ra_achievements[0].earned?.should be_true

          fake.award_fails = false
          window.app.interp.wait_until(5.seconds) { window.ra_pending_unlocks.empty? }
          pump(window, 500.milliseconds)

          fake.awarded_ids.should eq [1_i64, 1_i64]
          window.ra_achievements[0].earned?.should be_true
        ensure
          stop_worker_then_destroy(window)
        end
      end
    end

    # Writes into the real screenshots dir, same as main_window_spec's
    # own #take_screenshot test and for the same reason (see there);
    # cleaned up in ensure.
    it "takes the unlock screenshot when the setting is on" do
      with_tempdir do |dir|
        fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
          game_id: 515_i64, script: nil, achievements: [fake_achievement(7_i64, "Snapped", frames: 5)])
        window = ra_window(dir, fake)
        window.config.ra_screenshot_on_unlock = true
        before = Dir.exists?(Gemba::Paths.screenshots_dir) ? Dir.children(Gemba::Paths.screenshots_dir) : [] of String
        new_files = [] of String

        begin
          window.load_rom(FILL_ROM)
          window.app.interp.wait_until(15.seconds) do
            new_files = Dir.exists?(Gemba::Paths.screenshots_dir) ? Dir.children(Gemba::Paths.screenshots_dir) - before : [] of String
            new_files.size == 1
          end
          pump(window, 500.milliseconds)

          new_files.first.should start_with "fill_achievement_7_"
          new_files.first.should end_with ".png"
        ensure
          stop_worker_then_destroy(window)
          new_files.each { |name| File.delete?(File.join(Gemba::Paths.screenshots_dir, name)) }
        end
      end
    end
  end
end

private OTHER_ROM_ID = "AGB-OTHR-22222222"

describe Gemba::MainWindow do
  describe "achievements window" do
    it "lists the loaded game's achievements, and Sync picks up an unlock the site recorded elsewhere" do
      with_tempdir do |dir|
        fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
          game_id: 515_i64, script: nil,
          achievements: [fake_achievement(1_i64, "Someday", frames: 100_000), fake_achievement(2_i64, "Already mine")],
          unlocked: [2_i64])
        window = ra_window(dir, fake)
        achievements = window.achievements_window

        begin
          window.load_rom(FILL_ROM)
          window.app.interp.wait_until(15.seconds) { window.ra_achievements.size == 2 }
          window.show_achievements
          # The dropdown lands on the loaded game once the worker has
          # reported its header.
          window.app.interp.wait_until(5.seconds) { achievements.selected_game.try(&.path) == FILL_ROM }

          achievements.rows.map(&.[0]).should eq ["Already mine", "Someday"]
          achievements.status_text.should eq "1 / 2 earned"

          fake.mark_unlocked(1_i64)
          unlocks_before = fake.requests.count { |request| request["r"]? == "unlocks" }
          window.app.tcl_invoke(achievements.sync_button.path, "invoke")
          window.app.interp.wait_until(5.seconds) { achievements.status_text == "2 / 2 earned" }

          fake.requests.count { |request| request["r"]? == "unlocks" }.should eq unlocks_before + 1
          window.ra_achievements.all?(&.earned?).should be_true
          # A sync only reads earned state - it never awards anything.
          fake.awarded_ids.should be_empty
        ensure
          stop_worker_then_destroy(window)
        end
      end
    end

    it "switching the dropdown to another library game shows the empty state, and back shows the list" do
      with_tempdir do |dir|
        library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
        library.remember("Other Game", "/roms/other.gba", "2026-01-01T00:00:00Z")
        library.update_identity("/roms/other.gba", "AGB-OTHR", 0x22222222_u32)

        fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
          game_id: 515_i64, script: nil, achievements: [fake_achievement(1_i64, "Someday", frames: 100_000)])
        window = ra_window(dir, fake)
        achievements = window.achievements_window

        begin
          window.load_rom(FILL_ROM)
          window.app.interp.wait_until(15.seconds) { window.ra_achievements.size == 1 }
          window.show_achievements
          window.app.interp.wait_until(5.seconds) { achievements.selected_game.try(&.path) == FILL_ROM }
          loaded_id = achievements.selected_game.should_not(be_nil).rom_id
          achievements.rows.size.should eq 1

          achievements.select_game(OTHER_ROM_ID).should be_true
          achievements.rows.should be_empty
          achievements.status_text.should eq "No achievements loaded"

          achievements.select_game(loaded_id).should be_true
          achievements.rows.map(&.[0]).should eq ["Someday"]
        ensure
          stop_worker_then_destroy(window)
        end
      end
    end

    it "Include Unofficial re-fetches the game with the unofficial set included and persists the choice" do
      with_tempdir do |dir|
        unofficial = Gemba::Achievements::RetroAchievements::FakeRequester.achievement(
          2_i64, "0xH0000>=0.100000.", title: "Unofficial one", flags: Gemba::Achievements::Achievement::UNOFFICIAL.to_i64)
        fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
          game_id: 515_i64, script: nil, achievements: [fake_achievement(1_i64, "Someday", frames: 100_000), unofficial])
        window = ra_window(dir, fake)
        achievements = window.achievements_window

        begin
          window.load_rom(FILL_ROM)
          window.app.interp.wait_until(15.seconds) { window.ra_achievements.size == 1 }
          window.show_achievements
          window.app.interp.wait_until(5.seconds) { achievements.selected_game.try(&.path) == FILL_ROM }
          achievements.rows.map(&.[0]).should eq ["Someday"]

          window.app.tcl_invoke(achievements.unofficial_checkbox.path, "invoke")
          window.app.interp.wait_until(15.seconds) { window.ra_achievements.size == 2 }
          window.app.interp.wait_until(5.seconds) { achievements.rows.size == 2 }

          window.config.ra_unofficial?.should be_true
          achievements.rows.map(&.[0]).should eq ["Someday", "Unofficial one"]
          fake.requests.count { |request| request["r"]? == "patch" }.should eq 2
        ensure
          stop_worker_then_destroy(window)
        end
      end
    end
  end
end
