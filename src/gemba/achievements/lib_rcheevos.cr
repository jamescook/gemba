# Raw rcheevos bindings - straight `lib` FFI, same convention as
# lib_mgba.cr. Unlike mGBA's mCore, rc_runtime_t is never accessed as a
# struct here: rc_runtime_alloc/rc_runtime_destroy own its allocation
# and lifetime entirely on the C side (confirmed in runtime.c -
# rc_runtime_alloc sets owns_self=1, rc_runtime_destroy frees when
# set), so Crystal only ever holds and passes around the opaque
# pointer it returns - no field layout to mirror or verify.
@[Link(ldflags: "#{__DIR__}/../../../vendor/rcheevos-build/librcheevos.a")]
lib LibRcheevos
  alias RcRuntimeT = Void

  alias PeekT = (UInt32, UInt32, Void* -> UInt32)

  struct RuntimeEvent
    id : UInt32
    value : Int32
    type : UInt8
  end

  alias EventHandlerT = (RuntimeEvent* -> Void)

  ACHIEVEMENT_TRIGGERED = 3_u8

  fun rc_runtime_alloc : RcRuntimeT*
  fun rc_runtime_destroy(runtime : RcRuntimeT*) : Void

  fun rc_runtime_activate_achievement(runtime : RcRuntimeT*, id : UInt32, memaddr : LibC::Char*,
                                       unused_l : Void*, unused_funcs_idx : Int32) : Int32
  fun rc_runtime_deactivate_achievement(runtime : RcRuntimeT*, id : UInt32) : Void

  fun rc_runtime_activate_richpresence(runtime : RcRuntimeT*, script : LibC::Char*,
                                        unused_l : Void*, unused_funcs_idx : Int32) : Int32
  fun rc_runtime_get_richpresence(runtime : RcRuntimeT*, buffer : LibC::Char*, buffersize : LibC::SizeT,
                                   peek : PeekT, peek_ud : Void*, unused_l : Void*) : Int32

  fun rc_runtime_do_frame(runtime : RcRuntimeT*, event_handler : EventHandlerT, peek : PeekT,
                           ud : Void*, unused_l : Void*) : Void
  fun rc_runtime_reset(runtime : RcRuntimeT*) : Void
end
