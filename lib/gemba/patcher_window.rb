# frozen_string_literal: true

module Gemba
  # Floating window for applying IPS/BPS/UPS patches to ROM files.
  #
  # Non-modal — no grab. Shows three file pickers (ROM, patch, output dir)
  # and runs the patch in a background thread so the UI stays responsive.
  class PatcherWindow
    include ChildWindow
    include Locale::Translatable

    # Worker class for Ractor-based patching.
    # Defined as a class so Ractor.shareable_proc never sees nested closures —
    # the lambda and rescue are created at runtime inside the Ractor.
    class PatchWorker
      def call(t, d)
        RomPatcher.patch(
          rom_path:    d[:rom],
          patch_path:  d[:patch],
          out_path:    d[:out],
          on_progress: ->(pct) { t.yield(pct) }
        )
        t.yield({ ok: true, path: d[:out] })
      rescue => e
        t.yield({ ok: false, error: e.message })
      end
    end

    TOP          = '.patcher_window'
    BG_MODE      = (RUBY_VERSION >= '4.0' ? :ractor : :thread).freeze

    VAR_ROM    = '::gemba_patcher_rom'
    VAR_PATCH  = '::gemba_patcher_patch'
    VAR_OUTDIR = '::gemba_patcher_outdir'
    VAR_STATUS = '::gemba_patcher_status'

    def initialize(app:)
      @app = app
      @callbacks = {}
      build_toplevel(translate('patcher.title'), geometry: '540x220') { build_ui }
    end

    def show    = show_window(modal: false)
    def hide    = hide_window(modal: false)
    def visible? = @app.tcl_eval("wm state #{TOP}") == 'normal'

    private

    def build_ui
      f = "#{TOP}.f"
      @app.command('ttk::frame', f, padding: 12)
      @app.command(:pack, f, fill: :both, expand: 1)

      @app.set_variable(VAR_ROM,    '')
      @app.set_variable(VAR_PATCH,  '')
      @app.set_variable(VAR_OUTDIR, Config.default_patches_dir)
      @app.set_variable(VAR_STATUS, '')

      build_file_row(f, 'rom',   translate('patcher.rom_label'),
                     "{{GBA ROMs} {.gba .zip}} {{All Files} *}")
      build_file_row(f, 'patch', translate('patcher.patch_label'),
                     "{{Patch Files} {.ips .bps .ups}} {{All Files} *}")
      build_dir_row(f,  'outdir', translate('patcher.outdir_label'), VAR_OUTDIR)

      btn_row = "#{f}.btn_row"
      @app.command('ttk::frame', btn_row)
      @app.command(:pack, btn_row, fill: :x, pady: [10, 0])

      @apply_btn = "#{btn_row}.apply"
      @app.command('ttk::button', @apply_btn,
                   text: translate('patcher.apply'),
                   command: proc { apply_patch })
      @app.command(:pack, @apply_btn, side: :left)

      @progress_bar = "#{btn_row}.pb"
      @app.command('ttk::progressbar', @progress_bar,
                   orient: :horizontal, length: 200,
                   mode: :determinate, maximum: 100)
      @app.command(:pack, @progress_bar, side: :left, padx: [8, 0])

      if BG_MODE == :thread
        @app.command('ttk::label', "#{btn_row}.ruby_warn",
                     text: translate('patcher.thread_mode_warn'),
                     foreground: 'gray')
        @app.command(:pack, "#{btn_row}.ruby_warn", side: :left, padx: [10, 0])
      end

      @app.command('ttk::label', "#{f}.status",
                   textvariable: VAR_STATUS,
                   wraplength: 500)
      @app.command(:pack, "#{f}.status", fill: :x, pady: [6, 0])
    end

    def build_file_row(parent, name, label_text, filetypes_tcl)
      row = "#{parent}.#{name}_row"
      var = case name
            when 'rom'   then VAR_ROM
            when 'patch' then VAR_PATCH
            end

      @app.command('ttk::frame', row)
      @app.command(:pack, row, fill: :x, pady: 2)

      @app.command('ttk::label', "#{row}.lbl", text: label_text, width: 10, anchor: :w)
      @app.command(:grid, "#{row}.lbl", row: 0, column: 0, sticky: :w)

      @app.command('ttk::entry', "#{row}.ent", textvariable: var, width: 48)
      @app.command(:grid, "#{row}.ent", row: 0, column: 1, sticky: :ew, padx: [4, 4])

      @app.command('ttk::button', "#{row}.btn",
                   text: translate('patcher.browse'),
                   command: proc { browse_file(var, filetypes_tcl) })
      @app.command(:grid, "#{row}.btn", row: 0, column: 2)
      @app.command(:grid, :columnconfigure, row, 1, weight: 1)
    end

    def build_dir_row(parent, name, label_text, var)
      row = "#{parent}.#{name}_row"
      @app.command('ttk::frame', row)
      @app.command(:pack, row, fill: :x, pady: 2)

      @app.command('ttk::label', "#{row}.lbl", text: label_text, width: 10, anchor: :w)
      @app.command(:grid, "#{row}.lbl", row: 0, column: 0, sticky: :w)

      @app.command('ttk::entry', "#{row}.ent", textvariable: var, width: 48)
      @app.command(:grid, "#{row}.ent", row: 0, column: 1, sticky: :ew, padx: [4, 4])

      @app.command('ttk::button', "#{row}.btn",
                   text: translate('patcher.browse'),
                   command: proc { browse_dir(var) })
      @app.command(:grid, "#{row}.btn", row: 0, column: 2)
      @app.command(:grid, :columnconfigure, row, 1, weight: 1)
    end

    def browse_file(var, filetypes_tcl)
      path = @app.tcl_eval("tk_getOpenFile -filetypes {#{filetypes_tcl}}")
      @app.set_variable(var, path) unless path.to_s.strip.empty?
    end

    def browse_dir(var)
      dir = @app.tcl_eval("tk_chooseDirectory")
      @app.set_variable(var, dir) unless dir.to_s.strip.empty?
    end

    def apply_patch
      rom    = @app.get_variable(VAR_ROM).strip
      patch  = @app.get_variable(VAR_PATCH).strip
      outdir = @app.get_variable(VAR_OUTDIR).strip

      if rom.empty? || patch.empty? || outdir.empty?
        set_status(translate('patcher.err_missing_fields'))
        return
      end

      unless File.exist?(rom)
        set_status(translate('patcher.err_rom_not_found'))
        return
      end

      unless File.exist?(patch)
        set_status(translate('patcher.err_patch_not_found'))
        return
      end

      resolved_rom = begin
                       RomResolver.resolve(rom)
                     rescue => e
                       set_status("#{translate('patcher.err_failed')} #{e.message}")
                       return
                     end

      rom_ext     = File.extname(resolved_rom)
      basename    = File.basename(rom, '.*') + '-patched' + rom_ext
      desired_out = File.join(outdir, basename)

      out_path = if File.exist?(desired_out)
                   msg = translate('patcher.overwrite_msg').gsub('{path}', File.basename(desired_out))
                   answer = @app.command('tk_messageBox',
                                        parent: TOP,
                                        title: translate('patcher.overwrite_title'),
                                        message: msg,
                                        type: :yesnocancel,
                                        icon: :question)
                   case answer
                   when 'yes'    then desired_out
                   when 'no'     then RomPatcher.safe_out_path(desired_out)
                   else return   # cancel — abort silently
                   end
                 else
                   desired_out
                 end

      set_status(translate('patcher.working'))
      @app.command(@apply_btn, :configure, state: :disabled)
      @app.command(@progress_bar, :configure, value: 0)

      data = Ractor.make_shareable({ rom: resolved_rom.freeze, patch: patch.freeze, out: out_path.freeze })
      Teek::BackgroundWork.drop_intermediate = false
      Teek::BackgroundWork.new(@app, data, mode: BG_MODE, worker: PatchWorker).on_progress do |result|
        case result
        when Float
          @app.command(@progress_bar, :configure, value: (result * 100).round)
          @app.update
        when Hash
          @app.command(@apply_btn, :configure, state: :normal)
          @app.command(@progress_bar, :configure, value: result[:ok] ? 100 : 0)
          @app.update
          if result[:ok]
            set_status("#{translate('patcher.done')} #{File.basename(result[:path])}")
          else
            set_status("#{translate('patcher.err_failed')} #{result[:error]}")
          end
        end
      end.on_done do
        @app.command(@apply_btn, :configure, state: :normal)
      end
    end

    def set_status(msg)
      @app.set_variable(VAR_STATUS, msg)
    end
  end
end
