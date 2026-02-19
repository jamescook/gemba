# frozen_string_literal: true

# Shared bootstrap — explicitly required by lib/gemba.rb (full GUI) and
# lib/gemba/headless.rb (no Tk/SDL2).  Sets up Zeitwerk autoloading,
# loads the C extension, and initializes the locale.

require "zeitwerk"
require "teek/platform"
require "gemba_ext"

# Define the Gemba module before loader.setup so Zeitwerk can register
# autoloads directly on it (e.g. Gemba.autoload(:ChildWindow, ...)).
# Without this, Gemba doesn't exist yet and Zeitwerk proxies through
# lib/gemba.rb — which is never loaded in the headless path.
module Gemba
  ASSETS_DIR = File.expand_path('../../assets', __dir__).freeze

  class << self
    # Lazily loaded user config — shared across the application.
    # @return [Gemba::Config]
    def user_config
      @user_config ||= Config.new
    end

    # Override the user config (useful for tests).
    # @param config [Gemba::Config, nil] pass nil to reset to default
    attr_writer :user_config

    # Load translations based on the config locale setting.
    def load_locale
      lang = user_config.locale
      lang = nil if lang == 'auto'
      Locale.load(lang)
    end

    # Event bus — auto-created on first access.
    # AppController replaces it with a fresh bus at startup.
    def bus
      @bus ||= EventBus.new
    end

    attr_writer :bus

    # Session logger — lazily initialized on first write.
    def logger
      @logger ||= SessionLogger.new
    end

    attr_writer :logger

    # Log a message at the given level.
    # @example Gemba.log(:warn) { "something went wrong" }
    def log(level = :info, &block)
      logger.log(level, &block)
    end
  end
end

loader = Zeitwerk::Loader.new
loader.push_dir(File.expand_path("../..", __FILE__))  # lib/ as root
loader.inflector.inflect("gba" => "GBA", "gb" => "GB", "gbc" => "GBC", "cli" => "CLI")
loader.ignore(__FILE__)  # bootstrap file — not a constant
loader.ignore(File.expand_path("../../gemba.rb", __FILE__))  # entry point, not a constant
loader.setup

# Initialize locale on require
Gemba.load_locale
