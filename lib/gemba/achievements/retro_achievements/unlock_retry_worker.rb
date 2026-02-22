# frozen_string_literal: true

module Gemba
  module Achievements
    module RetroAchievements
      # Background worker for retrying failed achievement unlock submissions.
      #
      # Defined as a named class (not a closure) so it is Ractor-safe on
      # Ruby 4+.  Receives the same flat params hash used by ra_request
      # (keys: :r, :u, :t, :a, :h).  Yields [ok, achievement_id] back to
      # the main thread via on_progress.
      class UnlockRetryWorker
        RA_HOST = "retroachievements.org"
        RA_PATH = "/dorequest.php"

        def call(t, data)
          require "net/http"
          require "json"
          uri  = URI::HTTPS.build(host: RA_HOST, path: RA_PATH)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl      = true
          http.read_timeout = 15
          req  = Net::HTTP::Post.new(uri.path)
          req['User-Agent'] = "gemba/#{Gemba::VERSION} (https://github.com/jamescook/gemba)"
          req.set_form_data(data.transform_keys(&:to_s).transform_values(&:to_s))
          resp = http.request(req)
          ok   = resp.is_a?(Net::HTTPSuccess) && JSON.parse(resp.body)["Success"]
          t.yield([ok ? true : false, data[:a].to_s])
        rescue
          t.yield([false, data[:a].to_s])
        end
      end
    end
  end
end
