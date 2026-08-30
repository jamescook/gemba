require "tryst"
require "tryst/ui"
require "./rom_patcher"
require "./paths"
require "./locale"

module Gemba
  # Floating window for applying IPS/BPS/UPS patches to ROM files -
  # ruby gemba's PatcherWindow. Non-modal: patching while a game keeps
  # running is fine. Three pickers (ROM, patch, output dir), an Apply
  # button, a progress bar, and a status line; the patch itself runs on
  # a Tryst::BackgroundWork thread so the UI stays responsive, with
  # RomPatcher's progress budget driving the bar.
  #
  # Ruby's "progress may appear stuck on Ruby < 4" warning label has no
  # counterpart here - BackgroundWork is always a real OS thread.
  class PatcherWindow
    record PatchJob, rom : String, patch : String, out_path : String

    getter handle : Tryst::UI::Handle
    getter apply_button : Tryst::UI::Handle

    # Public so a spec drives the same fields a user types into.
    getter rom_var : Tryst::UI::Var
    getter patch_var : Tryst::UI::Var
    getter outdir_var : Tryst::UI::Var
    getter status_var : Tryst::UI::Var
    getter progress_var : Tryst::UI::Var

    # True from Apply until the background patch reports back.
    getter? busy : Bool = false

    # Seam for specs: the overwrite question is a WM-modal tk_messageBox
    # that can't be answered headless. Takes the colliding basename,
    # returns :yes (overwrite) / :no (pick a -(n) name) / anything else
    # (abort silently), like the real dialog's buttons.
    setter overwrite_prompt : (String -> Symbol)? = nil

    @task : Tryst::BackgroundWork(PatchJob, Float64)?

    def initialize(@app : Tryst::App, @handle : Tryst::UI::Handle, session : Tryst::UI::Session,
                   patches_dir : String = Paths.patches_dir)
      rom_var = nil
      patch_var = nil
      outdir_var = nil
      status_var = nil
      progress_var = nil
      apply_handle = nil

      session.add(@handle) do |build|
        build.component(:patcher) do |scope|
          scope.column(:body, pad: 12, gap: 4, align: :stretch, grow: true) do |column|
            rom_var = build_path_row(column, :rom, Locale.translate("patcher.rom_label")) do |var|
              browse_file(var, rom_filetypes)
            end
            patch_var = build_path_row(column, :patch, Locale.translate("patcher.patch_label")) do |var|
              browse_file(var, patch_filetypes)
            end
            outdir_var = build_path_row(column, :outdir, Locale.translate("patcher.outdir_label"),
              initial: patches_dir) do |var|
              browse_dir(var)
            end

            column.row(:actions, gap: 8) do |row|
              apply_handle = row.button(:apply, text: Locale.translate("patcher.apply"),
                command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { apply; nil })
              progress_var = row.var(0)
              row.progress(:pb, bind: progress_var.as(Tryst::UI::Var),
                mode: :determinate, maximum: 100, length: 200)
            end

            status_var = column.var("")
            column.label(:status, bind: status_var.as(Tryst::UI::Var), wraplength: 500, anchor: :w)
          end
        end
      end

      @rom_var = rom_var.as(Tryst::UI::Var)
      @patch_var = patch_var.as(Tryst::UI::Var)
      @outdir_var = outdir_var.as(Tryst::UI::Var)
      @status_var = status_var.as(Tryst::UI::Var)
      @progress_var = progress_var.as(Tryst::UI::Var)
      @apply_button = apply_handle.as(Tryst::UI::Handle)

      # Non-modal palette window: the close box hides it, keeping the
      # typed-in paths for the next View > Patch ROM.
      @handle.on_close { |_values, _signal| @handle.hide }
    end

    def show : Nil
      @handle.show
    end

    # The Apply button's action. Validates the three fields, resolves an
    # output-name collision (through the dialog, or a spec's injected
    # prompt), then hands off to the background worker. Public so a spec
    # can press Apply without synthesizing a Tk click.
    def apply : Nil
      return if @busy

      rom = @rom_var.value.to_s.strip
      patch = @patch_var.value.to_s.strip
      outdir = @outdir_var.value.to_s.strip

      if rom.empty? || patch.empty? || outdir.empty?
        set_status(Locale.translate("patcher.err_missing_fields"))
        return
      end
      unless File.exists?(rom)
        set_status(Locale.translate("patcher.err_rom_not_found"))
        return
      end
      unless File.exists?(patch)
        set_status(Locale.translate("patcher.err_patch_not_found"))
        return
      end

      rom_ext = File.extname(rom)
      desired_out = File.join(outdir, File.basename(rom, rom_ext) + "-patched" + rom_ext)
      out_path = resolve_collision(desired_out)
      return unless out_path # cancel - abort silently, like ruby

      start_patch(rom, patch, out_path)
    end

    # Stops any in-flight patch worker. The output file may be left
    # partially written - same as ruby's, where quitting mid-patch
    # abandons the thread.
    def destroy : Nil
      @task.try(&.close)
      @task = nil
    end

    private def build_path_row(column, name : Symbol, label_text : String, initial : String = "",
                               &browse : Tryst::UI::Var -> Nil) : Tryst::UI::Var
      var = column.var(initial)
      column.row(gap: 4) do |row|
        row.label(text: label_text, width: 10, anchor: :w)
        row.text_box(name, bind: var, width: 48, grow: true)
        row.button(text: Locale.translate("patcher.browse"),
          command: ->(_values : Array(String), _signal : Tryst::CallbackSignal) { browse.call(var); nil })
      end
      var
    end

    private def rom_filetypes : Tryst::FileTypes
      types : Tryst::FileTypes = [{"GBA ROMs", [".gba"]}, {"All Files", "*"}]
      types
    end

    private def patch_filetypes : Tryst::FileTypes
      types : Tryst::FileTypes = [{"Patch Files", [".ips", ".bps", ".ups"]}, {"All Files", "*"}]
      types
    end

    private def browse_file(var : Tryst::UI::Var, filetypes : Tryst::FileTypes) : Nil
      path = @app.choose_open_file(filetypes: filetypes)
      var.value = path if path.is_a?(String) && !path.strip.empty?
    end

    private def browse_dir(var : Tryst::UI::Var) : Nil
      current = var.value.to_s.strip
      dir = @app.choose_dir(initialdir: Dir.exists?(current) ? current : nil)
      var.value = dir if dir.is_a?(String) && !dir.strip.empty?
    end

    # nil means the user cancelled.
    private def resolve_collision(desired_out : String) : String?
      return desired_out unless File.exists?(desired_out)

      basename = File.basename(desired_out)
      answer = if prompt = @overwrite_prompt
                 prompt.call(basename)
               else
                 @app.message_box(Locale.translate("patcher.overwrite_msg").gsub("{path}", basename),
                   title: Locale.translate("patcher.overwrite_title"),
                   type: :yesnocancel, icon: :question, parent: @handle.path)
               end
      case answer
      when :yes then desired_out
      when :no  then RomPatcher.safe_out_path(desired_out)
      end
    end

    private def start_patch(rom : String, patch : String, out_path : String) : Nil
      set_status(Locale.translate("patcher.working"))
      @apply_button.disable
      @progress_var.value = 0
      @busy = true

      job = PatchJob.new(rom: rom, patch: patch, out_path: out_path)
      # The outcome rides the String message channel ("ok:"/"err:")
      # rather than a progress value, so Result stays a plain Float64
      # percentage - RomPatcher::Error and friends never cross the
      # thread boundary as exceptions.
      @task = Tryst::BackgroundWork(PatchJob, Float64).new(@app, job) do |task, data|
        # Whole-percent throttle: RomPatcher reports per chunk/record,
        # far faster than the UI polls; the bar only has 100 states
        # anyway.
        last_step = -1
        RomPatcher.patch(rom_path: data.rom, patch_path: data.patch, out_path: data.out_path,
          on_progress: ->(pct : Float64) {
            step = (pct * 100).to_i
            if step != last_step
              last_step = step
              task.yield(pct)
            end
          })
        task.send_message("ok:#{data.out_path}")
      rescue ex
        task.send_message("err:#{ex.message}")
      end
        .on_progress { |pct| @progress_var.value = (pct * 100).round.to_i }
        .on_message { |msg| finish(msg) }
        .on_done do
          @busy = false
          @apply_button.enable
        end
    end

    private def finish(message : String) : Nil
      kind, _, payload = message.partition(':')
      if kind == "ok"
        @progress_var.value = 100
        set_status("#{Locale.translate("patcher.done")} #{File.basename(payload)}")
      else
        @progress_var.value = 0
        set_status("#{Locale.translate("patcher.err_failed")} #{payload}")
      end
    end

    private def set_status(msg : String) : Nil
      @status_var.value = msg
    end
  end
end
