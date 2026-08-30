require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("cli_play_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Gemba::CLI::Play do
  it "parses the session-override flags into a typed plan (dry run)" do
    plan = Gemba::CLI.run(
      ["play", "-s", "2", "-v", "40", "-m", "-f", "--show-fps", "--locale", "ja", "rom.gba"],
      dry_run: true).as(Gemba::CLI::Play::Plan)
    plan.scale.should eq 2
    plan.volume.should eq 40
    plan.mute.should be_true
    plan.fullscreen.should be_true
    plan.show_fps.should be_true
    plan.locale.should eq "ja"
    plan.rom.to_s.should end_with "/rom.gba"
  end

  it "clamps scale and volume to their real ranges" do
    plan = Gemba::CLI.run(["play", "-s", "9", "-v", "150"], dry_run: true).as(Gemba::CLI::Play::Plan)
    plan.scale.should eq 4
    plan.volume.should eq 100
  end

  it ".apply writes overrides into the Config in memory only - nothing persisted" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      config = Gemba::Config.new(path)
      plan = Gemba::CLI.run(["play", "-s", "2", "-v", "40", "-m", "--show-fps", "--locale", "ja"],
        dry_run: true).as(Gemba::CLI::Play::Plan)

      Gemba::CLI::Play.apply(config, plan)
      config.scale.should eq 2
      config.volume.should eq 40
      config.muted?.should be_true
      config.show_fps?.should be_true
      config.locale.should eq "ja"

      # Session-only: the file was never written.
      File.exists?(path).should be_false
    end
  end

  it "flags a plan didn't set leave the saved settings alone" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      saved = Gemba::Config.new(path)
      saved.scale = 4
      saved.volume = 55
      saved.save!

      config = Gemba::Config.new(path)
      plan = Gemba::CLI.run(["play", "-m"], dry_run: true).as(Gemba::CLI::Play::Plan)
      Gemba::CLI::Play.apply(config, plan)

      config.scale.should eq 4
      config.volume.should eq 55
      config.muted?.should be_true
    end
  end

  it "MainWindow accepts an injected, pre-mutated Config (the seam play uses)" do
    with_tempdir do |dir|
      path = File.join(dir, "settings.json")
      config = Gemba::Config.new(path)
      config.scale = 2
      config.muted = true

      window = Gemba::MainWindow.new(
        rom_library_path: File.join(dir, "rom_library.json"),
        gamepad_polling: false,
        config: config,
      )
      begin
        window.config.should be config
        window.config.scale.should eq 2
        window.config.muted?.should be_true
        # Construction alone persisted nothing - the overrides stay
        # session-only until something deliberately save!s.
        File.exists?(path).should be_false
      ensure
        window.destroy
      end
    end
  end
end
