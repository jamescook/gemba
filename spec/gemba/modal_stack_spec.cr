require "../spec_helper"

private def window_state(app : Tryst::App, path : String) : String
  app.command(:wm, "state", path)
end

describe Gemba::ModalStack do
  it "push shows the window and fires on_enter once (empty -> non-empty)" do
    session = Tryst::UI::Session.new(title: "modal_stack_spec_1")
    settings = session.window(:settings, title: "Settings", modal: true)
    app = session.run_async.app

    entered = [] of Symbol
    exited = 0
    stack = Gemba::ModalStack.new(
      on_enter: ->(name : Symbol) { entered << name; nil },
      on_exit: -> { exited += 1; nil },
    )

    stack.push(:settings, settings)
    stack.active?.should be_true
    stack.current.should eq :settings
    entered.should eq [:settings]
    exited.should eq 0
    window_state(app, settings.path).should eq "normal"

    app.destroy
  end

  it "pushing a second modal hides the first without firing on_enter again" do
    session = Tryst::UI::Session.new(title: "modal_stack_spec_2")
    settings = session.window(:settings, title: "Settings", modal: true)
    rom_info = session.window(:rom_info, title: "ROM Info", modal: true)
    app = session.run_async.app

    entered = [] of Symbol
    stack = Gemba::ModalStack.new(on_enter: ->(name : Symbol) { entered << name; nil }, on_exit: -> { })

    stack.push(:settings, settings)
    stack.push(:rom_info, rom_info)

    stack.current.should eq :rom_info
    entered.should eq [:settings]
    window_state(app, settings.path).should eq "withdrawn"
    window_state(app, rom_info.path).should eq "normal"

    app.destroy
  end

  it "pop re-shows the previous modal, then fires on_exit once the stack empties" do
    session = Tryst::UI::Session.new(title: "modal_stack_spec_3")
    settings = session.window(:settings, title: "Settings", modal: true)
    rom_info = session.window(:rom_info, title: "ROM Info", modal: true)
    app = session.run_async.app

    exited = 0
    stack = Gemba::ModalStack.new(on_enter: ->(_name : Symbol) { }, on_exit: -> { exited += 1; nil })
    stack.push(:settings, settings)
    stack.push(:rom_info, rom_info)

    stack.pop
    stack.current.should eq :settings
    window_state(app, settings.path).should eq "normal"
    exited.should eq 0

    stack.pop
    stack.active?.should be_false
    exited.should eq 1

    app.destroy
  end

  it "closing the window via the OS close button pops the stack instead of destroying it (auto_close, the default)" do
    session = Tryst::UI::Session.new(title: "modal_stack_spec_4")
    settings = session.window(:settings, title: "Settings", modal: true)
    app = session.run_async.app

    exited = 0
    stack = Gemba::ModalStack.new(on_enter: ->(_name : Symbol) { }, on_exit: -> { exited += 1; nil })
    stack.push(:settings, settings)

    # Simulates the window manager sending WM_DELETE_WINDOW - re-invokes
    # whatever script #push registered for it.
    close_script = app.tcl_invoke("wm", "protocol", settings.path, "WM_DELETE_WINDOW")
    app.tcl_eval(close_script)

    stack.active?.should be_false
    exited.should eq 1
    window_state(app, settings.path).should eq "withdrawn"
    app.winfo.exists?(settings.path).should be_true # hidden, not destroyed

    stack.push(:settings, settings)
    stack.active?.should be_true
    window_state(app, settings.path).should eq "normal"

    app.destroy
  end

  it "auto_close: false leaves the close button unwired, for full manual control" do
    session = Tryst::UI::Session.new(title: "modal_stack_spec_5")
    settings = session.window(:settings, title: "Settings", modal: true)
    app = session.run_async.app

    stack = Gemba::ModalStack.new(on_enter: ->(_name : Symbol) { }, on_exit: -> { })
    stack.push(:settings, settings, auto_close: false)

    app.tcl_invoke("wm", "protocol", settings.path, "WM_DELETE_WINDOW").should eq ""
    stack.active?.should be_true

    app.destroy
  end
end
