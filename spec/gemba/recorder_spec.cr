require "../spec_helper"
require "file_utils"
require "compress/zlib"

private def with_tempdir(&)
  dir = File.tempname("recorder_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private record GrecHeader,
  version : Int32, width : Int32, height : Int32,
  fps_num : UInt32, fps_den : UInt32,
  audio_rate : Int32, channels : Int32, bits : Int32

private record GrecFrame, change_pct : Int32, video : Slice(UInt32), audio : Slice(Int16)

# A from-scratch reader for the .grec layout, deliberately independent
# of Recorder's own writing code - it asserts the bytes, not that the
# writer agrees with itself. Mirrors ruby RecorderDecoder's read path
# (header, per-frame chunks with a footer probe, inflate + un-XOR).
private def read_grec(path : String) : {GrecHeader, Array(GrecFrame), UInt32}
  File.open(path, "rb") do |io|
    magic = Bytes.new(8)
    io.read_fully(magic)
    String.new(magic).should eq "GEMBAREC"

    header = GrecHeader.new(
      version: read_u8(io),
      width: io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_i,
      height: io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_i,
      fps_num: io.read_bytes(UInt32, IO::ByteFormat::LittleEndian),
      fps_den: io.read_bytes(UInt32, IO::ByteFormat::LittleEndian),
      audio_rate: io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i,
      channels: read_u8(io),
      bits: read_u8(io),
    )
    io.skip(5) # reserved

    frames = [] of GrecFrame
    prev = Slice(UInt32).new(header.width * header.height, 0_u32)

    loop do
      if footer_count = footer_at?(io)
        return {header, frames, footer_count}
      end

      change_pct = read_u8(io)
      video_len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      compressed = Bytes.new(video_len)
      io.read_fully(compressed)
      delta = inflate(compressed)
      delta.size.should eq prev.size * 4

      frame = Slice(UInt32).new(prev.size, 0_u32)
      words = delta.to_unsafe.as(UInt32*).to_slice(prev.size)
      Gemba::FrameDelta.xor_into(frame, words, prev)
      prev = frame

      audio_len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      audio_bytes = Bytes.new(audio_len)
      io.read_fully(audio_bytes)
      audio = Slice(Int16).new(audio_len.to_i // 2) { |i| IO::ByteFormat::LittleEndian.decode(Int16, audio_bytes[i * 2, 2]) }

      frames << GrecFrame.new(change_pct: change_pct, video: frame, audio: audio)
    end
  end
end

private def read_u8(io : File) : Int32
  (io.read_byte || raise "truncated .grec").to_i
end

# The 8-byte footer probe: u32 frame count + "GEND". Rewinds if this
# isn't it, same as ruby's at_footer?.
private def footer_at?(io : File) : UInt32?
  pos = io.pos
  probe = Bytes.new(8)
  read = io.read(probe)
  if read == 8 && String.new(probe[4, 4]) == "GEND"
    return IO::ByteFormat::LittleEndian.decode(UInt32, probe[0, 4])
  end
  io.pos = pos
  nil
end

private def inflate(compressed : Bytes) : Bytes
  Compress::Zlib::Reader.open(IO::Memory.new(compressed)) do |zlib|
    io = IO::Memory.new
    IO.copy(zlib, io)
    io.to_slice
  end
end

private def wait_for(timeout : Time::Span, &) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "timed out" if Time.instant > deadline
    sleep 10.milliseconds
  end
end

describe Gemba::FrameDelta do
  it "XOR is its own inverse and changed pixels are nonzero words" do
    current = Slice(UInt32).new(4) { |i| (i + 1).to_u32 }
    previous = Slice[1_u32, 2_u32, 0_u32, 9_u32]
    delta = Slice(UInt32).new(4, 0_u32)

    Gemba::FrameDelta.xor_into(delta, current, previous)
    Gemba::FrameDelta.count_changed_pixels(delta).should eq 2 # words 0/1 identical

    back = Slice(UInt32).new(4, 0_u32)
    Gemba::FrameDelta.xor_into(back, delta, previous)
    back.should eq current
  end

  it "raises on a size mismatch" do
    expect_raises(ArgumentError, /size mismatch/) do
      Gemba::FrameDelta.xor_into(Slice(UInt32).new(2, 0_u32), Slice(UInt32).new(3, 0_u32), Slice(UInt32).new(2, 0_u32))
    end
  end
end

describe Gemba::Recorder do
  it "writes ruby gemba's .grec format and round-trips frames through inflate + un-XOR" do
    with_tempdir do |dir|
      path = File.join(dir, "clip.grec")
      recorder = Gemba::Recorder.new(path, 4, 2)
      recorder.recording?.should be_false
      recorder.start
      recorder.recording?.should be_true

      frame_a = Slice(UInt32).new(8) { |i| (0xFF000000_u32 + i + 1) }
      frame_b = frame_a.dup # unchanged frame -> 0% change
      frame_c = Slice(UInt32).new(8) { |i| (0x00112233_u32 * (i + 2)) }
      audio_a = Slice(Int16).new(6) { |i| (i * 1000 - 2500).to_i16 }
      audio_c = Slice[32767_i16, -32768_i16]

      recorder.capture(frame_a, audio_a)
      recorder.capture(frame_b, Slice(Int16).empty)
      recorder.capture(frame_c, audio_c)
      recorder.stop
      recorder.recording?.should be_false
      recorder.frame_count.should eq 3

      header, frames, footer_count = read_grec(path)
      header.version.should eq 1
      header.width.should eq 4
      header.height.should eq 2
      {header.fps_num, header.fps_den}.should eq Gemba::Recorder::GBA_FPS_FRACTION
      header.audio_rate.should eq 44100
      header.channels.should eq 2
      header.bits.should eq 16
      footer_count.should eq 3

      frames.size.should eq 3
      frames[0].video.should eq frame_a
      frames[1].video.should eq frame_b
      frames[2].video.should eq frame_c
      frames[0].audio.should eq audio_a
      frames[1].audio.should be_empty
      frames[2].audio.should eq audio_c
      frames.map(&.change_pct).should eq [100, 0, 100]
    end
  end

  it "hands the writer nothing but the header until FLUSH_INTERVAL frames (or stop) batch up" do
    with_tempdir do |dir|
      path = File.join(dir, "batched.grec")
      recorder = Gemba::Recorder.new(path, 4, 2)
      recorder.start

      frame = Slice(UInt32).new(8, 0xDEADBEEF_u32)
      3.times { recorder.capture(frame, Slice(Int16).empty) }
      # The writer thread is asynchronous, so wait for the header to
      # land - then the size holding at exactly 32 shows the 3 frames
      # are still batched in memory, not written per capture.
      wait_for(2.seconds) { File.exists?(path) && File.size(path) == 32 }

      (Gemba::Recorder::FLUSH_INTERVAL - 3).times { recorder.capture(frame, Slice(Int16).empty) }
      wait_for(2.seconds) { File.size(path) > 32 }

      recorder.stop
      _, frames, footer_count = read_grec(path)
      frames.size.should eq Gemba::Recorder::FLUSH_INTERVAL
      footer_count.should eq Gemba::Recorder::FLUSH_INTERVAL
    end
  end

  it "any compression level decodes to the same frames" do
    with_tempdir do |dir|
      path = File.join(dir, "level9.grec")
      recorder = Gemba::Recorder.new(path, 4, 2, compression: 9)
      recorder.start
      frame = Slice(UInt32).new(8) { |i| i.to_u32 * 7919 }
      recorder.capture(frame, Slice(Int16).empty)
      recorder.stop

      _, frames, _ = read_grec(path)
      frames[0].video.should eq frame
    end
  end

  it "#start raises while already recording; #stop is idempotent" do
    with_tempdir do |dir|
      recorder = Gemba::Recorder.new(File.join(dir, "twice.grec"), 4, 2)
      recorder.start
      expect_raises(Exception, "Already recording") { recorder.start }
      recorder.stop
      recorder.stop
    end
  end
end
