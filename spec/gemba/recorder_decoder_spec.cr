require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("recorder_decoder_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# A small real recording to decode: 16x8, alternating frames of two
# solid colors, a burst of nonzero PCM per frame.
private def record_clip(path : String, frames : Int32) : Nil
  recorder = Gemba::Recorder.new(path, 16, 8)
  recorder.start
  red = Slice(UInt32).new(16 * 8, 0xFFFF0000_u32)
  blue = Slice(UInt32).new(16 * 8, 0xFF0000FF_u32)
  audio = Slice(Int16).new(1470 * 2) { |i| ((i % 100) * 300 - 15000).to_i16 }
  frames.times { |i| recorder.capture(i.even? ? red : blue, audio) }
  recorder.stop
end

describe Gemba::RecorderDecoder do
  it "#stats scans header + change bytes without ffmpeg" do
    with_tempdir do |dir|
      path = File.join(dir, "clip.grec")
      record_clip(path, 10)

      stats = Gemba::RecorderDecoder.stats(path)
      stats.frame_count.should eq 10
      stats.width.should eq 16
      stats.height.should eq 8
      stats.fps.should be_close(59.7275, 0.001)
      stats.duration.should be_close(10 / 59.7275, 0.001)
      stats.audio_rate.should eq 44100
      stats.audio_channels.should eq 2
      stats.raw_video_size.should eq 10_i64 * 16 * 8 * 4
      # Frame 1: everything changed from the zero prev; alternating
      # solid frames keep every later delta at 100% too.
      stats.avg_change_pct.should eq 100.0
    end
  end

  it "#stats counts what a truncated (crashed-recorder) file actually holds" do
    with_tempdir do |dir|
      path = File.join(dir, "clip.grec")
      record_clip(path, 5)
      # Chop the footer and half the last frame off.
      bytes = File.read(path).to_slice
      File.write(File.join(dir, "cut.grec"), bytes[0, bytes.size - 20])

      Gemba::RecorderDecoder.stats(File.join(dir, "cut.grec")).frame_count.should be <= 5
    end
  end

  it "raises FormatError on something that isn't a .grec" do
    with_tempdir do |dir|
      short = File.join(dir, "short.grec")
      File.write(short, "nope")
      expect_raises(Gemba::RecorderDecoder::FormatError, /too small/) do
        Gemba::RecorderDecoder.stats(short)
      end

      wrong = File.join(dir, "wrong.grec")
      File.write(wrong, "NOTGEMBA" + "\0" * 24)
      expect_raises(Gemba::RecorderDecoder::FormatError, /Invalid magic/) do
        Gemba::RecorderDecoder.stats(wrong)
      end
    end
  end

  it "#decode pipes frames to ffmpeg and produces a playable mp4" do
    with_tempdir do |dir|
      path = File.join(dir, "clip.grec")
      record_clip(path, 12)
      out_path = File.join(dir, "clip.mp4")

      info = Gemba::RecorderDecoder.decode(path, out_path, progress: false)
      info.frame_count.should eq 12
      File.exists?(out_path).should be_true
      File.size(out_path).should be > 0
      # An MP4 container starts with an ftyp box a few bytes in.
      File.open(out_path, "rb") do |io|
        head = Bytes.new(12)
        io.read_fully(head)
        String.new(head[4, 4]).should eq "ftyp"
      end
    end
  end

  it "#decode with scale: upscales with nearest-neighbor without erroring" do
    with_tempdir do |dir|
      path = File.join(dir, "clip.grec")
      record_clip(path, 4)
      out_path = File.join(dir, "scaled.mp4")

      Gemba::RecorderDecoder.decode(path, out_path, scale: 2, progress: false)
      File.size(out_path).should be > 0
    end
  end
end
