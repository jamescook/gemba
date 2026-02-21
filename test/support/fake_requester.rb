# frozen_string_literal: true

# Synchronous test double for the RetroAchievements HTTP transport.
#
# Designed to match Teek::BackgroundWork's fluent interface so it can be
# injected without any branching in ra_request — the same code path runs
# in production and tests.
#
# Usage:
#   req = FakeRequester.new
#   req.stub(r: "login2", body: { "Success" => true, "Token" => "tok" })
#   req.stub(r: "gameid", body: { "GameID" => 42 })
#
#   backend = Backend.new(app: nil, runtime: FakeRARuntime.new, requester: req)
#   backend.login_with_token(username: "u", token: "t")
#   assert backend.authenticated?
#   assert req.requested?("login2")
class FakeRequester
  # Returned by call() — mirrors BackgroundWork's fluent on_progress/on_done chain.
  # on_progress fires synchronously with the canned result so callers behave
  # identically to the async production path without needing an event loop.
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

  attr_reader :requests

  def initialize
    @stubs    = {}   # r_string => Array<[json_or_nil, ok_bool]>
    @requests = []   # all params hashes, in call order
  end

  # Register a canned response for a given r= value.
  # Overwrites any previous stub — the response is reused for every call
  # until replaced. Use stub_queue for ordered sequential responses.
  def stub(r:, body: nil, ok: true)
    @stubs[r.to_s] = [[body, ok]]
  end

  # Enqueue an additional response for a given r= value.
  # Each queued entry is consumed once; the last entry is reused once exhausted.
  def stub_queue(r:, body: nil, ok: true)
    (@stubs[r.to_s] ||= []) << [body, ok]
  end

  # Called by ra_request with the same signature as Teek::BackgroundWork.new.
  # Ignores the block (which contains real Net::HTTP code) and returns a
  # Result that fires on_progress synchronously with the canned response.
  def call(_app, params, mode: nil, worker: nil, **_opts, &_block)
    @requests << params.dup
    r      = (params[:r] || params["r"]).to_s
    queue  = @stubs.fetch(r, [[nil, false]])
    result = queue.size > 1 ? queue.shift : queue.first
    result = [result[1] ? true : false, params[:a].to_s] if worker
    Result.new(result)
  end

  # True if at least one request with the given r= value was made.
  def requested?(r)
    @requests.any? { |p| (p[:r] || p["r"]).to_s == r.to_s }
  end

  # All params hashes for requests with the given r= value.
  def requests_for(r)
    @requests.select { |p| (p[:r] || p["r"]).to_s == r.to_s }
  end
end
