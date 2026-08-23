require "tryst/ui"
require "./rom_info_data"
require "./locale"

module Gemba
  # Displays ROM metadata in a read-only modal window - built on the
  # Tryst::UI DSL's own ui.window/grid/Var support rather than ruby's
  # raw wm/grid Tcl calls (see ChildWindow in ruby gemba): a Var-bound
  # label per field, populated by setting the Var's value, no manual
  # widget bookkeeping needed to keep them in sync.
  #
  # Takes a RomInfoData snapshot, never a Core directly - Core is
  # thread-confined to EmulationWorker's own thread (see its class
  # comment), so nothing here may call a Core method itself.
  class RomInfoWindow
    # Calls Locale.translate directly rather than mixing in
    # Locale::Translatable's instance-level #translate: the DSL block
    # passed to session.window below runs synchronously while @handle
    # itself is still being computed - not yet assigned - and Crystal
    # bans any instance-method call on self until every ivar has been
    # assigned (see MainWindow's own comment on this same constraint).
    # A direct call to the Locale module's own class method carries no
    # such restriction.

    # GBA maker/publisher codes (2-char ASCII -> publisher name), copied
    # verbatim from ruby gemba's own rom_info_window.rb.
    MAKER_CODES = {
      "01" => "Nintendo", "08" => "Capcom", "13" => "Electronic Arts Japan",
      "18" => "Hudson Soft", "20" => "Destination Software / Zoo Digital",
      "24" => "PCM Complete", "25" => "San-X", "28" => "Kemco Japan",
      "29" => "SETA Corporation", "2N" => "Nowpro", "30" => "Viacom / Infogrames",
      "34" => "Konami", "35" => "Hector", "36" => "Codemasters",
      "37" => "GAGA Communications", "38" => "Laguna", "41" => "Ubisoft",
      "42" => "Sunsoft", "47" => "Spectrum Holobyte", "49" => "IREM",
      "4D" => "Malibu Games", "4F" => "Eidos / U.S. Gold", "4Q" => "Disney",
      "4Z" => "Crave Entertainment", "50" => "Absolute Entertainment",
      "51" => "Acclaim", "52" => "Activision", "54" => "GameTek", "56" => "LJN",
      "58" => "Mattel", "5D" => "Midway / Tradewest", "5G" => "Majesco",
      "5H" => "3DO", "5L" => "NewKidCo", "5S" => "TDK Mediactive", "60" => "Titus",
      "61" => "Virgin", "64" => "LucasArts", "67" => "Ocean", "69" => "Electronic Arts",
      "6E" => "Elite Systems", "6F" => "Electro Brain", "6L" => "BAM! Entertainment",
      "6S" => "TDK Mediactive", "70" => "Infogrames", "71" => "Interplay",
      "72" => "JVC / Broderbund", "73" => "Sculptured Software",
      "75" => "The Sales Curve / SCi", "78" => "THQ", "79" => "Accolade",
      "7A" => "Triffix", "7D" => "Sierra / Universal Interactive", "7F" => "Kemco",
      "7G" => "Rage Software", "7H" => "Encore", "7L" => "Warped Productions",
      "80" => "Misawa", "83" => "LOZC / G.Amusements", "86" => "Tokuma Shoten",
      "87" => "Tsukuda Original", "8B" => "Bullet-Proof Software", "8C" => "Vic Tokai",
      "8E" => "Character Soft", "8J" => "General Entertainment", "8N" => "Success",
      "91" => "Chunsoft", "92" => "Video System", "93" => "BEC / Ocean / Acclaim",
      "95" => "Varie", "97" => "Kaneko", "99" => "Pack-In-Video", "9B" => "Tecmo",
      "9C" => "Imagineer", "9H" => "Bottom Up", "A0" => "Telenet", "A1" => "Hori",
      "A4" => "Konami", "A7" => "Takara", "A9" => "Technos Japan",
      "AA" => "JVC / Broderbund", "AC" => "Toei Animation", "AD" => "Toho",
      "AF" => "Namco", "AG" => "Media Rings", "AH" => "J-Wing", "AK" => "KID",
      "AL" => "MediaFactory", "AP" => "Infogrames Hudson", "AQ" => "Kiratto Ludic",
      "AY" => "Yacht Club Games", "B0" => "Acclaim Japan / Nexsoft",
      "B1" => "ASCII / Nexsoft", "B2" => "Bandai", "B4" => "Enix",
      "B6" => "HAL Laboratory", "B7" => "SNK", "B9" => "Pony Canyon",
      "BA" => "Culture Brain", "BB" => "Sunsoft", "BD" => "Sony Imagesoft",
      "BF" => "Sammy", "BG" => "Magical", "BJ" => "Compile", "BL" => "MTO",
      "BN" => "Sunrise Interactive", "BP" => "Global A Entertainment",
      "C0" => "Taito", "C2" => "Kemco", "C3" => "Square Soft", "C4" => "Tokuma Shoten",
      "C5" => "Data East", "C6" => "Tonkin House", "C8" => "Koei", "CB" => "Vap",
      "CC" => "Use Corporation", "CD" => "Meldac", "CE" => "Pony Canyon / FCI",
      "CF" => "Angel / Dtop", "CG" => "Marvelous Entertainment",
      "CJ" => "Boss Communication", "CK" => "Axela / Crea-Tech", "CP" => "Enterbrain",
      "D0" => "Taito", "D1" => "Sofel", "D2" => "Quest", "D3" => "Sigma Enterprises",
      "D4" => "Ask Kodansha", "D6" => "Naxat Soft", "D7" => "Copya System",
      "D9" => "Banpresto", "DA" => "Tomy", "DB" => "LJN Japan", "DD" => "NCS",
      "DE" => "Human", "DF" => "Altron", "DH" => "Gaps", "DK" => "Kodansha",
      "DN" => "ELF", "E2" => "Yutaka", "E3" => "Varie", "E5" => "Epoch",
      "E7" => "Athena", "E8" => "Asmik / Asmik Ace", "E9" => "Natsume",
      "EB" => "Atlus", "EC" => "Epic / Sony Records", "EE" => "IGS", "EL" => "Spike",
      "EM" => "Konami Computer Entertainment Tokyo", "EP" => "Sting",
      "ES" => "Square Enix", "F0" => "A-Wave", "G1" => "PCCW", "G4" => "KiKi",
      "G5" => "Open Sesame", "G6" => "Sims", "G7" => "Broccoli", "G8" => "Avex",
      "G9" => "D3 Publisher", "GB" => "Konami Computer Entertainment Japan",
      "GD" => "Square Enix", "GE" => "KSG", "GF" => "Micott & Basara",
      "GH" => "Orbital Media", "GN" => "Nintendo", "GT" => "505 Games",
      "GY" => "The Game Factory", "H1" => "Treasure", "H2" => "Aruze",
      "H3" => "Ertain", "H4" => "SNK Playmore", "HF" => "Level-5",
      "HJ" => "Genius Sonority", "HY" => "Reef Entertainment", "IH" => "Yojigen",
      "J9" => "AQ Interactive", "JF" => "Arc System Works", "K6" => "Nihon System",
      "KB" => "NexEntertainment", "KM" => "Cybird", "KP" => "Purple Hills",
      "LH" => "Sekai Project", "LP" => "Witchcraft", "LT" => "Inti Creates",
      "LU" => "XSEED Games", "MJ" => "MumboJumbo", "MR" => "Mindscape",
      "MS" => "Mindscape / Red Orb", "MT" => "Blast!", "N9" => "Teyon",
      "NK" => "Neko Entertainment", "NP" => "Nobilis", "PL" => "Playlogic",
      "RA" => "Nordcurrent", "RS" => "Warner Bros. Interactive", "SU" => "Slitherine",
      "SV" => "SevenOne Intermedia / dtp", "TR" => "Tetris Online",
      "UG" => "Metro3D / Data Design", "VN" => "GameFly", "VP" => "Virgin Play",
      "VZ" => "Little Orbit", "WR" => "Warner Bros. Interactive",
      "XJ" => "XSEED Games", "XS" => "Aksys Games", "YT" => "Valcon Games",
      "Z4" => "Ntreev Soft", "ZA" => "WBA Interactive", "ZH" => "Internal Engine",
      "ZS" => "Zinkia", "ZW" => "Judo Baby", "ZX" => "TopWare Interactive",
    }

    def self.publisher_name(code : String) : String
      MAKER_CODES[code]? || "Unknown (#{code})"
    end

    # {field key, locale key} pairs, in display order.
    ROWS = {
      {"title", "rom_info.field_title"}, {"game_code", "rom_info.game_code"},
      {"publisher", "rom_info.publisher"}, {"platform", "rom_info.platform"},
      {"rom_size", "rom_info.rom_size"}, {"checksum", "rom_info.checksum"},
      {"rom_path", "rom_info.rom_file"}, {"save_path", "rom_info.save_file"},
      {"resolution", "rom_info.resolution"},
    }

    # ROM header offset of the 2-char ASCII maker code (bus address
    # 0x080000B0/B1) - the same field ruby's own core.maker_code binding
    # reads, just via bus_read8 rather than a dedicated Core method,
    # since only this one caller needs it.
    MAKER_CODE_OFFSET = 0x080000B0_u32

    @handle : Tryst::UI::Handle
    @on_close : (-> Nil)? = nil

    # For a spec to invoke a real click (`app.tcl_invoke(close_button.path, "invoke")`)
    # rather than only calling #on_close's callback directly.
    getter close_button : Tryst::UI::Handle

    def initialize(session : Tryst::UI::Session)
      @fields = {} of String => Tryst::UI::Var
      close_button = nil

      # The close button's own handler is wired AFTER this whole
      # assignment (seen below), not inline here: Crystal's ivar-initialization
      # check flags ANY reference to @handle textually inside the very
      # expression that computes its own value - even inside a closure
      # that only runs later - so referencing @handle in here (to hide
      # the window on click) would fail to compile. Capturing the
      # button's own Handle in a local and wiring #on_action once
      # @handle is a real, already-assigned ivar sidesteps it.
      @handle = session.window(:gemba_rom_info, title: Locale.translate("rom_info.title"),
        resizable: false, modal: true) do |window_dsl|
        window_dsl.grid(gap: 6) do |grid|
          ROWS.each_with_index do |(key, locale_key), i|
            grid.cell(row: i, col: 0, sticky: :e, padx: 8) { grid.label(text: Locale.translate(locale_key)) }
            var = grid.var("")
            @fields[key] = var
            grid.cell(row: i, col: 1, sticky: :w) { grid.label(bind: var) }
          end

          grid.cell(row: ROWS.size, col: 0, colspan: 2) do
            close_button = grid.button(text: Locale.translate("rom_info.close"))
          end
        end
      end

      @close_button = close_button.as(Tryst::UI::Handle)
      @close_button.on_action { |_v, _s| @on_close.try(&.call) || @handle.hide }
    end

    # Fires when the in-window Close button is clicked - wire this to
    # ModalStack#pop (not just #hide, which never touches ModalStack's
    # own bookkeeping and would leave it thinking this window is still
    # active forever, permanently blocking every future modal). Set once
    # ModalStack exists, same reason the button's own #on_action above is
    # wired after @handle rather than inline.
    def on_close(&block : -> Nil) : Nil
      @on_close = block
    end

    def handle : Tryst::UI::Handle
      @handle
    end

    # The currently displayed text for one field ("title", "game_code",
    # "publisher", "platform", "rom_size", "checksum", "rom_path",
    # "save_path", "resolution" - see ROWS), or nil for an unknown key.
    def field(key : String) : String?
      @fields[key]?.try(&.value.as(String))
    end

    def show(data : RomInfoData, rom_path : String, save_path : String) : Nil
      populate(data, rom_path, save_path)
      @handle.show
    end

    private def populate(data : RomInfoData, rom_path : String, save_path : String) : Nil
      na = Locale.translate("rom_info.na")
      maker = data.maker_code
      publisher = maker.empty? ? na : "#{self.class.publisher_name(maker)} (#{maker})"

      @fields["title"].value = data.title
      @fields["game_code"].value = data.game_code
      @fields["publisher"].value = publisher
      @fields["platform"].value = data.platform
      @fields["rom_size"].value = format_size(data.rom_size)
      @fields["checksum"].value = "0x%08X" % data.checksum
      @fields["rom_path"].value = rom_path.empty? ? na : rom_path
      @fields["save_path"].value = save_path.empty? ? na : save_path
      @fields["resolution"].value = "#{data.width}x#{data.height}"
    end

    private def format_size(bytes : UInt64) : String
      if bytes >= 1024 * 1024
        "%.1f MB (%d bytes)" % [bytes / (1024.0 * 1024), bytes]
      elsif bytes >= 1024
        "%.1f KB (%d bytes)" % [bytes / 1024.0, bytes]
      else
        "#{bytes} bytes"
      end
    end
  end
end
