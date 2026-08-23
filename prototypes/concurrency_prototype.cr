# A persistent measurement harness: whether BackgroundWork (Isolated
# thread + App#after poll) can sustain real GBA pacing (59.7275 fps)
# with gapless audio. Re-run
# (`DURATION=<seconds> crystal run prototypes/concurrency_prototype.cr`
# from gemba/) if BackgroundWork's own implementation changes, or to
# verify on a platform/machine this hasn't been measured on yet.
#
# drop_intermediate = false: BackgroundWork defaults to delivering only
# the LATEST yielded value per poll tick, discarding the rest - fine for
# a progress percentage, not for audio, which can't tolerate a dropped
# chunk without an audible glitch. Every frame's packet (video AND its
# paired audio) is delivered here, no silent drops.
require "../src/gemba"
require "tryst-sdl"

DURATION_S     = (ENV["DURATION"]? || "15").to_i
ROM            = File.join(__DIR__, "..", "spec", "fixtures", "space_blast.gba")
GBA_FPS        = 59.7275006
FRAME_INTERVAL = 1.0 / GBA_FPS

Tryst::BackgroundWork.drop_intermediate = false

app = Tryst::App.new(title: "concurrency prototype")
app.show
viewport = Tryst::SDL::Viewport.new(app, width: 240, height: 160, vsync: false)
texture = viewport.renderer.create_texture(240, 160, access: Tryst::SDL::Texture::Access::Streaming)

audio = Tryst::SDL::AudioStream.new(Tryst::SDL::AudioSpec.new(format: Tryst::SDL::AudioFormat::S16LE, channels: 2, freq: 44100))
audio_started = false

frame_gaps = [] of Float64
last_delivery = Time.instant
frames_delivered = 0
underrun_events = 0
argb_scratch = Bytes.new(240 * 160 * 4)

alias FramePacket = NamedTuple(video: Slice(UInt32), audio: Slice(Int16), frame_num: Int32)

work = Tryst::BackgroundWork(Nil, FramePacket).new(app, nil) do |task, _data|
  core = Gemba::Core.new(ROM)
  frame_num = 0
  next_frame_at = Time.instant

  loop do
    msg = task.check_message
    break if msg == Tryst::BackgroundControl::Stop

    core.keys = 0_u32
    core.run_frame
    task.yield({video: core.video_buffer.dup, audio: core.audio_buffer.dup, frame_num: frame_num})
    frame_num += 1

    next_frame_at += FRAME_INTERVAL.seconds
    now = Time.instant
    sleep(next_frame_at - now) if next_frame_at > now
  end
  core.destroy
end

work.on_progress do |packet|
  now = Time.instant
  frame_gaps << (now - last_delivery).total_milliseconds
  last_delivery = now
  frames_delivered += 1

  # XBGR8888 (mGBA's color_t) -> ARGB8888 (SDL), unoptimized here to
  # measure the true cost.
  video = packet[:video]
  video.each_with_index do |pixel, index|
    r = pixel & 0xFF
    g = (pixel >> 8) & 0xFF
    b = (pixel >> 16) & 0xFF
    o = index * 4
    argb_scratch[o] = b.to_u8
    argb_scratch[o + 1] = g.to_u8
    argb_scratch[o + 2] = r.to_u8
    argb_scratch[o + 3] = 0xFF_u8
  end
  texture.update(argb_scratch)
  viewport.render(&.clear.copy(texture).present)

  audio_bytes = Bytes.new(packet[:audio].to_unsafe.as(UInt8*), packet[:audio].size * 2)
  before = audio.queued_bytes
  underrun_events += 1 if audio_started && before < 2048
  audio.queue(audio_bytes)

  unless audio_started
    if audio.queued_bytes > 4096
      audio.resume
      audio_started = true
    end
  end
end

work.on_error { |err| puts "WORKER ERROR: #{err}" }

app.after(DURATION_S * 1000) do
  work.close
  sorted = frame_gaps.sort
  n = sorted.size
  puts "=== concurrency prototype results (#{DURATION_S}s) ==="
  puts "frames delivered: #{frames_delivered} (expected ~#{(DURATION_S * GBA_FPS).to_i})"
  if n > 0
    puts "delivery gap ms: min=#{sorted.first.round(3)} p50=#{sorted[n // 2].round(3)} " \
         "p95=#{sorted[(n * 0.95).to_i.clamp(0, n - 1)].round(3)} " \
         "p99=#{sorted[(n * 0.99).to_i.clamp(0, n - 1)].round(3)} max=#{sorted.last.round(3)}"
  end
  puts "audio underrun events (queued_bytes < 2048 before a queue): #{underrun_events}"
  puts "final audio queued_bytes: #{audio.queued_bytes}"
  exit
end

app.mainloop
