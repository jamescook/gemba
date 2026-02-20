# frozen_string_literal: true

module Gemba
  # Include in any class that emits events via Gemba.bus.
  # No constructor changes needed — just include and call emit.
  module BusEmitter
    private

    def emit(event, *args, **kwargs)
      Gemba.bus.emit(event, *args, **kwargs)
    end
  end
end
