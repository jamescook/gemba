# frozen_string_literal: true

require_relative "logging"

module Gemba
  # Publish/subscribe event bus for decoupled communication.
  #
  # Replaces callback-hash threading where intermediary classes (e.g.
  # SettingsWindow) pass callbacks through without inspecting them.
  # Emitters fire named events, subscribers listen — no intermediaries.
  #
  # Lives at Gemba.bus (module-level). Player creates it at startup;
  # any class does Gemba.bus.emit / Gemba.bus.on. For tests, replace
  # with Gemba.bus = EventBus.new (or a mock).
  #
  # @example
  #   Gemba.bus.on(:scale_changed) { |val| apply_scale(val) }
  #   Gemba.bus.emit(:scale_changed, 3)
  class EventBus
    def initialize
      @listeners = Hash.new { |h, k| h[k] = [] }
    end

    # Subscribe to a named event.
    # @param event [Symbol]
    # @return [Proc] the block (for later #off)
    def on(event, &block)
      @listeners[event] << block
      block
    end

    # Emit a named event to all subscribers.
    # @param event [Symbol]
    def emit(event, *args, **kwargs)
      Gemba.log(:debug) { "bus: #{event}(#{[*args, *kwargs.map { |k,v| "#{k}: #{v}" }].join(', ')})" }
      if kwargs.empty?
        @listeners[event].each { |cb| cb.call(*args) }
      else
        @listeners[event].each { |cb| cb.call(*args, **kwargs) }
      end
    end

    # Unsubscribe a specific block.
    # @param event [Symbol]
    # @param block [Proc] the block returned by #on
    def off(event, block)
      @listeners[event].delete(block)
    end
  end

  # Module-level bus accessor. Auto-creates a default bus on first access
  # so tests and standalone classes don't need explicit setup.
  # Player replaces it with a fresh bus at startup.
  class << self
    def bus
      @bus ||= EventBus.new
    end

    attr_writer :bus
  end

  # Include in any class that emits events via Gemba.bus.
  # No constructor changes needed — just include and call emit.
  module BusEmitter
    private

    def emit(event, *args, **kwargs)
      Gemba.bus.emit(event, *args, **kwargs)
    end
  end
end
