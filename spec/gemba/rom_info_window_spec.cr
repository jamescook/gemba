require "../spec_helper"

private def fixture_data : Gemba::RomInfoData
  Gemba::RomInfoData.new(
    title: "SPACE BLAST", game_code: "AGB-SPBE", maker_code: "01",
    platform: "Game Boy Advance", rom_size: 2_097_152_u64,
    checksum: 0xDEADBEEF_u32, width: 240, height: 160,
  )
end

describe Gemba::RomInfoWindow do
  it "#show populates every field from a RomInfoData snapshot" do
    session = Tryst::UI::Session.new(title: "rom_info_window_spec_1")
    window = Gemba::RomInfoWindow.new(session)
    app = session.run_async.app

    window.show(fixture_data, "/roms/space_blast.gba", "/saves/space_blast.sav")

    window.field("title").should eq "SPACE BLAST"
    window.field("game_code").should eq "AGB-SPBE"
    window.field("publisher").should eq "Nintendo (01)"
    window.field("platform").should eq "Game Boy Advance"
    window.field("rom_size").should eq "2.0 MB (2097152 bytes)"
    window.field("checksum").should eq "0xDEADBEEF"
    window.field("rom_path").should eq "/roms/space_blast.gba"
    window.field("save_path").should eq "/saves/space_blast.sav"
    window.field("resolution").should eq "240x160"

    app.destroy
  end

  it "shows \"Unknown (XX)\" for a maker code not in the table" do
    session = Tryst::UI::Session.new(title: "rom_info_window_spec_2")
    window = Gemba::RomInfoWindow.new(session)
    app = session.run_async.app

    data = Gemba::RomInfoData.new(
      title: "MYSTERY GAME", game_code: "AGB-ZZZZ", maker_code: "ZZ",
      platform: "Game Boy Advance", rom_size: 1024_u64,
      checksum: 0_u32, width: 240, height: 160,
    )
    window.show(data, "/roms/mystery.gba", "/saves/mystery.sav")

    window.field("publisher").should eq "Unknown (ZZ) (ZZ)"

    app.destroy
  end

  it "shows the window on #show and hides it via #handle.hide" do
    session = Tryst::UI::Session.new(title: "rom_info_window_spec_3")
    window = Gemba::RomInfoWindow.new(session)
    app = session.run_async.app

    window.show(fixture_data, "/roms/space_blast.gba", "/saves/space_blast.sav")
    app.command(:wm, "state", window.handle.path).should eq "normal"

    window.handle.hide
    app.command(:wm, "state", window.handle.path).should eq "withdrawn"

    app.destroy
  end

  it "clicking the in-window Close button fires #on_close instead of just hiding" do
    session = Tryst::UI::Session.new(title: "rom_info_window_spec_4")
    window = Gemba::RomInfoWindow.new(session)
    app = session.run_async.app

    closed = false
    window.on_close { closed = true }

    window.show(fixture_data, "/roms/space_blast.gba", "/saves/space_blast.sav")
    app.tcl_invoke(window.close_button.path, "invoke")

    closed.should be_true

    app.destroy
  end

  it "with no #on_close wired, the Close button falls back to plain #hide" do
    session = Tryst::UI::Session.new(title: "rom_info_window_spec_5")
    window = Gemba::RomInfoWindow.new(session)
    app = session.run_async.app

    window.show(fixture_data, "/roms/space_blast.gba", "/saves/space_blast.sav")
    app.command(:wm, "state", window.handle.path).should eq "normal"

    app.tcl_invoke(window.close_button.path, "invoke")
    app.command(:wm, "state", window.handle.path).should eq "withdrawn"

    app.destroy
  end
end
