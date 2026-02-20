# frozen_string_literal: true

require "minitest/autorun"
require "gemba/headless"

class TestEventBus < Minitest::Test
  def setup
    @bus = Gemba::EventBus.new
  end

  def test_on_and_emit
    received = nil
    @bus.on(:ping) { |val| received = val }
    @bus.emit(:ping, 42)
    assert_equal 42, received
  end

  def test_emit_with_no_subscribers_is_noop
    @bus.emit(:ghost, 1, 2, 3) # should not raise
  end

  def test_multiple_subscribers
    results = []
    @bus.on(:tick) { |v| results << "a:#{v}" }
    @bus.on(:tick) { |v| results << "b:#{v}" }
    @bus.emit(:tick, 7)
    assert_equal ["a:7", "b:7"], results
  end

  def test_different_events_are_independent
    a = nil
    b = nil
    @bus.on(:foo) { |v| a = v }
    @bus.on(:bar) { |v| b = v }
    @bus.emit(:foo, 1)
    assert_equal 1, a
    assert_nil b
  end

  def test_emit_multiple_args
    received = nil
    @bus.on(:multi) { |x, y| received = [x, y] }
    @bus.emit(:multi, :a, :b)
    assert_equal [:a, :b], received
  end

  def test_emit_with_kwargs
    received = nil
    @bus.on(:kw) { |name:, val:| received = { name: name, val: val } }
    @bus.emit(:kw, name: "scale", val: 3)
    assert_equal({ name: "scale", val: 3 }, received)
  end

  def test_off_removes_subscriber
    received = []
    block = @bus.on(:evt) { |v| received << v }
    @bus.emit(:evt, 1)
    @bus.off(:evt, block)
    @bus.emit(:evt, 2)
    assert_equal [1], received
  end

  def test_on_returns_block_for_later_off
    block = @bus.on(:x) { }
    assert_instance_of Proc, block
  end

  # -- Module-level accessor ------------------------------------------------

  def test_gemba_bus_auto_creates
    Gemba.bus = nil
    bus = Gemba.bus
    assert_instance_of Gemba::EventBus, bus
  ensure
    Gemba.bus = nil
  end

  def test_gemba_bus_setter
    custom = Gemba::EventBus.new
    Gemba.bus = custom
    assert_same custom, Gemba.bus
  ensure
    Gemba.bus = nil
  end

  # -- BusEmitter mixin -----------------------------------------------------

  def test_bus_emitter_emits_to_gemba_bus
    Gemba.bus = @bus
    klass = Class.new { include Gemba::BusEmitter; public :emit }
    obj = klass.new

    received = nil
    @bus.on(:test_event) { |v| received = v }
    obj.emit(:test_event, 99)
    assert_equal 99, received
  ensure
    Gemba.bus = nil
  end
end
