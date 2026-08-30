require "../spec_helper"
require "file_utils"

private FILL_ROM = File.join(__DIR__, "..", "fixtures", "fill.gba")

private def with_tempdir(&)
  dir = File.tempname("cli_record_decode_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Records a real (headless) clip through the CLI itself, so decode
# tests exercise the same files a user's `gemba record` produces.
private def record_clip(path : String, frames : Int32 = 8) : Nil
  Gemba::CLI.run(["record", "--frames", frames.to_s, "-o", path, FILL_ROM], io: IO::Memory.new)
end

# A stand-in ffmpeg: appends its argv to $FAKE_FFMPEG_OUT and drains
# stdin (the decoder pipes every frame - an unread pipe would break it
# mid-write). The -version probe writes too; the encode invocation
# comes last, so specs read the file's tail.
private def write_fake_ffmpeg(dir : String) : String
  bin = File.join(dir, "fake_ffmpeg")
  File.write(bin, <<-'SCRIPT')
    #!/bin/sh
    printf '%s\n' "$@" >> "$FAKE_FFMPEG_OUT"
    printf '===\n' >> "$FAKE_FFMPEG_OUT"
    cat > /dev/null
    exit 0
    SCRIPT
  File.chmod(bin, 0o755)
  bin
end

describe Gemba::CLI::Record do
  it "parses flags into a typed plan (dry run)" do
    plan = Gemba::CLI.run(
      ["record", "--frames", "10", "-o", "x.grec", "-c", "3", "--progress", "rom.gba"],
      dry_run: true).as(Gemba::CLI::Record::Plan)
    plan.frames.should eq 10
    plan.output.should eq "x.grec"
    plan.compression.should eq 3
    plan.progress.should be_true
    plan.rom.to_s.should end_with "/rom.gba"
    plan.error.should be_nil
  end

  it "requires --frames and a ROM" do
    Gemba::CLI.run(["record", "rom.gba"], dry_run: true).as(Gemba::CLI::Record::Plan)
      .error.to_s.should contain "requires --frames"
    Gemba::CLI.run(["record", "--frames", "5"], dry_run: true).as(Gemba::CLI::Record::Plan)
      .error.to_s.should contain "requires --frames"
  end

  it "records a real ROM headless and reports the stats" do
    with_tempdir do |dir|
      path = File.join(dir, "clip.grec")
      io = IO::Memory.new
      Gemba::CLI.run(["record", "--frames", "12", "-o", path, FILL_ROM], io: io)

      io.to_s.should contain "Recorded 12 frames to #{path}"
      io.to_s.should contain ".grec size:"
      Gemba::RecorderDecoder.stats(path).frame_count.should eq 12
    end
  end
end

describe Gemba::CLI::Decode do
  it "parses flags, positional and -- passthrough into a typed plan (dry run)" do
    plan = Gemba::CLI.run(
      ["decode", "-o", "out.mkv", "-s", "2", "--no-progress", "clip.grec", "--", "-c:v", "ffv1"],
      dry_run: true).as(Gemba::CLI::Decode::Plan)
    plan.grec.should eq "clip.grec"
    plan.output.should eq "out.mkv"
    plan.scale.should eq 2
    plan.progress.should be_false
    plan.ffmpeg_args.should eq ["-c:v", "ffv1"]

    stats = Gemba::CLI.run(["decode", "--stats", "clip.grec"], dry_run: true).as(Gemba::CLI::Decode::Plan)
    stats.stats.should be_true
  end

  it "--stats prints a scan without touching ffmpeg" do
    with_tempdir do |dir|
      path = File.join(dir, "clip.grec")
      record_clip(path, frames: 8)

      io = IO::Memory.new
      Gemba::CLI.run(["decode", "--stats", path], io: io)
      output = io.to_s
      output.should contain "Frames:     8"
      output.should contain "Resolution: 240x160"
      output.should contain "Audio:      44100 Hz, 2ch"
    end
  end

  it "builds the expected ffmpeg invocation (asserted through the fake shell-out seam)" do
    with_tempdir do |dir|
      grec = File.join(dir, "clip.grec")
      record_clip(grec, frames: 4)
      args_out = File.join(dir, "args.txt")
      ENV["FAKE_FFMPEG_OUT"] = args_out
      begin
        io = IO::Memory.new
        Gemba::CLI::Decode.new(
          ["-o", File.join(dir, "out.mkv"), "-s", "2", "--no-progress", grec, "--", "-c:v", "ffv1"],
          io: io, ffmpeg_bin: write_fake_ffmpeg(dir)).call
        io.to_s.should contain "Encoded 4 frames"

        # Last invocation (after the -version probe) is the encode.
        invocation = File.read(args_out).split("===\n")[-2].lines
        invocation.should contain "-pix_fmt"
        invocation.should contain "bgra"
        invocation.should contain "-s"
        invocation.should contain "240x160"
        invocation.should contain "-vf"
        invocation.should contain "scale=480:320"
        invocation.should contain "-sws_flags"
        invocation.should contain "neighbor"
        # -- passthrough replaced the default codec args entirely.
        invocation.should contain "-c:v"
        invocation.should contain "ffv1"
        invocation.should_not contain "libx264"
        invocation.should_not contain "yuv420p"
        # No -progress flag when --no-progress is set; output lands last.
        invocation.should_not contain "-progress"
        invocation.last.should eq File.join(dir, "out.mkv")
      ensure
        ENV.delete("FAKE_FFMPEG_OUT")
      end
    end
  end

  it "with no file it lists the recordings directory" do
    with_tempdir do |dir|
      recordings = File.join(dir, "recordings")
      io = IO::Memory.new
      Gemba::CLI.run(["decode"], io: io, recordings_dir: recordings)
      io.to_s.should contain "No recordings directory found at #{recordings}"

      Dir.mkdir_p(recordings)
      io = IO::Memory.new
      Gemba::CLI.run(["decode"], io: io, recordings_dir: recordings)
      io.to_s.should contain "No .grec recordings in #{recordings}"

      record_clip(File.join(recordings, "a.grec"), frames: 4)
      io = IO::Memory.new
      Gemba::CLI.run(["-l"].unshift("decode"), io: io, recordings_dir: recordings)
      io.to_s.should contain "a.grec"
      io.to_s.should contain "4 frames"
    end
  end
end
