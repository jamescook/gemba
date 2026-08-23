require "../spec_helper"

describe Gemba::Locale do
  after_each { Gemba::Locale.load("en") }

  it "loads en by default and translates a known key" do
    Gemba::Locale.load("en")
    Gemba::Locale.translate("menu.file").should eq "File"
  end

  it "returns the key itself for an unknown key" do
    Gemba::Locale.translate("menu.does_not_exist").should eq "menu.does_not_exist"
  end

  it "interpolates {name}-style variables" do
    Gemba::Locale.load("en")
    Gemba::Locale.translate("toast.state_saved", slot: 3).should eq "State saved to slot 3"
  end

  it "falls back to English for a locale file that doesn't exist" do
    Gemba::Locale.load("xx")
    Gemba::Locale.translate("menu.file").should eq "File"
  end

  it "loads a real second locale (ja) with the same key set" do
    Gemba::Locale.load("ja")
    Gemba::Locale.translate("menu.file").should_not eq "File"
    Gemba::Locale.translate("menu.file").should_not eq "menu.file"
  end

  it "flattens keys nested a level deeper than the common 2-level shape" do
    Gemba::Locale.load("en")
    Gemba::Locale.translate("picker.toolbar.boxart_view").should eq "Box art view"
  end

  # YAML duplicate keys silently overwrite, not merge - verifies both
  # "picker:" declarations survived.
  it "the save-state picker's own labels survive alongside game_picker's toolbar labels" do
    Gemba::Locale.load("en")
    Gemba::Locale.translate("picker.title").should eq "Save States"
    Gemba::Locale.translate("picker.empty").should eq "Empty"
    Gemba::Locale.translate("picker.no_preview").should eq "No preview"
    Gemba::Locale.translate("picker.slot", n: 3).should eq "Slot 3"
    Gemba::Locale.translate("picker.close").should eq "Close"
    Gemba::Locale.translate("picker.toolbar.boxart_view").should eq "Box art view"
    Gemba::Locale.translate("picker.toolbar.list_view").should eq "List view"
  end

  it "#available_languages includes both shipped locales" do
    Gemba::Locale.available_languages.should eq ["en", "ja"]
  end

  it "#language reflects the last loaded locale" do
    Gemba::Locale.load("ja")
    Gemba::Locale.language.should eq "ja"
  end
end
