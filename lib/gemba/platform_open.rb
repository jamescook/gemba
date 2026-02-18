# frozen_string_literal: true

require 'fileutils'

module Gemba
  # Open a directory in the platform's file manager.
  # @param dir [String] directory path (created if missing)
  def self.open_directory(dir)
    FileUtils.mkdir_p(dir) unless File.directory?(dir)
    p = Teek.platform
    if p.darwin?
      system('open', dir)
    elsif p.windows?
      system('explorer.exe', dir)
    else
      system('xdg-open', dir)
    end
  end
end
