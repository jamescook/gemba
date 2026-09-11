require "../spec_helper"
require "file_utils"

private def with_tempdir(&)
  dir = File.tempname("paths_spec")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Gemba::Paths do
  describe ".data_root" do
    it "returns nil for a spec/dev build, so callers fall back to the source tree" do
      # The spec binary lives in a Crystal cache dir with no share/gemba
      # beside it - the same shape `crystal run` and an in-tree `shards
      # build` produce.
      Gemba::Paths.data_root.should be_nil
    end

    it "returns GEMBA_DATA_DIR verbatim when set, without checking it exists" do
      # Verbatim on purpose: a wrong override must fail loudly at the
      # point of use rather than silently fall back to whatever source
      # tree happened to be on the build machine.
      with_data_dir("/nonexistent/share/gemba") do
        Gemba::Paths.data_root.should eq "/nonexistent/share/gemba"
      end
    end

    it "prefers GEMBA_DATA_DIR over anything found beside the binary" do
      with_tempdir do |dir|
        with_data_dir(dir) { Gemba::Paths.data_root.should eq dir }
      end
    end
  end

  describe "the three bundled-data accessors" do
    it "resolve under data_root when one is set" do
      with_tempdir do |dir|
        with_data_dir(dir) do
          Gemba::Paths.asset("placeholder_boxart.png")
            .should eq File.join(dir, "assets", "placeholder_boxart.png")
          Gemba::Paths.game_data_dir.should eq File.join(dir, "data")
          Gemba::Paths.locales_dir.should eq File.join(dir, "locales")
        end
      end
    end

    it "fall back to the source tree's own three locations with no data_root" do
      # assets/ at the repo root, data/ and locales/ beside paths.cr -
      # the layout a checkout actually has, which is why there are three
      # fallbacks rather than one source root.
      Gemba::Paths.asset("placeholder_boxart.png")
        .should eq File.join(Gemba::Paths::SOURCE_REPO_DIR, "assets", "placeholder_boxart.png")
      Gemba::Paths.game_data_dir.should eq File.join(Gemba::Paths::SOURCE_GEMBA_DIR, "data")
      Gemba::Paths.locales_dir.should eq File.join(Gemba::Paths::SOURCE_GEMBA_DIR, "locales")
    end

    it "point at files that really exist in a source checkout" do
      File.exists?(Gemba::Paths.asset("placeholder_boxart.png")).should be_true
      File.exists?(Gemba::Paths.asset("JetBrainsMonoNL-Regular.ttf")).should be_true
      File.exists?(File.join(Gemba::Paths.game_data_dir, "gba_games.json")).should be_true
      File.exists?(File.join(Gemba::Paths.locales_dir, "en.yml")).should be_true
    end
  end

  describe ".installed_data_root" do
    it "finds share/gemba beside the binary's bin/" do
      # The layout `make install` writes: PREFIX/bin/gemba alongside
      # PREFIX/share/gemba. The binary itself need not exist - only its
      # path is used - so no release build is needed inside a spec.
      with_tempdir do |prefix|
        Dir.mkdir_p(File.join(prefix, "share", "gemba"))

        Gemba::Paths.installed_data_root(File.join(prefix, "bin", "gemba"))
          .should eq File.join(prefix, "share", "gemba")
      end
    end

    it "returns nil when there is no share/gemba beside the binary" do
      # An in-tree build: bin/gemba with no share/ next to bin/.
      with_tempdir do |prefix|
        Gemba::Paths.installed_data_root(File.join(prefix, "bin", "gemba")).should be_nil
      end
    end
  end
end
