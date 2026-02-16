# frozen_string_literal: true

# Shared runtime for gemba — loads the C extension, config, locale,
# core, and ROM loader. Both the full GUI and headless entry points
# require this.

require "teek/platform"
require "gemba_ext"
require_relative "version"
require_relative "config"
require_relative "locale"
require_relative "core"
require_relative "rom_loader"

module Gemba
  ASSETS_DIR = File.expand_path('../../assets', __dir__).freeze

  # Lazily loaded user config — shared across the application.
  # @return [Gemba::Config]
  def self.user_config
    @user_config ||= Config.new
  end

  # Override the user config (useful for tests).
  # @param config [Gemba::Config, nil] pass nil to reset to default
  def self.user_config=(config)
    @user_config = config
  end

  # Load translations based on the config locale setting.
  def self.load_locale
    lang = user_config.locale
    lang = nil if lang == 'auto'
    Locale.load(lang)
  end

  # Initialize locale on require
  load_locale
end
