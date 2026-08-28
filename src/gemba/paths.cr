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
  end
end
