# frozen_string_literal: true

module Gemba
  module Achievements
    module RetroAchievements
      # Background worker for the RA session ping heartbeat.
      #
      # Defined as a named class (not a closure) so it is Ractor-safe on
      # Ruby 4+.  All state is passed through the data hash; no captured
      # variables.
      class PingWorker
        def call(t, data)
          require "net/http"
          uri  = URI::HTTPS.build(host: data[:host], path: data[:path])
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl      = true
          http.read_timeout = 10
          req  = Net::HTTP::Post.new(uri.path)
          req.set_form_data(data[:params])
          t.yield(http.request(req).is_a?(Net::HTTPSuccess))
        rescue
          t.yield(false)
        end
      end
    end
  end
end
