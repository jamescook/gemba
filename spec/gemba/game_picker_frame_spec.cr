require "../spec_helper"
require "file_utils"
require "base64"

private def with_tempdir(&)
  dir = File.tempname("game_picker_frame_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Guarantees app.destroy runs even if an assertion inside the block
# fails/raises - see list_picker_frame_spec.cr's own with_app for why
# this matters (a failed .should otherwise leaks a real Tk window).
private def with_app(title : String, &)
  app = Tryst::App.new(title: title)
  begin
    stub_tk_popup(app)
    yield app
  ensure
    app.destroy
  end
end

private class FakeBackend < Gemba::BoxartFetcher::Backend
  def url_for(game_code : String) : String?
    nil
  end
end

private def new_picker(app : Tryst::App, library : Gemba::RomLibrary, dir : String,
                       fetcher : Gemba::BoxartFetcher? = nil,
                       overrides : Gemba::RomOverrides? = nil,
                       on_open_rom : -> Nil = -> { nil },
                       on_select : String -> Nil = ->(_path : String) { nil },
                       on_quick_load : Proc(String, Int32, Nil) = ->(_path : String, _slot : Int32) { nil },
                       on_view_changed : String -> Nil = ->(_view : String) { nil }) : Gemba::GamePickerFrame
  config = Gemba::Config.new(File.join(dir, "settings.json"))
  Gemba::GamePickerFrame.new(app, ".", library, config, fetcher, overrides,
    on_open_rom, on_select, on_quick_load, on_view_changed)
end

private ONE_PIXEL_PNG = Base64.decode(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)

describe Gemba::GamePickerFrame do
  it "builds a full #{Gemba::GamePickerFrame::SLOTS}-card grid, populated first, hollow after" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")
      library.remember("Space Blast", "/roms/space_blast.gba", "2026-01-02T00:00:00Z")

      with_app("game_picker_1") do |app|
        picker = new_picker(app, library, dir)

        picker.cards.size.should eq Gemba::GamePickerFrame::SLOTS
        app.command(picker.cards[0].title.path, :cget, "-text").should eq "Space Blast"
        app.command(picker.cards[1].title.path, :cget, "-text").should eq "Fill"
        (2...Gemba::GamePickerFrame::SLOTS).each do |i|
          app.command(picker.cards[i].title.path, :cget, "-text").should eq ""
        end
      end
    end
  end

  it "left-clicking a populated card fires on_select with its path" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")

      with_app("game_picker_2") do |app|
        selected_path = nil
        picker = new_picker(app, library, dir, on_select: ->(path : String) { selected_path = path; nil })

        # Shown and updated first: simulate_event refuses an unviewable
        # target, because Tk silently drops events aimed at one.
        picker.show
        app.show
        app.update

        app.tcl_invoke("bind", picker.cards[0].frame.path, "<Button-1>").should_not be_empty
        app.interp.simulate_event(picker.cards[0].frame.path, "<Button-1>")

        selected_path.should eq "/roms/fill.gba"
      end
    end
  end

  it "a hollow (empty) card has no click binding" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))

      with_app("game_picker_3") do |app|
        picker = new_picker(app, library, dir)
        app.tcl_invoke("bind", picker.cards[0].frame.path, "<Button-1>").should be_empty
      end
    end
  end

  it "right-clicking a populated card opens the Play/Quick Load/Set Boxart/Remove menu" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")

      with_app("game_picker_4") do |app|
        picker = new_picker(app, library, dir)
        picker.show
        app.show
        app.update

        # <<ContextMenu>>, not <Button-3>: GamePickerFrame binds the
        # portable virtual event (see EventSpec::VIRTUAL_ALIASES), which
        # sits on a different physical button per platform.
        app.tcl_invoke("bind", picker.cards[0].frame.path, "<<ContextMenu>>").should_not be_empty
        app.interp.simulate_event(picker.cards[0].frame.path, "<<ContextMenu>>")

        menu_path = "#{picker.cards[0].frame.path}.ctx"
        app.winfo.exists?(menu_path).should be_true
        app.command(menu_path, :entrycget, 0, "-label").should eq Gemba::Locale.translate("game_picker.menu.play")
      end
    end
  end

  it "the Open ROM button fires on_open_rom" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))

      with_app("game_picker_5") do |app|
        opened = false
        picker = new_picker(app, library, dir, on_open_rom: -> { opened = true; nil })

        app.winfo.exists?(picker.open_button.path).should be_true
        app.command(picker.open_button.path, :invoke)

        opened.should be_true
      end
    end
  end

  it "starts with the placeholder image, immediately, before box art resolves" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")

      with_app("game_picker_6") do |app|
        picker = new_picker(app, library, dir, fetcher: Gemba::BoxartFetcher.new(app, File.join(dir, "cache"), FakeBackend.new))
        app.command(picker.cards[0].image.path, :cget, "-image").should eq "gemba_boxart_placeholder"

        # BoxartFetcher#fetch's callback fires on its own spawned fiber
        # and touches this card's Tk image directly (see its own doc
        # comment) - draining it before `with_app`'s `ensure app.destroy`
        # runs, same as the next test does, so that callback can't land
        # on an already-destroyed app. Confirmed directly: skipping this
        # segfaults under Docker/Xvfb (BadDrawable on X_GetGeometry),
        # deterministically, not a flake.
        sleep 50.milliseconds
        app.update
      end
    end
  end

  it "stays on the placeholder once box art resolution finishes, when there's no cached/custom art" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")

      with_app("game_picker_6b") do |app|
        picker = new_picker(app, library, dir, fetcher: Gemba::BoxartFetcher.new(app, File.join(dir, "cache"), FakeBackend.new))

        # Deferred #load_boxart has no box art to resolve, so no
        # observable change to wait_until on.
        sleep 50.milliseconds
        app.update

        app.command(picker.cards[0].image.path, :cget, "-image").should eq "gemba_boxart_placeholder"
      end
    end
  end

  it "shows the real cached boxart image, scaled, once box art resolution finishes (not blocking construction)" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")
      library.update_identity("/roms/fill.gba", "AGB-BPEE", 0xDEADBEEF_u32)

      cache_dir = File.join(dir, "cache")
      Dir.mkdir_p(File.join(cache_dir, "AGB-BPEE"))
      File.write(File.join(cache_dir, "AGB-BPEE", "boxart.png"), ONE_PIXEL_PNG)

      with_app("game_picker_7") do |app|
        picker = new_picker(app, library, dir, fetcher: Gemba::BoxartFetcher.new(app, cache_dir, FakeBackend.new))

        # Immediately after construction, box art resolution hasn't run
        # yet - still the placeholder. This is the whole point: the grid
        # (with real titles/bindings already in place) doesn't wait on
        # box art to appear.
        app.command(picker.cards[0].image.path, :cget, "-image").should eq "gemba_boxart_placeholder"

        finished = app.interp.wait_until(2.seconds) do
          app.command(picker.cards[0].image.path, :cget, "-image") != "gemba_boxart_placeholder"
        end

        finished.should be_true
        image_name = app.command(picker.cards[0].image.path, :cget, "-image")
        image_name.should_not eq "gemba_boxart_placeholder"
        image_name.should_not be_empty
      end
    end
  end

  describe "gear menu view toggle" do
    it "switches to list on selection" do
      with_tempdir do |dir|
        library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))

        with_app("game_picker_gear") do |app|
          changed_to = nil
          picker = new_picker(app, library, dir, on_view_changed: ->(view : String) { changed_to = view; nil })

          gear_path = "#{picker.path}.toolbar.gear"
          app.winfo.exists?(gear_path).should be_true
          app.command(gear_path, :invoke)

          menu_path = "#{picker.path}.toolbar.gearmenu"
          app.command(menu_path, :invoke, 1) # "List view" entry

          changed_to.should eq "list"
        end
      end
    end
  end
end
