require "./lib_rcheevos"

module Gemba
  module Achievements
    # Thin wrapper around rcheevos' rc_runtime_t - the RetroAchievements
    # condition evaluator. Deliberately decoupled from Core/mGBA: #do_frame
    # and #get_richpresence take a peek block (address, num_bytes -> value)
    # rather than a Core, so this class is fully testable without an
    # emulator running. Wiring a real peek callback into Core's bus reads
    # is separate, later scope.
    class RARuntime
      RC_OK = 0

      # rc_runtime_event_handler_t has no userdata parameter, so
      # #do_frame stashes triggered ids in this class var while its C
      # call is in flight and reads it back once rc_runtime_do_frame
      # returns - safe because that call is synchronous and Tk's world
      # is single-threaded, same reasoning as ruby's own GVL-based
      # s_ra_frame_ctx.
      @@triggered_ids = [] of UInt32

      EVENT_HANDLER = LibRcheevos::EventHandlerT.new do |event|
        if event.value.type == LibRcheevos::ACHIEVEMENT_TRIGGERED
          @@triggered_ids << event.value.id
        end
      end

      PEEK_TRAMPOLINE = LibRcheevos::PeekT.new do |address, num_bytes, boxed_peek|
        Box(Proc(UInt32, UInt32, UInt32)).unbox(boxed_peek).call(address, num_bytes)
      end

      def initialize
        @ptr = LibRcheevos.rc_runtime_alloc
        raise "rcheevos: rc_runtime_alloc returned null" if @ptr.null?
        @count = 0
      end

      def finalize
        LibRcheevos.rc_runtime_destroy(@ptr) unless @ptr.null?
      end

      # Raises ArgumentError if rcheevos rejects the condition string.
      def activate(id : UInt32, memaddr : String) : Nil
        result = LibRcheevos.rc_runtime_activate_achievement(@ptr, id, memaddr, nil, 0)
        raise ArgumentError.new("RARuntime: rcheevos rejected memaddr (err #{result}): #{memaddr}") unless result == RC_OK
        @count += 1
      end

      def deactivate(id : UInt32) : Nil
        LibRcheevos.rc_runtime_deactivate_achievement(@ptr, id)
        @count -= 1 if @count > 0
      end

      # Resets every achievement to WAITING state - call after loading a
      # save state so delta/prior histories are discarded.
      def reset_all : Nil
        LibRcheevos.rc_runtime_reset(@ptr)
      end

      def clear : Nil
        LibRcheevos.rc_runtime_destroy(@ptr)
        @ptr = LibRcheevos.rc_runtime_alloc
        raise "rcheevos: rc_runtime_alloc returned null" if @ptr.null?
        @count = 0
      end

      def count : Int32
        @count
      end

      # Loads a Rich Presence script. Returns true on success, false if
      # the script failed to parse.
      def activate_richpresence(script : String) : Bool
        LibRcheevos.rc_runtime_activate_richpresence(@ptr, script, nil, 0) == RC_OK
      end

      # Returns the active Rich Presence display string, or nil if none
      # is loaded. Macro values reflect memory as of the last #do_frame
      # call, not this call's peek block, unless a display line has its
      # own hit-count condition.
      def get_richpresence(&peek : UInt32, UInt32 -> UInt32) : String?
        boxed = Box.box(peek)
        buffer = Bytes.new(512)
        len = LibRcheevos.rc_runtime_get_richpresence(@ptr, buffer, buffer.size, PEEK_TRAMPOLINE, boxed, nil)
        return if len <= 0
        String.new(buffer[0, len])
      end

      # Evaluates every active achievement against current memory (via
      # the peek block) and returns the ids that triggered this frame.
      def do_frame(&peek : UInt32, UInt32 -> UInt32) : Array(UInt32)
        boxed = Box.box(peek)
        @@triggered_ids.clear
        LibRcheevos.rc_runtime_do_frame(@ptr, EVENT_HANDLER, PEEK_TRAMPOLINE, boxed, nil)
        @@triggered_ids.dup
      end
    end
  end
end
