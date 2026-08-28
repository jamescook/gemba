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
