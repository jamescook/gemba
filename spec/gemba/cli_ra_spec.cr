require "../spec_helper"
require "file_utils"

private FILL_ROM = File.join(__DIR__, "..", "fixtures", "fill.gba")

private def with_tempdir(&)
  dir = File.tempname("cli_ra_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def logged_in_config(dir : String, username : String = "bob", token : String = "tok") : String
  path = File.join(dir, "settings.json")
  config = Gemba::Config.new(path)
  config.ra_username = username
  config.ra_token = token
  config.save!
  path
end

private def new_ra(args : Array(String), fake : Gemba::Achievements::RetroAchievements::FakeRequester,
                   io : IO, config_path : String, cache_dir : String = "/nonexistent",
                   input : IO = IO::Memory.new) : Gemba::CLI::Ra
  Gemba::CLI::Ra.new(args, io: io, err: IO::Memory.new, input: input,
    config_path: config_path, cache_dir: cache_dir, requester: fake.to_proc)
end

describe Gemba::CLI::Ra do
  it "parses subcommands and flags into typed plans (dry run)" do
    plan = Gemba::CLI.run(["ra", "login", "--username", "bob", "--password", "pw"],
      dry_run: true).as(Gemba::CLI::Ra::Plan)
    plan.subcommand.should eq :login
    plan.username.should eq "bob"
    plan.password.should eq "pw"

    Gemba::CLI.run(["ra", "achievements", "--rom", "x.gba", "--json"], dry_run: true)
      .as(Gemba::CLI::Ra::Plan).json.should be_true
    Gemba::CLI.run(["ra", "sync", "x.gba"], dry_run: true)
      .as(Gemba::CLI::Ra::Plan).rom.to_s.should end_with "/x.gba"
    Gemba::CLI.run(["ra"], dry_run: true).as(Gemba::CLI::Ra::Plan).subcommand.should be_nil
  end

  it "login stores credentials on success, prompting when --password is omitted" do
    with_tempdir do |dir|
      fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(valid_token: "hunter2")
      config_path = File.join(dir, "settings.json")
      io = IO::Memory.new

      new_ra(["login", "--username", "bob"], fake, io, config_path,
        input: IO::Memory.new("hunter2\n")).call
      io.to_s.should contain "Logged in as bob"
      fake.requests.first["p"]?.should eq "hunter2"

      config = Gemba::Config.new(config_path)
      config.ra_username.should eq "bob"
      config.ra_token.should eq "fake-token-bob"
      config.ra_enabled?.should be_true
    end
  end

  it "login with bad credentials raises the exit-1 error" do
    with_tempdir do |dir|
      fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(valid_token: "right")
      expect_raises(Gemba::CLI::Error, /Login failed/) do
        new_ra(["login", "--username", "bob", "--password", "wrong"], fake,
          IO::Memory.new, File.join(dir, "settings.json")).call
      end
    end
  end

  it "verify reports on the stored token, and refuses when not logged in" do
    with_tempdir do |dir|
      fake = Gemba::Achievements::RetroAchievements::FakeRequester.new
      io = IO::Memory.new
      new_ra(["verify"], fake, io, logged_in_config(dir)).call
      io.to_s.should contain "Token valid for bob"
      fake.requests.first["t"]?.should eq "tok"

      expect_raises(Gemba::CLI::Error, /Not logged in/) do
        new_ra(["verify"], fake, IO::Memory.new, File.join(dir, "empty.json")).call
      end
    end
  end

  it "logout clears stored credentials" do
    with_tempdir do |dir|
      config_path = logged_in_config(dir)
      io = IO::Memory.new
      new_ra(["logout"], Gemba::Achievements::RetroAchievements::FakeRequester.new, io, config_path).call
      io.to_s.should contain "Logged out"

      config = Gemba::Config.new(config_path)
      config.ra_username.should eq ""
      config.ra_token.should eq ""
      config.ra_enabled?.should be_false
    end
  end

  it "achievements fetches gameid -> patch -> unlocks and prints earned state" do
    with_tempdir do |dir|
      fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
        achievements: [
          Gemba::Achievements::RetroAchievements::FakeRequester.achievement(9, "0xH0000=1", title: "First", points: 10),
          Gemba::Achievements::RetroAchievements::FakeRequester.achievement(10, "0xH0001=1", title: "Second", points: 5),
        ],
        unlocked: [9_i64])
      io = IO::Memory.new
      new_ra(["achievements", "--rom", FILL_ROM], fake, io, logged_in_config(dir)).call

      output = io.to_s
      output.should contain "1/2 achievements - fill"
      output.should contain "[X] First (10pts)"
      output.should contain "[ ] Second (5pts)"
      fake.requests.map(&.["r"]?).should eq ["gameid", "patch", "unlocks"]
    end
  end

  it "achievements --json emits machine-readable earned state" do
    with_tempdir do |dir|
      fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
        achievements: [Gemba::Achievements::RetroAchievements::FakeRequester.achievement(9, "0xH0000=1", title: "First")],
        unlocked: [9_i64])
      io = IO::Memory.new
      new_ra(["achievements", "--rom", FILL_ROM, "--json"], fake, io, logged_in_config(dir)).call

      parsed = JSON.parse(io.to_s)
      parsed.as_a.size.should eq 1
      parsed[0]["id"].should eq 9
      parsed[0]["earned"].as_bool.should be_true
      parsed[0]["earned_at"].as_s?.should_not be_nil
    end
  end

  it "sync writes the offline achievement cache under the app's rom_id" do
    with_tempdir do |dir|
      fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(
        achievements: [Gemba::Achievements::RetroAchievements::FakeRequester.achievement(9, "0xH0000=1", title: "First")],
        unlocked: [9_i64])
      cache_dir = File.join(dir, "achievements")
      io = IO::Memory.new
      new_ra(["sync", FILL_ROM], fake, io, logged_in_config(dir), cache_dir: cache_dir).call

      io.to_s.should contain "Synced 1 achievements (1 earned) for fill.gba"

      core = Gemba::Core.new(FILL_ROM)
      rom_id = Gemba::RomLibrary.rom_id(core.game_code, core.checksum)
      core.destroy
      cached = Gemba::Achievements::Cache.read(rom_id, cache_dir).should_not be_nil
      cached.size.should eq 1
      cached[0].title.should eq "First"
      cached[0].earned?.should be_true
    end
  end

  it "an unrecognized ROM raises rather than writing an empty cache" do
    with_tempdir do |dir|
      fake = Gemba::Achievements::RetroAchievements::FakeRequester.new(game_id: nil)
      expect_raises(Gemba::CLI::Error, /not recognized/) do
        new_ra(["sync", FILL_ROM], fake, IO::Memory.new, logged_in_config(dir),
          cache_dir: File.join(dir, "achievements")).call
      end
      Dir.exists?(File.join(dir, "achievements")).should be_false
    end
  end
end
