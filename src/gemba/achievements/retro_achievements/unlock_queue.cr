require "../../session_logger"
require "./backend"

module Gemba
  module Achievements
    module RetroAchievements
      # Submits unlocks to the site and keeps at every one it couldn't
      # confirm: a POST that fails (no network, a transient 5xx, a
      # refusal) is queued and re-sent on a backoff schedule until the
      # site accepts it or the attempt cap is reached. Ports the
      # unlock_queue half of ruby gemba's Backend, with two departures:
      # ruby re-POSTs every queued entry every 30s forever, this backs
      # off (30s, doubling, 5-minute ceiling) and gives up after
      # Schedule#max_attempts - roughly half an hour on the default
      # schedule; and the timing is a main-thread App#after timer rather
      # than a frame counter, since the frame loop lives on the worker
      # here.
      #
      # In-memory only, deliberately: an entry still pending when the
      # app exits is dropped with a warn line (#shutdown), not persisted.
      # That costs nothing but the line - the site treats re-awarding an
      # already-earned id as benign, and the next r=unlocks sync brings
      # local earned state back in step either way.
      #
      # Entries outlive the game they were earned in: nothing about a
      # retry depends on the ROM still being loaded, so swapping games
      # or switching achievements off mid-retry leaves the queue alone.
      # Credentials are read fresh for every attempt (the block passed
      # to .new), so a retry after a re-login goes out with the new
      # token.
      class UnlockQueue
        # initial_delay before the first retry, doubling per attempt up
        # to max_delay; max_attempts counts every POST including the
        # first, so it bounds how long a dead server is retried against.
        record Schedule, initial_delay : Time::Span, max_delay : Time::Span, max_attempts : Int32 do
          DEFAULT = new(30.seconds, 5.minutes, 10)

          # How long to wait before POST number `attempt` (2 or more).
          def delay_before(attempt : Int32) : Time::Span
            delay = initial_delay * (2 ** (attempt - 2))
            delay > max_delay ? max_delay : delay
          end
        end

        private class Entry
          getter id : UInt32
          getter? hardcore : Bool
          property attempts = 0
          property timer : Tryst::AfterHandle? = nil

          def initialize(@id : UInt32, @hardcore : Bool)
          end
        end

        getter schedule : Schedule

        def initialize(@app : Tryst::App, @backend : Backend, @schedule : Schedule = Schedule::DEFAULT,
                       &@credentials : -> {String, String})
          @entries = [] of Entry
        end

        # Ids submitted but not yet confirmed by the site, oldest first.
        def pending_ids : Array(UInt32)
          @entries.map(&.id)
        end

        # POSTs the unlock now; a failure queues it for retry.
        def submit(id : UInt32, hardcore : Bool = false) : Nil
          post(Entry.new(id, hardcore))
        end

        # Cancels every pending retry and reports what never made it -
        # for the app-exit path. Nothing is re-sent afterwards.
        def shutdown : Nil
          @entries.each { |entry| cancel_timer(entry) }
          unless @entries.empty?
            ids = @entries.map(&.id).join(", ")
            Gemba.log(SessionLogger::Level::Warn) do
              "RA: #{@entries.size} unlock(s) never confirmed - dropped on exit: #{ids}"
            end
          end
          @entries.clear
        end

        private def post(entry : Entry) : Nil
          entry.attempts += 1
          username, token = @credentials.call
          @backend.award_achievement(username, token, entry.id, hardcore: entry.hardcore?) do |accepted, error|
            accepted ? confirmed(entry) : failed(entry, error || "Request failed")
          end
        end

        private def confirmed(entry : Entry) : Nil
          if entry.attempts == 1
            Gemba.log { "RA: submitted unlock for achievement #{entry.id}" }
          else
            Gemba.log { "RA: retry succeeded for achievement #{entry.id} (attempt #{entry.attempts}/#{@schedule.max_attempts})" }
          end
          @entries.delete(entry)
        end

        private def failed(entry : Entry, error : String) : Nil
          if entry.attempts == 1
            @entries << entry
            Gemba.log { "RA: unlock submission failed for achievement #{entry.id}: #{error} - queued for retry" }
          else
            Gemba.log(SessionLogger::Level::Warn) do
              "RA: retry #{entry.attempts}/#{@schedule.max_attempts} failed for achievement #{entry.id}: #{error}"
            end
          end

          # An entry #shutdown already dropped gets no further attempts
          # even if its in-flight POST only failed afterwards.
          return unless @entries.includes?(entry)

          if entry.attempts >= @schedule.max_attempts
            @entries.delete(entry)
            Gemba.log(SessionLogger::Level::Error) do
              "RA: giving up on achievement #{entry.id} after #{entry.attempts} attempts - unlock never confirmed by the site"
            end
            return
          end

          delay = @schedule.delay_before(entry.attempts + 1)
          Gemba.log { "RA: next attempt for achievement #{entry.id} in #{delay.total_seconds.round(1)}s" }
          entry.timer = @app.after(delay.total_milliseconds.to_i) do
            entry.timer = nil
            post(entry)
          end
        end

        private def cancel_timer(entry : Entry) : Nil
          entry.timer.try { |timer| @app.after_cancel(timer) }
          entry.timer = nil
        end
      end
    end
  end
end
