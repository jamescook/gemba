require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("cli_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Every example here runs headless: dry_run plans for the dispatch, and
# real (io-captured) execution only for the commands that never touch
# Tk/SDL - the bead's own acceptance criteria.
describe Gemba::CLI do
  describe "dispatch" do
    it "defaults to play, treating a bare argument as the ROM path" do
      Gemba::CLI.run([] of String, dry_run: true).should eq Gemba::CLI::Play::Plan.new(rom: nil)

      plan = Gemba::CLI.run(["foo.gba"], dry_run: true).as(Gemba::CLI::Play::Plan)
      plan.rom.to_s.should end_with "/foo.gba" # expanded to an absolute path

      explicit = Gemba::CLI.run(["play", "bar.gba"], dry_run: true).as(Gemba::CLI::Play::Plan)
      explicit.rom.to_s.should end_with "/bar.gba"
    end

    it "--help / -h print the subcommand list without launching anything" do
      io = IO::Memory.new
      Gemba::CLI.run(["--help"], io: io).should be_a(Gemba::CLI::HelpPlan)
      io.to_s.should contain "Commands:"
      io.to_s.should contain "play      Play a ROM (default)"

      Gemba::CLI.run(["-h"], dry_run: true).should be_a(Gemba::CLI::HelpPlan)
    end

    it "reserved-but-unported subcommands say so instead of becoming ROM paths" do
      %w[record decode replay patch ra].each do |command|
        plan = Gemba::CLI.run([command], dry_run: true)
        plan.should eq Gemba::CLI::UnimplementedPlan.new(command: command)
      end

      io = IO::Memory.new
      Gemba::CLI.run(["record"], io: io)
      io.to_s.should contain "not implemented yet"
    end

    it "play -h prints play's own usage without opening a window" do
      io = IO::Memory.new
      plan = Gemba::CLI.run(["play", "-h"], io: io).as(Gemba::CLI::Play::Plan)
      plan.help.should be_true
      io.to_s.should contain "Usage: gemba [play] [ROM_FILE]"
    end
  end

  describe "version" do
    it "prints the version and exits" do
      io = IO::Memory.new
      plan = Gemba::CLI.run(["version"], io: io).as(Gemba::CLI::VersionCmd::Plan)
      plan.version.should eq Gemba::VERSION
      io.to_s.should eq "gemba #{Gemba::VERSION}\n"
    end
  end

  describe "config" do
    it "shows the settings path and main knobs when the file exists" do
      with_tempdir do |dir|
        path = File.join(dir, "settings.json")
        config = Gemba::Config.new(path)
        config.scale = 2
        config.volume = 40
        config.save!

        io = IO::Memory.new
        plan = Gemba::CLI.run(["config"], io: io, config_path: path).as(Gemba::CLI::ConfigCmd::Plan)
        plan.action.should eq :show

        output = io.to_s
        output.should contain "Config: #{path}"
        output.should contain "Exists: true"
        output.should contain "Scale: 2"
        output.should contain "Volume: 40"
      end
    end

    it "reports a missing settings file without inventing fields" do
      with_tempdir do |dir|
        path = File.join(dir, "settings.json")
        io = IO::Memory.new
        Gemba::CLI.run(["config"], io: io, config_path: path)
        io.to_s.should contain "Exists: false"
        io.to_s.should_not contain "Scale:"
      end
    end

    it "--reset asks first, deletes on y, and leaves the file on anything else" do
      with_tempdir do |dir|
        path = File.join(dir, "settings.json")
        Gemba::Config.new(path).save!

        io = IO::Memory.new
        Gemba::CLI.run(["config", "--reset"], io: io, input: IO::Memory.new("n\n"), config_path: path)
        File.exists?(path).should be_true

        Gemba::CLI.run(["config", "--reset"], io: io, input: IO::Memory.new("y\n"), config_path: path)
        File.exists?(path).should be_false
        io.to_s.should contain "Deleted #{path}"
      end
    end

    it "--reset -y skips the prompt entirely" do
      with_tempdir do |dir|
        path = File.join(dir, "settings.json")
        Gemba::Config.new(path).save!

        io = IO::Memory.new
        # An empty input stream: if the prompt were still consulted,
        # gets would return nil and the file would survive.
        plan = Gemba::CLI.run(["config", "--reset", "-y"], io: io,
          input: IO::Memory.new, config_path: path).as(Gemba::CLI::ConfigCmd::Plan)
        plan.action.should eq :reset
        plan.yes.should be_true
        File.exists?(path).should be_false
      end
    end

    it "--reset on a missing file says so" do
      with_tempdir do |dir|
        path = File.join(dir, "settings.json")
        io = IO::Memory.new
        Gemba::CLI.run(["config", "--reset", "-y"], io: io, config_path: path)
        io.to_s.should contain "No config file found"
      end
    end
  end
end
