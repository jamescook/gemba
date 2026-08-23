require "spec"
require "../src/gemba"

# Forces SDL's dummy audio driver, which always opens successfully -
# some containers report a nonzero device count from a stale ALSA
# config entry with no real node behind it, making device-probing
# unreliable. Left alone if already set, so
# `SDL_AUDIO_DRIVER=coreaudio crystal spec` still works.
Tryst::SDL.audio_driver = "dummy" unless Tryst::SDL.audio_driver
