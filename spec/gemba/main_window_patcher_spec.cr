require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("main_window_patcher_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# One normal record at offset 0 - the smallest useful IPS patch.
private def write_ips(path : String, data : Bytes) : Nil
  io = IO::Memory.new
  io << "PATCH"
  io.write(Bytes[0, 0, 0]) # offset 0, 3 bytes big-endian
  io.write_bytes(data.size.to_u16, IO::ByteFormat::BigEndian)
  io.write(data)
  io << "EOF"
  File.write(path, io.to_slice)
end

private def new_window(dir : String) : Gemba::MainWindow
  Gemba::MainWindow.new(
    rom_library_path: File.join(dir, "rom_library.json"),
    config_path: File.join(dir, "settings.json"),
    gamepad_polling: false,
  )
end

describe Gemba::MainWindow do
  it "applies a picked IPS patch in the background, reporting progress and Done" do
    with_tempdir do |dir|
      rom = File.join(dir, "game.gba")
      File.write(rom, Bytes.new(64))
      patch = File.join(dir, "fix.ips")
      write_ips(patch, Bytes[0xFF, 0xFE])
      outdir = File.join(dir, "out")

      window = new_window(dir)
      begin
        window.show_patcher
        patcher = window.patcher_window
        app = window.app
        patcher.rom_var.value = rom
        patcher.patch_var.value = patch
        patcher.outdir_var.value = outdir

        patcher.apply
        patcher.busy?.should be_true
        app.interp.wait_until(10.seconds) { !patcher.busy? }
        patcher.busy?.should be_false

        out_path = File.join(outdir, "game-patched.gba")
        File.exists?(out_path).should be_true
        result = File.read(out_path).to_slice
        result[0, 2].should eq Bytes[0xFF, 0xFE]
        result.size.should eq 64

        patcher.status_var.value.to_s.should contain Gemba::Locale.translate("patcher.done")
        patcher.progress_var.value.should eq 100
      ensure
        window.destroy
      end
    end
  end

  it "validates fields before starting anything" do
    with_tempdir do |dir|
      window = new_window(dir)
      begin
        patcher = window.patcher_window

        # All empty (the outdir default points at a real directory
        # setting, so blank it too).
        patcher.outdir_var.value = ""
        patcher.apply
        patcher.busy?.should be_false
        patcher.status_var.value.to_s.should eq Gemba::Locale.translate("patcher.err_missing_fields")

        # Fields present, but the ROM doesn't exist.
        patcher.rom_var.value = File.join(dir, "missing.gba")
        patcher.patch_var.value = File.join(dir, "missing.ips")
        patcher.outdir_var.value = dir
        patcher.apply
        patcher.status_var.value.to_s.should eq Gemba::Locale.translate("patcher.err_rom_not_found")

        # ROM present, patch still missing.
        rom = File.join(dir, "game.gba")
        File.write(rom, Bytes.new(16))
        patcher.rom_var.value = rom
        patcher.apply
        patcher.status_var.value.to_s.should eq Gemba::Locale.translate("patcher.err_patch_not_found")
        patcher.busy?.should be_false
      ensure
        window.destroy
      end
    end
  end

  it "a colliding output name answered 'no' patches to the -(2) name instead" do
    with_tempdir do |dir|
      rom = File.join(dir, "game.gba")
      File.write(rom, Bytes.new(32))
      patch = File.join(dir, "fix.ips")
      write_ips(patch, Bytes[0xAB])
      File.write(File.join(dir, "game-patched.gba"), "existing")

      window = new_window(dir)
      begin
        patcher = window.patcher_window
        app = window.app
        patcher.rom_var.value = rom
        patcher.patch_var.value = patch
        patcher.outdir_var.value = dir
        asked = [] of String
        patcher.overwrite_prompt = ->(basename : String) { asked << basename; :no }

        patcher.apply
        app.interp.wait_until(10.seconds) { !patcher.busy? }

        asked.should eq ["game-patched.gba"]
        File.read(File.join(dir, "game-patched.gba")).should eq "existing"
        result = File.read(File.join(dir, "game-patched-(2).gba")).to_slice
        result[0].should eq 0xAB_u8
      ensure
        window.destroy
      end
    end
  end

  it "a patch failure reports through the status line, not a crash" do
    with_tempdir do |dir|
      rom = File.join(dir, "game.gba")
      File.write(rom, Bytes.new(16))
      bad_patch = File.join(dir, "bad.ips")
      File.write(bad_patch, "JUNKDATA")

      window = new_window(dir)
      begin
        patcher = window.patcher_window
        app = window.app
        patcher.rom_var.value = rom
        patcher.patch_var.value = bad_patch
        patcher.outdir_var.value = dir

        patcher.apply
        app.interp.wait_until(10.seconds) { !patcher.busy? }
        patcher.busy?.should be_false

        status = patcher.status_var.value.to_s
        status.should contain Gemba::Locale.translate("patcher.err_failed")
        status.should contain "Unknown patch format"
      ensure
        window.destroy
      end
    end
  end
end
