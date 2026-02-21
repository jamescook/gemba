# frozen_string_literal: true

require "net/http"
require "json"

module Gemba
  module Achievements
    module RetroAchievements
      # Synchronous HTTP requester for CLI use.
      #
      # Implements the same interface as FakeRequester and the DEFAULT_REQUESTER
      # lambda in Backend — call() returns a Result that fires on_progress
      # synchronously — but makes a real blocking Net::HTTP POST instead of
      # delegating to Teek::BackgroundWork.
      #
      # This means CLI commands get their result back in-line with no event loop.
      class CliSyncRequester
        # Mirrors FakeRequester::Result so the calling code (ra_request) is
        # identical regardless of whether it's running in CLI or GUI mode.
        class Result
          def initialize(value)
            @value = value
          end

          def on_progress(&block)
            block.call(@value)
            self
          end

          def on_done(&block)
            self
          end
        end

        # Called by ra_request with the same signature as the DEFAULT_REQUESTER
        # lambda. Ignores the BackgroundWork block (which uses t.yield / Ractor
        # protocol) and performs a direct synchronous HTTP POST instead.
        def call(_app, params, mode: nil, **_opts, &_block)
          Result.new(perform(params))
        end

        private

        def perform(params)
          uri  = URI::HTTPS.build(host: Backend::RA_HOST, path: Backend::RA_PATH)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl      = true
          http.read_timeout = 15
          req  = Net::HTTP::Post.new(uri.path)
          req.set_form_data(params.transform_keys(&:to_s).transform_values(&:to_s))
          resp = http.request(req)
          if resp.is_a?(Net::HTTPSuccess)
            [JSON.parse(resp.body), true]
          else
            [nil, false]
          end
        rescue => e
          $stderr.puts "RA request error (#{params[:r]}): #{e.class} #{e.message}"
          [nil, false]
        end
      end
    end
  end
end
