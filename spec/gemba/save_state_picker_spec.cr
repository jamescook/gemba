require "../spec_helper"
require "file_utils"

private def build(title : String) : {Tryst::App, Gemba::SaveStatePicker}
  session = Tryst::UI::Session.new(title: title)
  handle = session.window(:gemba_save_states, title: "Save States", modal: true)
  app = session.run_async.app
  picker = Gemba::SaveStatePicker.new(app, handle)
  {app, picker}
end

private def with_tempdir(&)
  dir = File.tempname("save_state_picker_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# A real double-click: simulate_event expands the repeat modifier into
# the timed press/release burst Tk's own click counting turns back into
# a double-click.
private def double_click(app : Tryst::App, path : String) : Nil
  app.interp.simulate_event(path, "<Double-Button-1>")
end

private def cell_path(picker : Gemba::SaveStatePicker, slot : Int32) : String
  "#{picker.handle.path}.grid.slot#{slot}"
end

# Writes a tiny, real PNG via Tk's own photo image - not a hand-authored
# fixture file - so #refresh has something real to load and subsample.
private def write_fixture_png(app : Tryst::App, path : String) : Nil
  photo = Tryst::Photo.new(app, width: 240, height: 160)
  photo.command(:write, path, format: "png")
  photo.delete
end

# <<ContextMenu>> is the portable virtual event :right_click binds
# (see Tryst::EventSpec) - simulate_event delivers it for real
# (deiconify + focus + `event generate`), no raw binding-script
# round-trip needed.
private def open_slot_menu(app : Tryst::App, picker : Gemba::SaveStatePicker, slot : Int32) : String
  app.interp.simulate_event(cell_path(picker, slot), "<<ContextMenu>>")
  "#{cell_path(picker, slot)}.ctx"
end

describe Gemba::SaveStatePicker do
  it "#refresh shows Empty for a slot with no save, and the timestamp for one with a save" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_1")
      File.write(Gemba::SaveStateManager.state_path(dir, 1), "fake state")

      picker.refresh(dir, quick_slot: 1)

      thumb1 = "#{cell_path(picker, 1)}.thumb"
      app.command(thumb1, :cget, "-text").should eq "No preview"

      thumb2 = "#{cell_path(picker, 2)}.thumb"
      app.command(thumb2, :cget, "-text").should eq "Empty"

      time1 = "#{cell_path(picker, 1)}.time"
      app.command(time1, :cget, "-text").should_not be_empty

      app.destroy
    end
  end

  it "#refresh loads the thumbnail straight from a PNG state file, subsampled to thumbnail size" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_2")
      # mgba writes states as real PNGs (see Core#save_state_to_file);
      # a Tk-written PNG at the state path stands in for one here.
      write_fixture_png(app, Gemba::SaveStateManager.state_path(dir, 3))

      picker.refresh(dir, quick_slot: 1)

      thumb3 = "#{cell_path(picker, 3)}.thumb"
      app.command(thumb3, :cget, "-text").should eq ""
      image_name = app.command(thumb3, :cget, "-image")
      image_name.should_not be_empty
      app.tcl_invoke("image", "width", image_name).to_i.should eq Gemba::SaveStatePicker::THUMB_W
      app.tcl_invoke("image", "height", image_name).to_i.should eq Gemba::SaveStatePicker::THUMB_H

      app.destroy
    end
  end

  it "#refresh falls back to the legacy state<slot>.png beside a non-PNG state file" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_8")
      File.write(Gemba::SaveStateManager.state_path(dir, 3), "fake state")
      write_fixture_png(app, Gemba::SaveStateManager.screenshot_path(dir, 3))

      picker.refresh(dir, quick_slot: 1)

      thumb3 = "#{cell_path(picker, 3)}.thumb"
      app.command(thumb3, :cget, "-text").should eq ""
      app.command(thumb3, :cget, "-image").should_not be_empty

      app.destroy
    end
  end

  it "highlights the quick-save slot's border and no other's" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_3")

      picker.refresh(dir, quick_slot: 4)

      app.command(cell_path(picker, 4), :cget, "-relief").should eq "solid"
      app.command(cell_path(picker, 1), :cget, "-relief").should eq "groove"

      app.destroy
    end
  end

  it "double-clicking a populated slot fires #on_load, not #on_save" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_4")
      File.write(Gemba::SaveStateManager.state_path(dir, 2), "fake state")
      picker.refresh(dir, quick_slot: 1)

      loaded = nil
      saved = nil
      picker.on_load { |slot| loaded = slot }
      picker.on_save { |slot| saved = slot }

      double_click(app, cell_path(picker, 2))

      loaded.should eq 2
      saved.should be_nil

      app.destroy
    end
  end

  it "double-clicking an empty slot fires #on_save, not #on_load" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_5")
      picker.refresh(dir, quick_slot: 1)

      loaded = nil
      saved = nil
      picker.on_load { |slot| loaded = slot }
      picker.on_save { |slot| saved = slot }

      double_click(app, "#{cell_path(picker, 5)}.thumb")

      saved.should eq 5
      loaded.should be_nil

      app.destroy
    end
  end

  it "a slot has no plain single-click binding at all - only Double-Button-1" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_7")
      picker.refresh(dir, quick_slot: 1)

      app.tcl_invoke("bind", cell_path(picker, 2), "<Button-1>").should eq ""
      app.tcl_invoke("bind", "#{cell_path(picker, 2)}.thumb", "<Button-1>").should eq ""

      app.destroy
    end
  end

  it "right-clicking a populated slot offers Load/Overwrite/Delete; an empty one offers only Save" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_9")
      stub_tk_popup(app)
      File.write(Gemba::SaveStateManager.state_path(dir, 2), "fake state")
      picker.refresh(dir, quick_slot: 1)

      menu = open_slot_menu(app, picker, 2)
      app.command(menu, :entrycget, 0, "-label").should eq "Load"
      app.command(menu, :entrycget, 1, "-label").should eq "Overwrite"
      app.command(menu, :entrycget, 3, "-label").should eq "Delete…"

      empty_menu = open_slot_menu(app, picker, 5)
      app.command(empty_menu, :entrycget, 0, "-label").should eq "Save"
      app.tcl_invoke(empty_menu, "index", "end").should eq "0"

      app.destroy
    end
  end

  it "the menu's Overwrite fires on_save for a populated slot - the action double-click can't reach" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_10")
      stub_tk_popup(app)
      File.write(Gemba::SaveStateManager.state_path(dir, 2), "fake state")
      picker.refresh(dir, quick_slot: 1)

      saved = nil
      loaded = nil
      picker.on_save { |slot| saved = slot }
      picker.on_load { |slot| loaded = slot }

      menu = open_slot_menu(app, picker, 2)
      app.tcl_invoke(menu, "invoke", "1")

      saved.should eq 2
      loaded.should be_nil

      app.destroy
    end
  end

  it "#delete_slot removes the state, its backup, and the legacy PNG once confirmed, and redraws" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_11")
      ss = Gemba::SaveStateManager.state_path(dir, 2)
      File.write(ss, "fake state")
      File.write("#{ss}.bak", "old state")
      write_fixture_png(app, Gemba::SaveStateManager.screenshot_path(dir, 2))
      picker.refresh(dir, quick_slot: 1)

      asked = nil
      picker.delete_prompt = ->(slot : Int32) { asked = slot; true }
      picker.delete_slot(2)

      asked.should eq 2
      File.exists?(ss).should be_false
      File.exists?("#{ss}.bak").should be_false
      File.exists?(Gemba::SaveStateManager.screenshot_path(dir, 2)).should be_false
      thumb2 = "#{cell_path(picker, 2)}.thumb"
      app.command(thumb2, :cget, "-text").should eq "Empty"

      app.destroy
    end
  end

  it "#delete_slot leaves everything in place when the prompt declines" do
    with_tempdir do |dir|
      app, picker = build("save_state_picker_spec_12")
      ss = Gemba::SaveStateManager.state_path(dir, 2)
      File.write(ss, "fake state")
      picker.refresh(dir, quick_slot: 1)

      picker.delete_prompt = ->(_slot : Int32) { false }
      picker.delete_slot(2)

      File.exists?(ss).should be_true
      app.command("#{cell_path(picker, 2)}.time", :cget, "-text").should_not be_empty

      app.destroy
    end
  end

  it "#on_close fires when the Close button is clicked" do
    session = Tryst::UI::Session.new(title: "save_state_picker_spec_6")
    handle = session.window(:gemba_save_states, title: "Save States", modal: true)
    app = session.run_async.app
    picker = Gemba::SaveStatePicker.new(app, handle)

    closed = false
    picker.on_close { closed = true }
    app.tcl_invoke("#{handle.path}.close_row.close", "invoke")

    closed.should be_true
    app.destroy
  end
end
