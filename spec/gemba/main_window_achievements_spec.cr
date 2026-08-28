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
          window.app.destroy
        end
      end
    end

    it "stays off when the rich presence switch is disabled" do
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
          sleep 500.milliseconds
          window.app.update

          fake.requests.any? { |request| request["r"]? == "gameid" }.should be_false
        ensure
          window.app.destroy
        end
      end
    end
  end
end
