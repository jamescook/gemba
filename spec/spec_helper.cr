require "spec"
require "../src/gemba"

# Forces SDL's dummy audio driver, which always opens successfully -
# some containers report a nonzero device count from a stale ALSA
# config entry with no real node behind it, making device-probing
# unreliable. Left alone if already set, so
# `SDL_AUDIO_DRIVER=coreaudio crystal spec` still works.
Tryst::SDL.audio_driver = "dummy" unless Tryst::SDL.audio_driver

# Claims the process-wide logger slot before any spec builds a
# MainWindow, whose own `Gemba.logger ||=` would otherwise open (and
# write to) the developer's REAL ~/…/gemba/logs directory. First
# assignment wins, so this has to happen at load time rather than in a
# before_each.
#
# Deliberately no at_exit close: `spec` registers its own test runner
# through at_exit, and handlers run in REVERSE registration order, so a
# close registered here fires BEFORE any spec runs - closing the file
# out from under every later Gemba.log call. Process exit flushes and
# closes it anyway.
Gemba.logger = Gemba::SessionLogger.new(File.tempname("gemba_spec_logs"))

# Replaces tk_popup with a no-op for the life of this interpreter.
#
# On macOS a posted Tk menu is a real native NSMenu: TkpPostMenu ends in
# [menu popUpMenuPositioningItem:...], a blocking AppKit call that runs
# its own modal loop and, in Tk's own words (macosx/tkMacOSXMenu.c),
# "steal[s] all mouse or keyboard input from the application until the
# menu is dismissed... Posting a Mac menu in a regression test will
# cause the test to halt waiting for user input." So a spec that pops a
# picker context menu (PickerRowActions#popup_rom_menu) hangs with a
# floating menu on screen until a human clicks it.
#
# It cannot be dismissed from Tcl after the fact: no `after` timer runs
# during AppKit's modal loop, and tk::MenuUnpost {} is a no-op here
# anyway - it dismisses via Priv(popup), which tk_popup only ever sets
# in its x11 branch (library/menu.tcl). Both were tried; neither works.
# Suppressing the post itself is the only option, and it costs no
# coverage: every `$menu add command` runs BEFORE the tk_popup call, so
# the menu widget is still fully built and its entries still assertable.
def stub_tk_popup(app) : Nil
  app.tcl_eval("proc ::tk_popup {menu x y {entry {}}} {}")
end
