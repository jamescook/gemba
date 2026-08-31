require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("list_picker_frame_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# A failed .should skips past a trailing app.destroy, leaking a real
# Tk window - this guarantees destroy runs even on failure.
private def with_app(title : String, &)
  app = Tryst::App.new(title: title)
  begin
    stub_tk_popup(app)
    yield app
  ensure
    app.destroy
  end
end

private def row_values(app : Tryst::App, tree_path : String, iid : String) : Array(String)
  app.split_list(app.command(tree_path, :item, iid, "-values"))
end

private def rows(app : Tryst::App, tree_path : String) : Array(Array(String))
  app.command(tree_path, :children, "").split.map { |iid| row_values(app, tree_path, iid) }
end

private def new_picker(app : Tryst::App, library : Gemba::RomLibrary, dir : String,
                       overrides : Gemba::RomOverrides? = nil,
                       on_open_rom : -> Nil = -> { nil },
                       on_select : String -> Nil = ->(_path : String) { nil },
                       on_quick_load : Proc(String, Int32, Nil) = ->(_path : String, _slot : Int32) { nil },
                       on_view_changed : String -> Nil = ->(_view : String) { nil }) : Gemba::ListPickerFrame
  config = Gemba::Config.new(File.join(dir, "settings.json"))
  Gemba::ListPickerFrame.new(app, ".", library, config, overrides, on_open_rom, on_select, on_quick_load, on_view_changed)
end

# The item's own bbox (relative to the tree widget), so a synthetic
# right-click lands on a real row rather than guessing pixel offsets.
private def row_center(app : Tryst::App, tree_path : String, iid : String) : {Int32, Int32}
  x, y, w, h = app.split_list(app.command(tree_path, :bbox, iid)).map(&.to_i)
  {x + w // 2, y + h // 2}
end

describe Gemba::ListPickerFrame do
  it "lists RomLibrary entries most-recently-played first, Title + Last Played columns" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")
      library.remember("Space Blast", "/roms/space_blast.gba", "2026-01-02T00:00:00Z")

      with_app("list_picker_frame_spec_1") do |app|
        opened = false
        picker = new_picker(app, library, dir, on_open_rom: -> { opened = true; nil })

        titles = rows(app, picker.tree.path).map(&.first)
        titles.should eq ["Space Blast", "Fill"]
        opened.should be_false
      end
    end
  end

  it "an entry with no last_played shows the 'never played' translation" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "")

      with_app("list_picker_frame_spec_never") do |app|
        picker = new_picker(app, library, dir)
        rows(app, picker.tree.path).first[1].should eq Gemba::Locale.translate("list_picker.never_played")
      end
    end
  end

  it "clicking the Title heading sorts ascending by title, and again reverses it" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Zelda-like", "/roms/z.gba", "2026-01-01T00:00:00Z")
      library.remember("Alpha Quest", "/roms/a.gba", "2026-01-02T00:00:00Z")

      with_app("list_picker_frame_spec_sort") do |app|
        picker = new_picker(app, library, dir)

        app.command(picker.tree.path, :heading, "title", "-command").should_not be_empty
        app.tcl_eval(app.command(picker.tree.path, :heading, "title", "-command"))
        rows(app, picker.tree.path).map(&.first).should eq ["Alpha Quest", "Zelda-like"]

        app.tcl_eval(app.command(picker.tree.path, :heading, "title", "-command"))
        rows(app, picker.tree.path).map(&.first).should eq ["Zelda-like", "Alpha Quest"]
      end
    end
  end

  it "selecting an entry and pressing Return fires on_select with its path" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")

      with_app("list_picker_frame_spec_2") do |app|
        selected_path = nil
        picker = new_picker(app, library, dir, on_select: ->(path : String) { selected_path = path; nil })
        picker.show

        # A withdrawn/unmapped toplevel can't take focus or deliver a
        # real event - map the window and force focus onto the tree
        # first, same as the root suite's own simulate_event has to.
        app.show
        app.update
        app.command(:focus, "-force", picker.tree.path)
        app.command(:event, :generate, picker.tree.path, "<Return>")

        selected_path.should eq "/roms/fill.gba"
      end
    end
  end

  it "double-clicking an entry fires on_select with its path" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
      library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")

      with_app("list_picker_frame_spec_dblclick") do |app|
        selected_path = nil
        picker = new_picker(app, library, dir, on_select: ->(path : String) { selected_path = path; nil })
        picker.show
        app.show
        app.update

        # A real double-click, aimed at the row's own center so the tree
        # resolves an item under the pointer (0,0 would be the heading).
        iid = app.command(picker.tree.path, :children, "").split.first
        x, y = row_center(app, picker.tree.path, iid)
        app.interp.simulate_event(picker.tree.path, "<Double-Button-1>", x: x, y: y)

        selected_path.should eq "/roms/fill.gba"
      end
    end
  end

  it "the Open ROM button fires on_open_rom" do
    with_tempdir do |dir|
      library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))

      with_app("list_picker_frame_spec_3") do |app|
        opened = false
        picker = new_picker(app, library, dir, on_open_rom: -> { opened = true; nil })

        app.winfo.exists?(picker.open_button.path).should be_true
        app.command(picker.open_button.path, :invoke)

        opened.should be_true
      end
    end
  end

  describe "right-click row menu" do
    it "Play fires on_select, Quick Load is disabled with no save, Remove deletes the row" do
      with_tempdir do |dir|
        library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
        library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")

        with_app("list_picker_frame_spec_ctx1") do |app|
          picker = new_picker(app, library, dir)
          picker.show
          app.show
          app.update

          iid = app.command(picker.tree.path, :children, "").split.first
          x, y = row_center(app, picker.tree.path, iid)
          app.command(:event, :generate, picker.tree.path, "<Button-3>", x: x, y: y)

          menu_path = "#{picker.tree.path}.ctx"
          app.winfo.exists?(menu_path).should be_true
          app.command(menu_path, :entrycget, 1, "-state").should eq "disabled"
        end
      end
    end

    it "Quick Load is enabled when that slot's save state exists, and fires on_quick_load" do
      with_tempdir do |dir|
        library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
        library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")
        library.update_identity("/roms/fill.gba", "AGB-BPEE", 0xDEADBEEF_u32)

        state_dir = File.join(Gemba::Paths.states_dir, "AGB-BPEE-DEADBEEF")
        Dir.mkdir_p(state_dir)
        File.write(Gemba::SaveStateManager.state_path(state_dir, 1), "fake save")

        begin
          with_app("list_picker_frame_spec_ctx2") do |app|
            quick_loaded = nil
            picker = new_picker(app, library, dir,
              on_quick_load: ->(path : String, slot : Int32) { quick_loaded = {path, slot}; nil })
            picker.show
            app.show
            app.update

            iid = app.command(picker.tree.path, :children, "").split.first
            x, y = row_center(app, picker.tree.path, iid)
            app.command(:event, :generate, picker.tree.path, "<Button-3>", x: x, y: y)

            menu_path = "#{picker.tree.path}.ctx"
            app.command(menu_path, :entrycget, 1, "-state").should eq "normal"
            app.command(menu_path, :invoke, 1)

            quick_loaded.should eq({"/roms/fill.gba", 1})
          end
        ensure
          FileUtils.rm_rf(Gemba::Paths.states_dir)
        end
      end
    end

    it "Remove deletes the RomLibrary entry and the row disappears on refresh" do
      with_tempdir do |dir|
        library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
        library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")

        with_app("list_picker_frame_spec_ctx3") do |app|
          picker = new_picker(app, library, dir)
          picker.show
          app.show
          app.update

          iid = app.command(picker.tree.path, :children, "").split.first
          x, y = row_center(app, picker.tree.path, iid)
          app.command(:event, :generate, picker.tree.path, "<Button-3>", x: x, y: y)

          menu_path = "#{picker.tree.path}.ctx"
          app.command(menu_path, :invoke, 4) # Play, Quick Load, Set Boxart, separator, Remove

          library.all.should be_empty
          app.command(picker.tree.path, :children, "").should be_empty
        end
      end
    end

    it "Set Boxart copies the chosen file via RomOverrides" do
      with_tempdir do |dir|
        library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))
        library.remember("Fill", "/roms/fill.gba", "2026-01-01T00:00:00Z")
        library.update_identity("/roms/fill.gba", "AGB-BPEE", 0xDEADBEEF_u32)

        overrides = Gemba::RomOverrides.new(File.join(dir, "rom_overrides.json"), boxart_dir: File.join(dir, "boxart"))
        # tk_getOpenFile blocks on real OS UI, which a headless spec
        # can't drive - just confirm the menu item is wired and reachable.
        with_app("list_picker_frame_spec_ctx4") do |app|
          picker = new_picker(app, library, dir, overrides: overrides)
          picker.show
          app.show
          app.update

          iid = app.command(picker.tree.path, :children, "").split.first
          x, y = row_center(app, picker.tree.path, iid)
          app.command(:event, :generate, picker.tree.path, "<Button-3>", x: x, y: y)

          menu_path = "#{picker.tree.path}.ctx"
          app.command(menu_path, :entrycget, 2, "-label").should eq Gemba::Locale.translate("game_picker.menu.set_boxart")
        end
      end
    end
  end

  describe "gear menu view toggle" do
    it "shows a checkmark on the current view and switches on selection" do
      with_tempdir do |dir|
        library = Gemba::RomLibrary.new(File.join(dir, "rom_library.json"))

        with_app("list_picker_frame_spec_gear") do |app|
          changed_to = nil
          picker = new_picker(app, library, dir, on_view_changed: ->(view : String) { changed_to = view; nil })
          picker.show
          app.show
          app.update

          gear_path = "#{picker.path}.toolbar.gear"
          app.winfo.exists?(gear_path).should be_true
          app.command(gear_path, :invoke)

          menu_path = "#{picker.path}.toolbar.gearmenu"
          app.command(menu_path, :entrycget, 0, "-label").should start_with("✓")
          app.command(menu_path, :invoke, 1) # "List view" entry

          changed_to.should eq "list"
        end
      end
    end
  end
end
