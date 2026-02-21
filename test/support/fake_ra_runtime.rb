# frozen_string_literal: true

# Test double for Gemba::RARuntime (the C extension).
#
# Mirrors the full RARuntime interface so RetroAchievements::Backend can be
# tested without a real rcheevos instance or ROM memory.
#
# Usage:
#   rt = FakeRARuntime.new
#   rt.queue_triggers("101", "102")   # do_frame will return these once
#   rt.rp_message = "Playing Stage 1" # get_richpresence returns this
#   rt.rp_activate_result = false     # activate_richpresence returns false
class FakeRARuntime
  attr_reader   :activated, :deactivated, :cleared, :reset_count
  attr_reader   :rp_script
  attr_accessor :rp_message, :rp_activate_result

  def initialize
    @activated          = {}   # id => memaddr
    @deactivated        = []
    @trigger_queue      = []   # Array<Array<String>> — one entry consumed per do_frame
    @cleared            = false
    @reset_count        = 0
    @rp_script          = nil
    @rp_message         = nil
    @rp_activate_result = true
  end

  # Queue one frame's worth of triggered achievement IDs.
  # Each call adds one "frame": the next do_frame call pops and returns it.
  def queue_triggers(*ids)
    @trigger_queue << ids.flatten.map(&:to_s)
  end

  # -- RARuntime interface ----------------------------------------------------

  def activate(id, memaddr)
    @activated[id.to_s] = memaddr.to_s
  end

  def deactivate(id)
    @deactivated << id.to_s
    @activated.delete(id.to_s)
  end

  def reset_all
    @reset_count += 1
  end

  def clear
    @activated.clear
    @deactivated.clear
    @trigger_queue.clear
    @cleared = true
  end

  # Returns the next queued batch of triggered IDs, or [] if nothing queued.
  def do_frame(_core)
    @trigger_queue.shift || []
  end

  def count
    @activated.size
  end

  def activate_richpresence(script)
    @rp_script = script
    @rp_activate_result
  end

  def get_richpresence(_core)
    @rp_message
  end
end
