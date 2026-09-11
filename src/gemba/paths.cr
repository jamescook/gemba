require "tryst"

module Gemba
  # Uses the same config directories as ruby-gemba so existing user
  # data (screenshots, saves, states) remains compatible across the
  # port.
  module Paths
    APP_NAME = "gemba"

    def self.config_dir : String
      platform = Tryst.platform
      if platform.darwin?
        File.join(Path.home, "Library", "Application Support", APP_NAME)
      elsif platform.windows?
        File.join(ENV.fetch("APPDATA", File.join(Path.home, "AppData", "Roaming")), APP_NAME)
      else
        base = ENV.fetch("XDG_CONFIG_HOME", File.join(Path.home, ".config"))
        File.join(base, APP_NAME)
      end
    end

    # Where the repo's own copies live, for a build running out of a
    # source checkout. assets/ sits at the repo root while data/ and
    # locales/ sit beside this file, so the three don't share a parent -
    # hence three fallbacks rather than one source root.
    SOURCE_REPO_DIR  = File.expand_path("../..", __DIR__)
    SOURCE_GEMBA_DIR = __DIR__

    # Root of gemba's read-only bundled data (assets, the game index,
    # locale files) when running from an INSTALLED prefix - the
    # `share/gemba` the Makefile's install target writes. nil when no
    # such directory is found, which is the normal case for a build run
    # out of a source checkout.
    #
    # Deliberately not memoized: it costs one Dir.exists? and the
    # callers are all startup-time (one image create, one font load, six
    # JSON loads, one YAML load). A memo would also freeze the first
    # answer for the whole process, which GEMBA_DATA_DIR exists to let
    # specs vary.
    def self.data_root : String?
      # An explicit override wins outright and is used verbatim - a
      # wrong value must fail loudly rather than silently fall back to
      # whatever source tree happened to be on the build machine.
      if override = ENV["GEMBA_DATA_DIR"]?
        return override
      end

      if exe = Process.executable_path
        installed_data_root(exe)
      end
    end

    # ../share/gemba relative to the binary at `exe`, if it exists - so
    # bin/gemba finds share/gemba under any PREFIX (~/.local, /usr/local,
    # a Homebrew Cellar) without the prefix being compiled in. Split out
    # of data_root so a spec can hand it a fake binary path.
    #
    # Nothing is found for `crystal run` (the binary lives in a cache
    # dir) or for an in-tree build (no share/ beside bin/), and both
    # correctly fall through to the source tree.
    def self.installed_data_root(exe : String) : String?
      candidate = File.expand_path(File.join("..", "share", APP_NAME), File.dirname(exe))
      candidate if Dir.exists?(candidate)
    end

    # Absolute path to a bundled asset, e.g. "placeholder_boxart.png".
    def self.asset(name : String) : String
      if root = data_root
        File.join(root, "assets", name)
      else
        File.join(SOURCE_REPO_DIR, "assets", name)
      end
    end

    # The serial/md5 JSON files GameIndex reads.
    def self.game_data_dir : String
      if root = data_root
        File.join(root, "data")
      else
        File.join(SOURCE_GEMBA_DIR, "data")
      end
    end

    # The per-language YAML files Locale reads.
    def self.locales_dir : String
      if root = data_root
        File.join(root, "locales")
      else
        File.join(SOURCE_GEMBA_DIR, "locales")
      end
    end

    def self.screenshots_dir : String
      File.join(config_dir, "screenshots")
    end

    def self.states_dir : String
      File.join(config_dir, "states")
    end

    def self.saves_dir : String
      File.join(config_dir, "saves")
    end

    def self.boxart_dir : String
      File.join(config_dir, "boxart")
    end

    def self.logs_dir : String
      File.join(config_dir, "logs")
    end

    # Per-ROM achievement lists (see Achievements::Cache) - the same
    # directory ruby gemba writes its own to.
    def self.achievements_cache_dir : String
      File.join(config_dir, "achievements")
    end

    # .gir input recordings (and, later, .grec captures) - ruby gemba's
    # own default_recordings_dir.
    def self.recordings_dir : String
      File.join(config_dir, "recordings")
    end

    # Default output directory for patched ROMs - ruby gemba's
    # Config.default_patches_dir.
    def self.patches_dir : String
      File.join(config_dir, "patches")
    end
  end
end
