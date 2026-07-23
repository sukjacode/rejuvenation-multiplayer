# Rejuvenation Co-op (Schritt D): Remote-Spieler sehen + Bewegung.
#
# WICHTIG: Diese Datei gehoert nach patch/Mods/ (NICHT patch/Init/).
# patch/Init laeuft VOR den Engine-Klassen; patch/Mods laeuft danach, sodass
# Game_Character und Spriteset_Map hier bereits definiert sind.
#
# Aufbau:
#   - Coop            : szenenunabhaengiger Singleton, Netz-Thread, State-Store, Sender
#   - Game_OnlinePlayer : Game_Character-Subklasse (through=true) mit abgespecktem
#                         update (nur Bewegung + Animation, KEINE Event-Trigger)
#   - Spriteset_Map-Hooks : erzeugen/aktualisieren/entfernen Remote-Sprites,
#                           gated auf die aktuelle map_id
#
# Constraints (siehe Briefing): kein blockierendes I/O in der Spiel-Loop,
# jeder Thread-Body mit rescue Exception -> Datei, kein puts (Konsole unsichtbar).

require "socket"
require "thread"
require "json"
require "base64"

# Top-Level-Schutz: Ladefehler (z.B. fehlende Konstante) in Datei protokollieren,
# damit sie nicht nur im mkxp-Popup auftauchen.
begin

module Coop
  DEFAULT_HOST = "127.0.0.1"   # Fallback; ueberschrieben durch coop_config.txt
  DEFAULT_PORT = 7777
  CONFIG_FILE  = "coop_config.txt"
  LOG_ERR      = "coop_error.txt"
  STALE        = 3.0           # Sekunden ohne Update -> Remote-Spieler entfernen

  @mutex   = Mutex.new
  @remote  = {}            # id => { :m, :x, :y, :d, :name, :seen }
  @sock    = nil
  @id      = sprintf("%08x", rand(0xffffffff))
  @thread  = nil
  @host    = DEFAULT_HOST
  @port    = DEFAULT_PORT
  @token   = ""

  # Config aus coop_config.txt lesen. Unterstuetzt:
  #   - reine "host:port"-Zeile (altes Format, weiterhin gueltig)
  #   - "server = host:port"  (auch host/relay als Schluessel)
  #   - "token  = geheim"     (auch password als Schluessel)
  # Zeilen mit fuehrendem # werden ignoriert. Fehlt die Datei -> Fallback localhost.
  def self.load_config
    host = DEFAULT_HOST
    port = DEFAULT_PORT
    token = ""
    if File.exist?(CONFIG_FILE)
      File.read(CONFIG_FILE).each_line do |raw|
        line = raw.strip
        next if line == "" || line.start_with?("#")
        key = nil
        val = line
        if line.include?("=")
          k, v = line.split("=", 2)
          key = k.strip.downcase
          val = v.strip
        end
        case key
        when "token", "password"
          token = val
        else
          # "server"/"host"/"relay" oder nil (altes Format) -> host:port
          h, p = parse_hostport(val)
          host = h if h
          port = p if p
        end
      end
    end
    @host = host
    @port = port
    @token = token
  rescue Exception => e
    log_err("load_config", e)
    @host = DEFAULT_HOST
    @port = DEFAULT_PORT
    @token = ""
  end

  def self.parse_hostport(val)
    if val.include?(":")
      h, p = val.split(":", 2)
      h = h.strip
      p = p.strip
      [h.empty? ? nil : h, (p.to_i > 0 ? p.to_i : nil)]
    else
      v = val.strip
      [v.empty? ? nil : v, nil]
    end
  end

  # Sender-Drossel
  @last_key   = nil
  @keepalive  = 0

  def self.my_id
    @id
  end

  # Live-Gate (kein Einmal-Latch): Coop ist nur aktiv, wenn GERADE keine Cutscene/
  # kein Map-Event laeuft. So bleibt der Remote waehrend JEDER Cutscene (Intro, Bett,
  # spaetere Szenen) ausgeblendet und erscheint danach wieder an der aktuellen
  # Position. Verhindert das "Herumdraggen" ueber laufende Cutscenes.
  def self.free_roam?
    return false unless $game_player
    return false if pbMapInterpreterRunning?
    return true
  rescue Exception
    false
  end

  def self.log_err(prefix, e)
    File.open(LOG_ERR, "a") do |f|
      f.write("#{Time.now.strftime('%H:%M:%S')} #{prefix}: #{e.class}: #{e.message}\n")
      f.write(e.backtrace.join("\n") + "\n") if e.respond_to?(:backtrace) && e.backtrace
    end
  rescue Exception
    # Logging darf nie den Thread killen
  end

  def self.log_info(msg)
    File.open("coop_net.txt", "a") { |f| f.write("#{Time.now.strftime('%H:%M:%S')} #{msg}\n") }
  rescue Exception
  end

  def self.start
    load_config
    @thread ||= Thread.new do
      begin
        log_info("connecting to relay #{@host}:#{@port} (id=#{@id})")
        @sock = TCPSocket.new(@host, @port)
        @sock.sync = true
        # Auth-Handshake zuerst (Token aus Config). Blocking write ist hier ok,
        # weil wir im Netz-Thread sind, nicht im Main-Thread.
        @sock.write({ "t" => "auth", "token" => @token.to_s, "id" => @id }.to_json + "\n")
        log_info("connected to relay #{@host}:#{@port}")
        buf = ""
        loop do
          # Praesenz-Heartbeat (~alle 5s) -- laeuft auch, wenn der Spieler im Menue
          # ist (der Main-Thread sendet dann keine Positionen). raw_send hat Mutex.
          now = Time.now
          if @cached_name && (@last_presence.nil? || now - @last_presence > 5)
            @last_presence = now
            raw_send({ "t" => "presence", "id" => @id, "name" => @cached_name })
          end
          begin
            chunk = @sock.read_nonblock(4096)
            buf << chunk
            while (idx = buf.index("\n"))
              line = buf.slice!(0, idx + 1).chomp
              handle_line(line)
            end
          rescue IO::WaitReadable, Errno::EWOULDBLOCK, Errno::EAGAIN
            sleep 0.03
          rescue EOFError
            break
          end
        end
      rescue Exception => e
        log_err("net thread", e)
      ensure
        @sock_dead = true   # Verbindung verloren -> Kampf kann darauf reagieren
        log_info("relay connection lost")
      end
    end
  end

  # Verbindung intakt? (fuer Disconnect-Behandlung im Kampf)
  def self.connected?
    @sock && !@sock_dead
  end

  def self.handle_line(line)
    msg = JSON.parse(line) rescue nil
    return unless msg.is_a?(Hash)
    if msg["t"] == "error"
      log_info("relay error: #{msg["msg"]}")   # z.B. abgelehntes Token
      return
    end
    return unless msg["id"] && msg["id"] != @id

    case msg["t"]
    when "party"
      @mutex.synchronize { @remote_party[msg["id"]] = { :blob => msg["blob"], :seen => Time.now } }
    when "bstart"
      # Startbefehl fuer den gespiegelten Sync-Kampf (Weg B)
      return unless msg["to"] == @id
      @mutex.synchronize do
        @bstart_in = { :from => msg["id"], :seed => msg["seed"], :kind => msg["kind"],
                       :mon => msg["mon"], :opp => msg["opp"], :time => Time.now }
      end
      log_battle("bstart received from #{msg["id"]} seed=#{msg["seed"]} kind=#{msg["kind"]}")
    when "bcmd"
      # Lockstep: Runden-Kommando des Partners
      return unless msg["to"] == @id
      @mutex.synchronize { @bcmd_in[msg["round"]] = msg }
    when "bswitch"
      # Lockstep: Zwangswechsel-Entscheidung des Partners
      return unless msg["to"] == @id
      @mutex.synchronize { @bswitch_in.push(msg) }
    when "bflee"
      # Partner flieht -> beide verlassen den Kampf
      return unless msg["to"] == @id
      @mutex.synchronize { @bflee_in = true }
    when "presence"
      @mutex.synchronize { @roster[msg["id"]] = { :name => msg["name"], :seen => Time.now } }
    when "pvp_req"
      return unless msg["to"] == @id
      @mutex.synchronize { @pvp_reqs[msg["id"]] = { :name => msg["name"], :time => Time.now } }
    when "pvp_reqcancel"
      return unless msg["to"] == @id
      @mutex.synchronize { @pvp_reqs.delete(msg["id"]) }
    when "pvp_accept"
      return unless msg["to"] == @id
      @mutex.synchronize { @pvp_accept_in = { :from => msg["id"], :team => msg["team"], :time => Time.now } }
    when "pvp_start"
      return unless msg["to"] == @id
      @mutex.synchronize { @pvp_start_in = { :from => msg["id"], :seed => msg["seed"], :team => msg["team"], :time => Time.now } }
      log_battle("pvp_start received from #{msg["id"]} seed=#{msg["seed"]}")
    when "trade_req"
      # Gezielte Tausch-Anfrage -> in die Liste (wird unter Trading > Receive gezeigt)
      return unless msg["to"] == @id
      @mutex.synchronize { @trade_reqs[msg["id"]] = { :name => msg["name"], :time => Time.now } }
    when "trade_accept"
      return unless msg["to"] == @id
      @mutex.synchronize { @trade_accept_in = { :from => msg["id"], :time => Time.now } }
    when "trade_commit"
      return unless msg["to"] == @id
      @mutex.synchronize { @trade_commit_in = true }
    when "trade_offer"
      return unless msg["to"] == @id
      @mutex.synchronize { @trade_offer_in = { :from => msg["id"], :mon => msg["mon"], :name => msg["name"], :time => Time.now } }
    when "trade_confirm"
      return unless msg["to"] == @id
      @mutex.synchronize { @trade_confirm_in = { :from => msg["id"], :ok => !!msg["ok"], :time => Time.now } }
    when "trade_cancel"
      return unless msg["to"] == @id
      @mutex.synchronize { @trade_cancel_in = true }
    when "trade_reqcancel"
      # Initiator hat seine Anfrage zurueckgezogen
      return unless msg["to"] == @id
      @mutex.synchronize { @trade_reqs.delete(msg["id"]) }
    when "binvite"
      # Kampf-Anfrage an UNS?
      return unless msg["to"] == @id
      @mutex.synchronize { @binvite_in = { :from => msg["id"], :time => Time.now } }
      log_battle("invite received from #{msg["id"]}")
    when "breply"
      # Antwort auf UNSERE Anfrage?
      return unless msg["to"] == @id
      @mutex.synchronize { @breply = { :from => msg["id"], :accept => !!msg["accept"], :time => Time.now } }
    else
      # kein/unbekannter Typ oder "pos" -> Positions-Update
      @mutex.synchronize do
        @remote[msg["id"]] = {
          :m    => msg["m"],
          :x    => msg["x"],
          :y    => msg["y"],
          :d    => msg["d"],
          :name => msg["name"],
          :sp   => msg["sp"],
          :seen => Time.now
        }
      end
    end
  rescue Exception => e
    log_err("handle_line", e)
  end

  # Momentaufnahme der Remote-States (fuer den Main-Thread / Spriteset)
  def self.snapshot
    @mutex.synchronize { @remote.dup }
  end

  # === Co-op-Kampf: Anfrage/Antwort-Gerueest ================================
  # Ablauf: Kommt ein Spieler in einen Kampf und ist ein Mitspieler auf
  # derselben Map, wird VOR dem Kampf eine Anfrage gesendet und bis zu 5s auf
  # die Antwort gewartet. Annahme -> $coop_battle_partner gesetzt (Doppelkampf-
  # Regeln folgen spaeter). Ablehnung/Timeout -> normaler Solokampf.

  INVITE_WAIT = 5.0   # Sekunden Wartezeit des Anfragenden
  INVITE_TTL  = 6.0   # aeltere eingehende Anfragen verfallen
  COOP_EXP_PERCENT = 50   # jeder Spieler bekommt diesen %-Anteil der normalen EXP

  @binvite_in = nil   # eingehende Anfrage  { :from, :time }
  @breply     = nil   # Antwort auf unsere Anfrage { :from, :accept, :time }
  @bstart_in  = nil   # Startbefehl fuer gespiegelten Kampf { :from, :seed, :kind, :mon, :time }
  @bcmd_in    = {}    # Lockstep: round => Kommando-Nachricht des Partners
  @bswitch_in = []    # Lockstep: FIFO der Partner-Zwangswechsel
  @bflee_in   = false # Partner hat Flucht gewaehlt
  @sock_dead  = false

  # Praesenz-Roster: wer ist verbunden (auch im Menue). Netz-Thread sendet
  # regelmaessig einen Praesenz-Heartbeat; Empfaenger fuehren @roster.
  @roster        = {}     # id => { :name, :seen }
  @cached_name   = nil    # vom Main-Thread gesetzt (Trainername), fuer den Heartbeat
  @last_presence = nil
  ROSTER_TTL     = 20.0

  # PvP-Zustand (Handshake wie Trading, Kampf wie der Sync-Kampf)
  @pvp_reqs      = {}     # eingehende Herausforderungen: from_id => { :name, :time }
  @pvp_accept_in = nil    # { :from, :team, :time }
  @pvp_start_in  = nil    # { :from, :seed, :team, :time }
  @pvp_wins      = 0
  @pvp_losses    = 0
  @pvp_pending   = nil    # { :team, :partner, :seed } -> im Feld (Scene_Map) gestartet

  # Trading-Zustand
  @trade_reqs       = {}  # eingehende Anfragen: from_id => { :name, :time }
  @trade_accept_in  = nil
  @trade_offer_in   = nil
  @trade_confirm_in = nil
  @trade_commit_in  = false
  @trade_cancel_in  = false
  @trading          = false

  def self.set_name(n)
    @cached_name = n if n && n != ""
  end

  # Verbundene Spieler (ausser uns selbst), frisch laut Roster: [[id, name], ...]
  def self.online_players
    now = Time.now
    @mutex.synchronize do
      @roster.select { |id, e| id != @id && (now - e[:seen]) < ROSTER_TTL }
             .map { |id, e| [id, e[:name].to_s] }
    end
  end

  # Trainername eines Spielers laut Roster (fuer Namensschilder), "" falls unbekannt.
  def self.name_for(id)
    @mutex.synchronize { e = @roster[id]; e ? e[:name].to_s : "" }
  end

  # Offene eingehende Tausch-Anfragen: [[from_id, name], ...]
  def self.pending_requests
    now = Time.now
    @mutex.synchronize do
      @trade_reqs.select { |id, e| (now - e[:time]) < 60 }
                 .map { |id, e| [id, e[:name].to_s] }
    end
  end

  COOP_DEBUG   = false  # true = Debug-Datei-Trigger aktiv (nur zum Testen)
  WAIT_TIMEOUT = 90.0   # Sek. auf Partner warten, dann Disconnect -> KI

  # --- Party-Sync -----------------------------------------------------------
  # Jede Instanz broadcastet ihre Party als Marshal+Base64-Blob (exakte Klone,
  # gleiche Technik wie Spielstaende). Blob = [name, trainertyp, trainer_id, party].
  @remote_party     = {}    # id => { :blob => b64, :seen => Time.now }
  @party_last_hash  = nil
  @party_tick       = 0
  @coop_partner_registered = false

  # Pro Frame aus dem Spriteset gerufen; sendet alle ~2s bei Aenderung,
  # alle ~15s als Keepalive.
  def self.tick_party
    return unless @sock
    return unless defined?($Trainer) && $Trainer && $Trainer.party
    @party_tick += 1
    return if @party_tick % 80 != 0   # nur alle ~2s pruefen (Marshal ist nicht gratis)
    blob = Marshal.dump([$Trainer.name, $Trainer.trainertype, $Trainer.id, $Trainer.party])
    h = blob.hash
    force = (@party_tick % 600 == 0)  # Keepalive ~alle 15s
    return if h == @party_last_hash && !force
    @party_last_hash = h
    send_msg({ "t" => "party", "blob" => Base64.strict_encode64(blob) })
  rescue Exception => e
    log_err("tick_party", e)
  end

  # Party-Blob eines Mitspielers (b64) oder nil
  def self.party_for(id)
    @mutex.synchronize do
      e = @remote_party[id]
      e ? e[:blob] : nil
    end
  end

  def self.log_battle(msg)
    File.open("coop_battle.txt", "a") { |f| f.write("#{Time.now.strftime('%H:%M:%S')} #{msg}\n") }
  rescue Exception
  end

  # Zentrale Schreib-Funktion mit Mutex -- Main-Thread (send_msg/tick_send) UND
  # Netz-Thread (Praesenz-Heartbeat) schreiben in denselben Socket; ohne Mutex
  # koennten sich JSON-Zeilen verschraenken.
  @write_mutex ||= Mutex.new
  def self.raw_send(hash)
    return unless @sock
    line = hash.to_json + "\n"
    @write_mutex.synchronize { @sock.write_nonblock(line) }
    true
  rescue IO::WaitWritable, Errno::EWOULDBLOCK, Errno::EAGAIN
    false
  rescue Exception => e
    log_err("raw_send", e)
    false
  end

  # Generischer Sender (haengt eigene id an)
  def self.send_msg(hash)
    hash["id"] = @id
    raw_send(hash)
  end

  # Erster frischer Mitspieler auf unserer aktuellen Map: [id, name] oder nil
  def self.partner_on_map
    return nil unless $game_map
    cur = $game_map.map_id
    now = Time.now
    snapshot.each do |id, st|
      next if st[:m] != cur
      next if (now - st[:seen]) > STALE
      return [id, st[:name]]
    end
    nil
  end

  def self.clear_reply
    @mutex.synchronize { @breply = nil }
  end

  def self.take_reply
    @mutex.synchronize { r = @breply; @breply = nil; r }
  end

  # Eingehende Anfrage nur entnehmen, wenn wir sie JETZT anzeigen koennen
  # (sonst liegen lassen -- TTL laesst sie verfallen).
  def self.take_invite_if_showable
    return nil if $game_temp && $game_temp.in_battle
    return nil unless free_roam?
    @mutex.synchronize do
      inv = @binvite_in
      return nil unless inv
      @binvite_in = nil
      return nil if (Time.now - inv[:time]) > INVITE_TTL
      inv
    end
  end

  # Vor Kampfbeginn aufgerufen (Anfragender). Setzt $coop_battle_partner.
  def self.coop_battle_gate
    $coop_battle_partner = nil
    return unless @sock
    p = partner_on_map
    return unless p
    clear_reply
    send_msg({ "t" => "binvite", "to" => p[0] })
    log_battle("invite sent to #{p[0]}")
    deadline = Time.now + INVITE_WAIT
    answer = nil
    while Time.now < deadline
      Graphics.update
      Input.update
      r = take_reply
      if r && r[:from] == p[0]
        answer = r
        break
      end
    end
    if answer && answer[:accept]
      $coop_battle_partner = p
      log_battle("ACCEPTED by #{p[0]} -> Weg B Sync-Kampf")
      # Weg A (KI-Partner via register_coop_partner) ist durch den
      # synchronisierten Kampf (Weg B) abgeloest; Funktion bleibt als Fallback.
    elsif answer
      log_battle("DECLINED by #{p[0]} -> Solokampf")
    else
      log_battle("TIMEOUT (keine Antwort von #{p[0]}) -> Solokampf")
    end
  rescue Exception => e
    log_err("coop_battle_gate", e)
  end

  # Partner-Party in $PokemonGlobal.partner einhaengen -> die Engine macht
  # daraus (bei Trainer-/Bosskaempfen) automatisch einen Doppelkampf mit den
  # Pokemon des Mitspielers an unserer Seite (KI-gesteuert, komplett lokal).
  def self.register_coop_partner(id)
    if $PokemonGlobal.partner
      log_battle("story partner already active -> kein Coop-Partner")
      return
    end
    b64 = party_for(id)
    unless b64
      log_battle("keine Party-Daten von #{id} -> Solokampf")
      Kernel.pbMessage("Mitspieler hat zugestimmt, aber noch keine Team-Daten gesendet - Solokampf.") rescue nil
      return
    end
    name, ttype, tid, mons = Marshal.load(Base64.decode64(b64))
    if mons.nil? || mons.empty?
      log_battle("Party von #{id} ist leer -> Solokampf")
      Kernel.pbMessage("Dein Mitspieler hat noch keine Pokémon - Solokampf.") rescue nil
      return
    end
    $PokemonGlobal.partner = [ttype, name, tid, mons, []]
    @coop_partner_registered = true
    log_battle("partner registered: #{name} (#{mons.length} Pokemon)")
    Kernel.pbMessage("#{name} kämpft an deiner Seite!") rescue nil
  rescue Exception => e
    log_err("register_coop_partner", e)
    @coop_partner_registered = false
  end

  # === Weg B: gespiegelter Sync-Kampf =======================================
  # M2-Stand: Bei Annahme startet auf BEIDEN Rechnern derselbe Wildkampf mit
  # demselben Seed, beide Seiten voll KI-gesteuert (@controlPlayer). Verifikation
  # ueber RNG-Zaehler + Pruefsumme in coop_battle.txt -- muessen auf beiden
  # Rechnern identisch sein. EXP ist in Sync-Testkaempfen deaktiviert.

  def self.take_bstart
    @mutex.synchronize { b = @bstart_in; @bstart_in = nil; b }
  end

  # --- Lockstep-Helfer (laufen im Main-Thread waehrend des Kampfes) ---------

  # Lockstep aktiv? (Co-op-Doppelkampf ODER PvP)
  def self.lockstep_active?
    $coop_sync && ($coop_sync[:side] || $coop_sync[:pvp])
  end

  def self.local_slot
    return 0 if $coop_sync && $coop_sync[:pvp]   # PvP: du bist immer Slot 0
    $coop_sync && $coop_sync[:side] == 1 ? 2 : 0
  end

  def self.remote_slot
    return 1 if $coop_sync && $coop_sync[:pvp]   # PvP: Gegner ist Slot 1
    $coop_sync && $coop_sync[:side] == 1 ? 0 : 2
  end

  # Nicht-blockierendes Abgreifen (fuer Warteschleifen mit UI).
  def self.poll_bcmd(round)
    @mutex.synchronize { @bcmd_in.delete(round) }
  end

  # Wartet auf das Runden-Kommando des Partners (blockiert die Kampf-Szene,
  # haelt aber Graphics am Leben).
  def self.wait_bcmd(round, timeout = 120.0)
    deadline = Time.now + timeout
    loop do
      m = @mutex.synchronize { @bcmd_in.delete(round) }
      return m if m
      return nil if Time.now > deadline
      Graphics.update
      Input.update
    end
  end

  def self.wait_bswitch(timeout = 60.0)
    deadline = Time.now + timeout
    loop do
      m = @mutex.synchronize { @bswitch_in.shift }
      return m if m
      return nil if Time.now > deadline
      Graphics.update
      Input.update
    end
  end

  def self.take_bflee
    @mutex.synchronize { f = @bflee_in; @bflee_in = false; f }
  end

  # === Trading =============================================================
  def self.trading?; @trading; end

  # Setzt nur den transienten Zustand DES LAUFENDEN Tauschs zurueck
  # (nicht die eingehende Anfragen-Liste @trade_reqs).
  def self.clear_trade
    @mutex.synchronize do
      @trade_accept_in = nil; @trade_offer_in = nil
      @trade_confirm_in = nil; @trade_commit_in = false; @trade_cancel_in = false
    end
  end

  # Einfacher Listen-Auswahldialog -> Index oder -1.
  def self.pick_from_list(title, entries)
    return -1 if entries.empty?
    cmds = entries + [_INTL("Zurück")]
    idx = Kernel.pbMessage(title, cmds, cmds.length) rescue -1
    (idx.nil? || idx >= entries.length) ? -1 : idx
  end

  # Warteschleife mit sichtbarer, abbrechbarer Meldung.
  # Rueckgabe: yield-Ergebnis | :cancel (Partner) | :localcancel (B/ESC) | nil (Timeout).
  def self.trade_wait(text, timeout, partner = nil)
    deadline = Time.now + timeout
    msgwin = (Kernel.pbCreateMessageWindow(nil) rescue nil)
    begin
      (msgwin.text = text) if msgwin
      loop do
        return :cancel if @mutex.synchronize { c = @trade_cancel_in; c }
        if Input.trigger?(Input::B)
          send_msg({ "t" => "trade_cancel", "to" => partner }) if partner
          return :localcancel
        end
        r = yield
        return r if r
        return nil if Time.now > deadline || !connected?
        msgwin.update if msgwin
        Graphics.update
        Input.update
      end
    ensure
      (Kernel.pbDisposeMessageWindow(msgwin) rescue nil) if msgwin
    end
  end

  def self.trade_precheck
    if !connected?
      Kernel.pbMessage(_INTL("Nicht mit dem Server verbunden.")) rescue nil
      return false
    end
    if @trading
      Kernel.pbMessage(_INTL("Ein Tausch laeuft bereits.")) rescue nil
      return false
    end
    true
  end

  # Trading > Request: Spieler aus der Verbundenen-Liste waehlen -> Anfrage.
  def self.trade_request_flow
    return unless trade_precheck
    players = online_players
    if players.empty?
      Kernel.pbMessage(_INTL("Aktuell ist niemand zum Tauschen verbunden.")) rescue nil
      return
    end
    sel = pick_from_list(_INTL("Mit wem moechtest du tauschen?"), players.map { |id, nm| nm })
    return if sel < 0
    partner = players[sel][0]
    clear_trade
    send_msg({ "t" => "trade_req", "to" => partner, "name" => (($Trainer.name rescue nil) || "?") })
    res = trade_wait(_INTL("Anfrage an {1} gesendet.\nWarte auf Annahme...\nB / ESC = Abbrechen", players[sel][1]), 30, nil) do
      m = @mutex.synchronize { a = @trade_accept_in; @trade_accept_in = nil; a }
      (m && m[:from] == partner) ? m[:from] : nil
    end
    unless res.is_a?(String)
      send_msg({ "t" => "trade_reqcancel", "to" => partner })   # Anfrage zurueckziehen
      Kernel.pbMessage(_INTL("Anfrage abgebrochen.")) rescue nil if res == :localcancel
      Kernel.pbMessage(_INTL("{1} hat nicht geantwortet.", players[sel][1])) rescue nil if res.nil?
      return
    end
    run_trade(partner)
  end

  # Trading > Receive: eingehende Anfragen ansehen -> annehmen.
  def self.trade_receive_flow
    return unless trade_precheck
    reqs = pending_requests
    if reqs.empty?
      Kernel.pbMessage(_INTL("Keine offenen Tausch-Anfragen.")) rescue nil
      return
    end
    sel = pick_from_list(_INTL("Tausch-Anfragen:"), reqs.map { |id, nm| nm })
    return if sel < 0
    from = reqs[sel][0]
    @mutex.synchronize { @trade_reqs.delete(from) }
    clear_trade
    send_msg({ "t" => "trade_accept", "to" => from })
    run_trade(from)
  end

  # Gemeinsame Tausch-Routine (beide Seiten): Pokemon waehlen -> Angebote
  # tauschen -> beidseitig bestaetigen -> Swap mit Animation (pbStartTrade).
  def self.run_trade(partner)
    @trading = true
    clear_trade
    # 1) eigenes Pokemon waehlen (Party-Screen)
    idx = trade_choose_pokemon
    if idx.nil? || idx < 0
      send_msg({ "t" => "trade_cancel", "to" => partner })
      Kernel.pbMessage(_INTL("Tausch abgebrochen.")) rescue nil
      return
    end
    mymon = $Trainer.party[idx]
    # 2) Angebot senden
    send_msg({ "t" => "trade_offer", "to" => partner,
               "mon" => Base64.strict_encode64(Marshal.dump(mymon)),
               "name" => (($Trainer.name rescue nil) || "?") })
    # 3) auf Partner-Angebot warten (abbrechbar)
    offer = trade_wait(_INTL("Warte auf das Angebot des Partners...\nB / ESC = Abbrechen"), 90, partner) do
      @mutex.synchronize { o = @trade_offer_in; @trade_offer_in = nil; o }
    end
    unless offer.is_a?(Hash)
      send_msg({ "t" => "trade_cancel", "to" => partner })
      Kernel.pbMessage(_INTL("Der Tausch wurde abgebrochen.")) rescue nil
      return
    end
    partnermon = Marshal.load(Base64.decode64(offer[:mon]))
    # 4) bestaetigen
    ok = false
    begin
      ok = Kernel.pbConfirmMessage(_INTL("Du gibst {1} ab und erhaeltst {2}.\nTauschen?", mymon.name, partnermon.name))
    rescue Exception
    end
    send_msg({ "t" => "trade_confirm", "to" => partner, "ok" => ok })
    unless ok
      send_msg({ "t" => "trade_cancel", "to" => partner })
      Kernel.pbMessage(_INTL("Tausch abgebrochen.")) rescue nil
      return
    end
    # 5) auf Partner-Bestaetigung warten (abbrechbar)
    conf = trade_wait(_INTL("Warte auf die Bestaetigung des Partners...\nB / ESC = Abbrechen"), 60, partner) do
      @mutex.synchronize { c = @trade_confirm_in; @trade_confirm_in = nil; c }
    end
    unless conf.is_a?(Hash) && conf[:ok]
      send_msg({ "t" => "trade_cancel", "to" => partner })
      Kernel.pbMessage(_INTL("Der Partner hat den Tausch abgelehnt.")) rescue nil
      return
    end
    # 6) Commit-Handshake (Absicherung): beide melden "bereit", erst dann wird
    #    getauscht. Nach beidseitiger Bestaetigung NICHT mehr lokal abbrechbar --
    #    nur Partner-Abbruch/Disconnect/Timeout verhindert den Swap. Verkleinert
    #    das Zeitfenster, in dem Verlust/Dupe entstehen koennte.
    send_msg({ "t" => "trade_commit", "to" => partner })
    committed = false
    cmw = (Kernel.pbCreateMessageWindow(nil) rescue nil)
    (cmw.text = _INTL("Tausch wird abgeschlossen...")) if cmw
    tdl = Time.now + 20
    loop do
      committed = @mutex.synchronize { @trade_commit_in }
      break if committed
      break if Time.now > tdl || !connected? || @mutex.synchronize { @trade_cancel_in }
      cmw.update if cmw
      Graphics.update
      Input.update
    end
    (Kernel.pbDisposeMessageWindow(cmw) rescue nil) if cmw
    unless committed
      Kernel.pbMessage(_INTL("Der Tausch konnte nicht abgeschlossen werden.")) rescue nil
      return
    end

    # PID-Kollisionsschutz (nur relevant bei gleichem Spielstand / Test): falls das
    # erhaltene Pokemon dieselbe Personal-ID wie eins in meiner Party hat, neu wuerfeln.
    begin
      if partnermon.respond_to?(:personalID) && partnermon.respond_to?(:personalID=)
        if $Trainer.party.any? { |p| p && p.personalID == partnermon.personalID }
          partnermon.personalID = rand(2**32)
          log_battle("trade: PID-Kollision -> neu gewuerfelt")
        end
      end
    rescue Exception
    end

    # 7) Swap + Animation
    pbStartTrade(idx, partnermon, partnermon.name, offer[:name].to_s, offer[:name].to_s, partnermon.level, partnermon.form)
    log_battle("trade done: gab #{mymon.name}, erhielt #{partnermon.name}")
  rescue Exception => e
    log_err("run_trade", e)
    begin; send_msg({ "t" => "trade_cancel", "to" => partner }); rescue Exception; end
    Kernel.pbMessage(_INTL("Beim Tausch ist ein Fehler aufgetreten.")) rescue nil
  ensure
    @trading = false
    clear_trade
  end

  # Party-Screen zum Auswaehlen; liefert Index oder -1.
  def self.trade_choose_pokemon
    chosen = -1
    pbFadeOutIn(99999) {
      scene = PokemonScreen_Scene.new
      screen = PokemonScreen.new(scene, $Trainer.party)
      screen.pbStartScene(_INTL("Waehle ein Pokemon zum Tauschen."))
      chosen = screen.pbChoosePokemon
      screen.pbEndScene
    }
    chosen
  rescue Exception => e
    log_err("trade_choose_pokemon", e)
    -1
  end

  # === PvP ==================================================================
  # Handshake wie Trading; Kampf gespiegelt: jeder baut [eigenes Team] vs
  # [Partner-Team] mit demselben Seed, steuert Slot 0, Gegner-Zug (Slot 1) kommt
  # per Lockstep. Digest-Log verifiziert die Determinismus-Gleichheit.

  def self.pending_pvp
    now = Time.now
    @mutex.synchronize do
      @pvp_reqs.select { |id, e| (now - e[:time]) < 60 }.map { |id, e| [id, e[:name].to_s] }
    end
  end

  def self.pvp_stats; @mutex.synchronize { [@pvp_wins, @pvp_losses] }; end
  def self.pvp_record_win;  @mutex.synchronize { @pvp_wins += 1 }; end
  def self.pvp_record_loss; @mutex.synchronize { @pvp_losses += 1 }; end

  def self.team_blob
    Base64.strict_encode64(Marshal.dump($Trainer.party))
  end

  # Menue: PvP > Request -> Spieler waehlen -> herausfordern.
  def self.pvp_request_flow
    return unless trade_precheck
    players = online_players
    if players.empty?
      Kernel.pbMessage(_INTL("Aktuell ist niemand fuer PvP verbunden.")) rescue nil
      return
    end
    sel = pick_from_list(_INTL("Wen moechtest du herausfordern?"), players.map { |id, nm| nm })
    return if sel < 0
    partner = players[sel][0]
    @mutex.synchronize { @pvp_accept_in = nil; @pvp_start_in = nil }
    send_msg({ "t" => "pvp_req", "to" => partner, "name" => (($Trainer.name rescue nil) || "?") })
    acc = trade_wait(_INTL("Herausforderung an {1} gesendet.\nWarte auf Annahme...\nB / ESC = Abbrechen", players[sel][1]), 30, nil) do
      m = @mutex.synchronize { a = @pvp_accept_in; @pvp_accept_in = nil; a }
      (m && m[:from] == partner) ? m : nil
    end
    unless acc.is_a?(Hash)
      send_msg({ "t" => "pvp_reqcancel", "to" => partner })
      Kernel.pbMessage(_INTL("Herausforderung abgebrochen.")) rescue nil if acc == :localcancel
      Kernel.pbMessage(_INTL("{1} hat nicht geantwortet.", players[sel][1])) rescue nil if acc.nil?
      return
    end
    # Angenommen -> Seed + eigenes Team senden, Kampf im Feld starten (Menue schliesst)
    seed = rand(2**30)
    send_msg({ "t" => "pvp_start", "to" => partner, "seed" => seed, "team" => team_blob })
    # Initiator = "Heimseite" (pbTieBreak 1); der Annehmer bekommt 0. So einigen
    # sich beide Rechner trotz gespiegelter Slots auf dieselbe Zug-Reihenfolge.
    @pvp_pending = { :team => acc[:team], :partner => partner, :seed => seed, :home => true }
  end

  # Menue: PvP > Receive -> Herausforderung annehmen.
  def self.pvp_receive_flow
    return unless trade_precheck
    reqs = pending_pvp
    if reqs.empty?
      Kernel.pbMessage(_INTL("Keine offenen Herausforderungen.")) rescue nil
      return
    end
    sel = pick_from_list(_INTL("PvP-Herausforderungen:"), reqs.map { |id, nm| nm })
    return if sel < 0
    from = reqs[sel][0]
    @mutex.synchronize { @pvp_reqs.delete(from); @pvp_start_in = nil }
    # Annehmen + eigenes Team senden; auf pvp_start (Seed + Gegner-Team) warten
    send_msg({ "t" => "pvp_accept", "to" => from, "team" => team_blob })
    st = trade_wait(_INTL("Angenommen. Warte auf Kampfstart...\nB / ESC = Abbrechen"), 30, nil) do
      m = @mutex.synchronize { s = @pvp_start_in; @pvp_start_in = nil; s }
      (m && m[:from] == from) ? m : nil
    end
    unless st.is_a?(Hash)
      Kernel.pbMessage(_INTL("Der Kampf kam nicht zustande.")) rescue nil
      return
    end
    @pvp_pending = { :team => st[:team], :partner => from, :seed => st[:seed], :home => false }
  end

  def self.pvp_pending?; !@pvp_pending.nil?; end

  # Aus Scene_Map: einen anstehenden PvP-Kampf im Feld starten.
  def self.run_pending_pvp
    p = @pvp_pending
    return unless p
    @pvp_pending = nil
    run_pvp_battle(p[:team], p[:partner], p[:seed], p[:home])
  end

  # Gespiegelter PvP-Kampf: [eigenes Team] vs [Partner-Team].
  def self.run_pvp_battle(their_team_blob, partner, seed, home = true)
    their_party = Marshal.load(Base64.decode64(their_team_blob))
    if their_party.nil? || their_party.empty?
      Kernel.pbMessage(_INTL("Gegner hat kein Team.")) rescue nil
      return
    end
    foename = name_for(partner); foename = "Rival" if foename.nil? || foename == ""
    foe = PokeBattle_Trainer.new(foename, ($Trainer.trainertype rescue 0))
    foe.id = rand(0xffffffff)
    foe.party = their_party
    clear_lockstep
    $coop_sync = { :seed => seed, :pvp => true, :partner => partner, :home => home }
    $coop_disconnected = false
    log_battle("pvp battle starting (seed=#{seed}, vs #{foename}, home=#{home})")
    $game_temp.in_battle = true
    scene = pbNewBattleScene
    battle = PokeBattle_Battle.new(scene, [$Trainer.party], [their_party], $Trainer, foe)
    battle.internalbattle = true
    pbPrepareBattle(battle)
    battle.doublebattle = false            # PvP v1 = 1-gegen-1 (keine Ziel-Abfrage)
    battle.instance_variable_set(:@disableExpGain, true)   # PvP = kein EXP (fair)
    battle.instance_variable_set(:@shiftStyle, false)      # Shift-Wechsel aus (desynct sonst)
    money_before = ($Trainer.money rescue nil)             # PvP = kein Geld (nur Statistik)
    decision = 0
    pbBattleAnimation(pbGetTrainerBattleBGM(foe)) {
      pbSceneStandby { decision = battle.pbStartBattle(true) }
      true
    }
    Input.update
    $game_temp.in_battle = false
    # Preisgeld/Verlust-Strafe neutralisieren -> im PvP wechselt kein Geld den Besitzer.
    ($Trainer.money = money_before) if money_before
    log_battle("pvp battle done decision=#{decision} rng=#{$coop_rng_count} digest=#{$coop_rng_digest}")
    # decision: 1 = Spieler (wir) gewinnen, 2/5 = verloren/unentschieden
    if decision == 1
      pvp_record_win
      Kernel.pbMessage(_INTL("Du hast das PvP-Duell gewonnen!")) rescue nil
    elsif [2, 5].include?(decision)
      pvp_record_loss
      Kernel.pbMessage(_INTL("Du hast das PvP-Duell verloren...")) rescue nil
    end
    w, l = pvp_stats
    log_battle("pvp record: #{w}W/#{l}L")
  rescue Exception => e
    log_err("run_pvp_battle", e)
    $game_temp.in_battle = false if $game_temp
  ensure
    $coop_sync = nil
    clear_lockstep
  end

  # DEBUG: Beutel mit Test-Items auffuellen (laeuft auf beiden Instanzen).
  def self.debug_stock_bag
    return unless COOP_DEBUG && defined?($PokemonBag) && $PokemonBag
    [[:POTION, 10], [:SUPERPOTION, 10], [:HYPERPOTION, 5], [:FULLRESTORE, 5],
     [:ORANBERRY, 10], [:XATTACK, 5]].each do |item, qty|
      begin
        $PokemonBag.pbStoreItem(item, qty) if $PokemonBag.pbQuantity(item) < qty
      rescue Exception
      end
    end
  rescue Exception => e
    log_err("debug_stock_bag", e)
  end

  def self.clear_lockstep
    @mutex.synchronize { @bcmd_in.clear; @bswitch_in.clear; @bflee_in = false }
  end

  # --- M3: echter Co-op-Doppelkampf -----------------------------------------
  # Beide Rechner bauen IDENTISCH: [Team A, Team B] vs Wildmon (2v1, lopsided),
  # gleicher Seed. side 0 = Initiator (steuert Slot 0), side 1 = Partner
  # (steuert Slot 2). Fremde Slots kommen per Lockstep (bcmd/bswitch).
  def self.run_coop_wild_battle(mon, partner_id, seed, side)
    mon = PokeBattle_Pokemon::PokemonBuilder.new(mon).build if mon.is_a?(Hash)
    blob = party_for(partner_id)
    unless blob
      log_battle("coop battle: keine Party-Daten von #{partner_id} -> abgebrochen")
      return
    end
    pname, pttype, ptid, pparty = Marshal.load(Base64.decode64(blob))
    fake = PokeBattle_Trainer.new(pname, pttype)
    fake.id = ptid
    fake.party = pparty
    if side == 0
      trainers = [$Trainer, fake]
      parties  = [$Trainer.party, pparty]
    else
      trainers = [fake, $Trainer]
      parties  = [pparty, $Trainer.party]
    end
    clear_lockstep
    $coop_sync = { :seed => seed, :side => side, :partner => partner_id }
    $coop_disconnected = false
    old_cp = $game_switches[:Control_Partners]
    cp_changed = true
    $game_switches[:Control_Partners] = true   # KI laesst Partner-Slot in Ruhe
    log_battle("coop battle starting (side=#{side}, seed=#{seed}, vs #{mon.name})")
    $game_temp.in_battle = true
    scene = pbNewBattleScene
    battle = PokeBattle_Battle.new(scene, parties, [[mon]], trainers, nil)
    battle.internalbattle = true
    pbPrepareBattle(battle)
    battle.doublebattle  = true
    battle.lopsidedBattle = true
    pbBattleAnimation(pbGetWildBattleBGM(mon.species)) {
      pbSceneStandby {
        battle.pbStartBattle(true)
      }
      true
    }
    Input.update
    $game_temp.in_battle = false
    log_battle("coop battle done rng_calls=#{$coop_rng_count} digest=#{$coop_rng_digest}")
  rescue Exception => e
    log_err("run_coop_wild_battle", e)
    $game_temp.in_battle = false if $game_temp
  ensure
    $game_switches[:Control_Partners] = old_cp if cp_changed
    $coop_sync = nil
    clear_lockstep
  end

  # Spiegelkampf beim Partner ausfuehren (aus Scene_Map heraus).
  def self.run_mirror_battle(b)
    return if (Time.now - b[:time]) > 10.0   # veralteter Start
    blob = party_for(b[:from])
    unless blob
      log_battle("mirror: keine Party-Daten von #{b[:from]} -> abgebrochen")
      return
    end
    mon = Marshal.load(Base64.decode64(b[:mon]))
    mon = PokeBattle_Pokemon::PokemonBuilder.new(mon).build if mon.is_a?(Hash)
    name, ttype, tid, party = Marshal.load(Base64.decode64(blob))
    fake = PokeBattle_Trainer.new(name, ttype)
    fake.id = tid
    fake.party = party
    $coop_sync = { :seed => b[:seed], :auto => true }
    log_battle("mirror battle starting (seed=#{b[:seed]}, #{party.length} mons vs #{mon.name})")
    $game_temp.in_battle = true
    scene = pbNewBattleScene
    battle = PokeBattle_Battle.new(scene, [party], [[mon]], fake, nil)
    battle.internalbattle = true
    pbPrepareBattle(battle)
    pbBattleAnimation(pbGetWildBattleBGM(mon.species)) {
      pbSceneStandby {
        battle.pbStartBattle(true)
      }
      true
    }
    Input.update
    $game_temp.in_battle = false
    log_battle("mirror battle done rng_calls=#{$coop_rng_count} digest=#{$coop_rng_digest}")
  rescue Exception => e
    log_err("run_mirror_battle", e)
    $game_temp.in_battle = false if $game_temp
  ensure
    $coop_sync = nil
  end

  # M4: Co-op-TRAINERkampf. Beide Rechner bauen [Team A, Team B] vs Trainer,
  # gleicher Seed, identischer (serialisiert uebertragener) Gegner.
  def self.run_coop_trainer_battle(opp, opp_items, opp_party, partner_id, seed, side)
    blob = party_for(partner_id)
    unless blob
      log_battle("coop trainer: keine Party-Daten von #{partner_id} -> abgebrochen")
      return
    end
    pname, pttype, ptid, pparty = Marshal.load(Base64.decode64(blob))
    fake = PokeBattle_Trainer.new(pname, pttype)
    fake.id = ptid
    fake.party = pparty
    if side == 0
      playertrainer = [$Trainer, fake]
      playerparty   = [$Trainer.party, pparty]
    else
      playertrainer = [fake, $Trainer]
      playerparty   = [pparty, $Trainer.party]
    end
    clear_lockstep
    $coop_sync = { :seed => seed, :side => side, :partner => partner_id }
    $coop_disconnected = false
    old_cp = $game_switches[:Control_Partners]
    cp_changed = true
    $game_switches[:Control_Partners] = true
    debug_stock_bag   # DEBUG: Traenke/Beeren zum Item-Test
    log_battle("coop trainer battle starting (side=#{side}, seed=#{seed}, vs #{opp.name})")
    $game_temp.in_battle = true
    scene = pbNewBattleScene
    battle = PokeBattle_Battle.new(scene, playerparty, [opp_party], playertrainer, opp, false, [])
    battle.internalbattle = true
    pbPrepareBattle(battle)
    battle.doublebattle   = true
    battle.lopsidedBattle  = (opp_party.length == 1)
    battle.endspeech = opp.defeatline rescue nil
    battle.items = opp_items || []   # bei EINEM Gegner: flache Item-Liste
    pbBattleAnimation(pbGetTrainerBattleBGM(opp)) {
      pbSceneStandby {
        battle.pbStartBattle(true)
      }
      true
    }
    Input.update
    $game_temp.in_battle = false
    log_battle("coop trainer battle done rng_calls=#{$coop_rng_count} digest=#{$coop_rng_digest}")
  rescue Exception => e
    log_err("run_coop_trainer_battle", e)
    $game_temp.in_battle = false if $game_temp
  ensure
    $game_switches[:Control_Partners] = old_cp if cp_changed
    $coop_sync = nil
    clear_lockstep
  end

  # Nach dem Kampf aufraeumen (nur unseren Coop-Partner, nie Story-Partner).
  def self.coop_battle_cleanup
    if @coop_partner_registered
      $PokemonGlobal.partner = nil
      @coop_partner_registered = false
      log_battle("partner deregistered")
    end
    $coop_battle_partner = nil
  rescue Exception => e
    log_err("coop_battle_cleanup", e)
  end

  # Pro Frame aus Scene_Map: liegt eine Anfrage vor -> Dialog + Antwort senden.
  def self.poll_incoming_invite
    inv = take_invite_if_showable
    return unless inv
    accept = false
    begin
      accept = Kernel.pbConfirmMessage("Ein Mitspieler möchte einen Kampf gemeinsam bestreiten! Mitkämpfen?")
    rescue Exception => e
      log_err("invite dialog", e)
    end
    send_msg({ "t" => "breply", "to" => inv[:from], "accept" => accept })
    log_battle(accept ? "invite from #{inv[:from]} ACCEPTED" : "invite from #{inv[:from]} DECLINED")
  rescue Exception => e
    log_err("poll_incoming_invite", e)
  end

  # Sendet den eigenen Zustand, gedrosselt: bei Aenderung sofort, sonst
  # ~ alle 20 Frames als Keepalive. Wird pro Frame aus dem Spriteset gerufen.
  def self.tick_send
    return unless @sock
    return unless free_roam?              # nicht senden, solange eine Cutscene laeuft
    return unless $game_player && $game_map
    m = $game_map.map_id
    x = $game_player.x
    y = $game_player.y
    d = $game_player.direction
    n = $game_player.character_name
    sp = ($game_player.move_speed rescue 4)   # Tempo mitsenden -> Remote laeuft gleich schnell
    key = [m, x, y, d, n]
    @keepalive += 1
    if key != @last_key || @keepalive >= 20
      @last_key  = key
      @keepalive = 0
      payload = { "t" => "pos", "id" => @id, "m" => m, "x" => x, "y" => y, "d" => d, "name" => n, "sp" => sp }
      raw_send(payload)   # write_nonblock + Mutex; blockiert den Main-Thread nie
    end
  rescue Exception => e
    log_err("tick_send outer", e)
  end
end

# --- Remote-Spieler als Game_Character ---------------------------------------

class Game_OnlinePlayer < Game_Character
  attr_reader :coop_id

  def initialize(map, coop_id)
    super(map)
    @coop_id      = coop_id
    @through      = true
    @move_speed   = 4
    @walk_anime   = true
    @anime_count  = 0
  end

  # Harte Positionsuebernahme (Snap), ohne triggerLeaveTile/Events.
  def warp_to(x, y, dir)
    @x = x
    @y = y
    @real_x = x * 128
    @real_y = y * 128
    @direction = dir if dir
  end

  # Ein-Tile-Schritt: Zielkachel setzen, real_x/y bleiben zurueck -> moving? = true,
  # unser update interpoliert dann samt Laufanimation.
  def step_to(x, y, dir)
    @direction = dir if dir
    @x = x
    @y = y
  end

  # Remote-Update. sp = Bewegungstempo des Partners (move_speed) -> gleiche
  # Geschwindigkeit wie der Partner, dadurch tile-fuer-tile statt "hinterhergleiten".
  def apply(x, y, dir, name, sp = nil)
    @character_name = name if name && name != @character_name
    @move_speed = sp if sp && sp > 0
    if moving?
      @x = x
      @y = y
      @direction = dir if dir
      return
    end
    dx = x - @x
    dy = y - @y
    if dx == 0 && dy == 0
      @direction = dir if dir
    elsif (dx.abs + dy.abs) == 1
      step_to(x, y, dir)
    else
      warp_to(x, y, dir)
    end
  end

  # Abgespecktes update: NUR Bewegungs-Interpolation + Pattern-Animation.
  def update
    if moving?
      distance = 2 ** @move_speed
      at_x = @x * 128
      at_y = @y * 128
      if     at_y > @real_y then @real_y = [@real_y + distance, at_y].min
      elsif  at_y < @real_y then @real_y = [@real_y - distance, at_y].max
      end
      if     at_x < @real_x then @real_x = [@real_x - distance, at_x].max
      elsif  at_x > @real_x then @real_x = [@real_x + distance, at_x].min
      end
      @anime_count += 1.5
    end
    if @anime_count > 18 - @move_speed * 3
      @pattern = (@pattern + 1) % 4
      @anime_count = 0
    end
    @pattern = 0 if !moving? && @anime_count == 0
  end
end

# --- Spriteset-Hooks: Remote-Sprites zeichnen --------------------------------

class Spriteset_Map
  alias coop_initialize initialize
  def initialize(map = nil)
    coop_initialize(map)
    @coop_online = {}   # id => { :char => Game_OnlinePlayer, :sprite => Sprite_Character }
  end

  alias coop_update update
  def update
    coop_update
    coop_update_online
    Coop.tick_send
    Coop.tick_party
  rescue Exception => e
    Coop.log_err("spriteset update", e)
  end

  alias coop_dispose dispose
  def dispose
    if @coop_online
      @coop_online.each_value { |o| o[:sprite].dispose if o[:sprite]; o[:label].dispose if o[:label] }
      @coop_online.clear
    end
    coop_dispose
  end

  def coop_update_online
    return unless @map == $game_map     # nur das aktive Map-Spriteset
    @coop_online ||= {}

    # Waehrend einer Cutscene/eines Map-Events: keine Remote-Sprites zeigen.
    unless Coop.free_roam?
      unless @coop_online.empty?
        @coop_online.each_value { |o| o[:sprite].dispose if o[:sprite]; o[:label].dispose if o[:label] }
        @coop_online.clear
      end
      return
    end

    cur = $game_map.map_id
    snap = Coop.snapshot
    now = Time.now

    # Entfernen: verschwunden, andere Map oder veraltet
    @coop_online.keys.each do |id|
      st = snap[id]
      if st.nil? || st[:m] != cur || (now - st[:seen]) > Coop::STALE
        @coop_online[id][:sprite].dispose if @coop_online[id][:sprite]
        @coop_online[id][:label].dispose if @coop_online[id][:label]
        @coop_online.delete(id)
      end
    end

    # Hinzufuegen / aktualisieren
    snap.each do |id, st|
      next if id == Coop.my_id
      next if st[:m] != cur
      next if (now - st[:seen]) > Coop::STALE
      next if st[:x].nil? || st[:y].nil?
      if !@coop_online[id]
        char = Game_OnlinePlayer.new($game_map, id)
        char.character_name = st[:name].to_s
        char.warp_to(st[:x], st[:y], st[:d])
        sprite = Sprite_Character.new(@viewport1, char)
        @coop_online[id] = { :char => char, :sprite => sprite, :label => nil, :labelname => nil, :age => 0 }
      else
        @coop_online[id][:char].apply(st[:x], st[:y], st[:d], st[:name], st[:sp])
      end
      o = @coop_online[id]
      o[:age] = (o[:age] || 0) + 1
      o[:char].update
      o[:sprite].update
      # Steht der Remote exakt auf DEINER Kachel (z.B. beide Spielstaende starten am
      # selben Punkt), nicht zeichnen -> kein "Klon auf dir selbst". Kommt einer
      # runter von der Kachel, erscheint er wieder. Label folgt sprite.visible.
      if $game_player && o[:char].x == $game_player.x && o[:char].y == $game_player.y
        o[:sprite].visible = false
      end
      coop_update_label(id, o)
    end
  end

  # Namensschild ueber dem Remote-Spieler (Trainername aus dem Praesenz-Roster).
  def coop_update_label(id, o)
    # Frisch erzeugtes Spriteset: Label ein paar Frames zurueckhalten. Beim Map-
    # Uebergang blendet die Engine altes+neues Spriteset -> ohne diese Sperre waeren
    # zwei Namen sichtbar. Nach ~0.5s ist der Uebergang durch -> Label erscheint sauber.
    if (o[:age] || 0) < 24
      if o[:label]; o[:label].dispose; o[:label] = nil; o[:labelname] = nil; end
      return
    end
    name = Coop.name_for(id)
    if name.nil? || name == ""
      if o[:label]; o[:label].dispose; o[:label] = nil; o[:labelname] = nil; end
      return
    end
    if o[:label].nil? || o[:labelname] != name
      o[:label].dispose if o[:label]
      bmp = Bitmap.new(176, 28)
      pbSetSmallFont(bmp) rescue nil
      pbDrawTextPositions(bmp, [[name, 88, 2, 2, Color.new(255, 255, 255), Color.new(0, 0, 0), 1]])
      spr = Sprite.new(@viewport1)
      spr.bitmap = bmp
      spr.ox = 88   # horizontal zentriert (bei sprite.x = screen_x)
      spr.oy = 28   # Unterkante des Labels als Ankerpunkt
      o[:label] = spr
      o[:labelname] = name
    end
    ch = o[:char]
    lbl = o[:label]
    lbl.x = ch.screen_x
    lbl.y = ch.screen_y - 30          # knapp ueber dem Kopf
    lbl.z = ch.screen_z(32) + 1       # ueber dem Charakter-Sprite
    lbl.visible = o[:sprite].visible
  rescue Exception => e
    Coop.log_err("coop_update_label", e)
  end
end

# --- Co-op-Kampf-Hooks -------------------------------------------------------

# Sync-Kampf-Unterstuetzung in der Battle-Engine:
#  - erzwungener Seed (beide Rechner wuerfeln identisch)
#  - Auto-Modus (@controlPlayer: KI spielt alle Slots -- M2-Spiegeltest)
#  - RNG-Zaehler + Pruefsumme fuer den Determinismus-Vergleich
class PokeBattle_Battle
  alias coop_sync_initialize initialize
  def initialize(*args)
    coop_sync_initialize(*args)
    if $coop_sync
      @seed = $coop_sync[:seed]
      @battleRandom = Random.new(@seed)
      if $coop_sync[:auto]
        @controlPlayer = true
        @disableExpGain = true
      end
      $coop_rng_count  = 0
      $coop_rng_digest = 0
      Coop.log_battle("battle initialized with sync seed=#{@seed} auto=#{!!$coop_sync[:auto]}")
    end
  end

  # Spiegel-Determinismus: die Engine ist fuer Online-Kaempfe gebaut. Ein Client
  # muss pbTieBreak==1 (Heimseite) liefern, der andere ==0. Der 0-Client tauscht
  # die Zug-Reihenfolge, sodass sich beide -- trotz gespiegelter Slots -- auf
  # DIESELBE Reihenfolge einigen (loest Speed-Gleichstand-Desyncs).
  alias coop_pvp_pbTieBreak pbTieBreak
  def pbTieBreak
    return ($coop_sync[:home] ? 1 : 0) if $coop_sync && $coop_sync[:pvp]
    coop_pvp_pbTieBreak
  end

  alias coop_sync_pbRandom pbRandom
  def pbRandom(x = 1.0)
    r = coop_sync_pbRandom(x)
    if $coop_sync
      $coop_rng_count += 1
      v = r.is_a?(Float) ? (r * 1_000_000).to_i : r.to_i
      $coop_rng_digest = ($coop_rng_digest * 31 + v) % 1_000_000_007
    end
    r
  end

  # === M3: Lockstep (nur aktiv, wenn $coop_sync[:side] gesetzt ist) =========

  # Platzhalter blockiert die lokale UI fuer den Slot des Partners
  # (commandloop ueberspringt Slots mit bereits gesetzter Wahl).
  alias coop_lockstep_commandloop commandloop
  def commandloop
    if $coop_sync && $coop_sync[:side]
      rs = Coop.remote_slot
      # Partner-Slot immer auf Platzhalter zwingen -- ueberschreibt auch eine
      # evtl. schon von der KI gesetzte Wahl (die KI laeuft vor commandloop).
      if @battlers[rs] && !@battlers[rs].isFainted? && pbCanShowCommands?(rs)
        @choices[rs] = [:coop_pending]
      end
    end
    coop_lockstep_commandloop
  end

  # Rundenzaehler + Austausch an der Rundengrenze.
  alias coop_lockstep_pbCommandPhase pbCommandPhase
  def pbCommandPhase
    if Coop.lockstep_active?
      @coop_round = (@coop_round || 0) + 1
      $coop_local_tuples = {}
      # Digest zu Rundenbeginn (= Stand NACH der vorigen Zug-Ausfuehrung) ->
      # zeigt exakt, in welcher Runde zwei Rechner divergieren.
      Coop.log_battle("round #{@coop_round} start: rng=#{$coop_rng_count} digest=#{$coop_rng_digest} " +
                      "speeds=[#{@battlers[0]&.pbSpeed},#{@battlers[1]&.pbSpeed}]")
    end
    coop_lockstep_pbCommandPhase
    coop_exchange_commands if Coop.lockstep_active? && @decision == 0
  end

  # Warte auf Partner-Kommando mit sichtbarem Text im Message-Fenster.
  # Rueckgabe: Kommando-Hash | :fled (Partner floh) | nil (Timeout/Disconnect -> KI).
  def coop_wait_for_partner(round, timeout = Coop::WAIT_TIMEOUT)
    return nil if $coop_disconnected
    deadline = Time.now + timeout
    msg = _INTL("Warte auf Mitspieler...")
    cw = nil
    begin
      sprites = @scene.instance_variable_get(:@sprites)
      cw = sprites ? sprites["messagewindow"] : nil
      @scene.pbShowWindow(1) if @scene.respond_to?(:pbShowWindow)  # 1 = MESSAGEBOX
    rescue Exception
    end
    loop do
      m = Coop.poll_bcmd(round)
      if m
        (cw.text = "" if cw) rescue nil
        return m
      end
      if Coop.take_bflee
        (cw.text = "" if cw) rescue nil
        return :fled
      end
      # Disconnect: Socket tot oder Timeout -> ab jetzt KI, nicht mehr warten
      if !Coop.connected? || Time.now > deadline
        $coop_disconnected = true
        Coop.log_battle("round #{round}: Verbindung verloren/Timeout -> KI uebernimmt Partner")
        begin
          if cw
            cw.text = _INTL("Verbindung zum Mitspieler verloren - der Computer uebernimmt.")
            30.times { cw.update; Graphics.update; Input.update }
            cw.text = ""
          end
        rescue Exception
        end
        return nil
      end
      begin
        if cw
          cw.text = msg if cw.text != msg
          cw.update
        end
      rescue Exception
      end
      Graphics.update
      Input.update
    end
  end

  def coop_exchange_commands
    ls = Coop.local_slot
    rs = Coop.remote_slot
    pvp = ($coop_sync && $coop_sync[:pvp])
    partner = $coop_sync[:partner]
    lside = pbIsOpposing?(ls) ? 1 : 0
    rside = pbIsOpposing?(rs) ? 1 : 0
    lowner = pbGetOwnerIndex(ls)
    flags = {
      "mega" => (@megaEvolution[lside][lowner] == ls),
      "ub"   => (@ultraBurst[lside][lowner] == ls),
      "tera" => (@terastal[lside][lowner] == ls),
      "z"    => (@zMove[lside][lowner] == ls)
    }
    Coop.send_msg({ "t" => "bcmd", "to" => partner, "round" => @coop_round,
                    "tuple" => $coop_local_tuples[ls], "flags" => flags })
    Coop.log_battle("round #{@coop_round}: local=#{$coop_local_tuples[ls].inspect}, warte auf Partner...")
    m = coop_wait_for_partner(@coop_round)
    if m == :fled
      @decision = 3
      Coop.log_battle("round #{@coop_round}: Partner floh -> Kampf endet")
      return
    end
    unless m
      # PvP: die KI-Wahl fuer den Gegner-Slot steht schon -> so lassen (Fallback).
      # Co-op: KI uebernimmt den Platzhalter.
      if !pvp && @choices[rs] && @choices[rs][0] == :coop_pending
        @choices[rs] = [nil]
        pbAutoChooseMove(rs)
      end
      return
    end
    # Anwenden: Co-op nur auf Platzhalter, PvP ueberschreibt die KI-Wahl fuer Slot 1.
    if pvp || (@choices[rs] && @choices[rs][0] == :coop_pending)
      @choices[rs] = [nil]
      tup = m["tuple"]
      applied = false
      if tup.is_a?(Array)
        case tup[0]
        when 0 # Attacke
          applied = pbRegisterMove(rs, tup[1], showMessage: false)
          pbRegisterTarget(rs, tup[2]) if applied && tup[2]
        when 1 # Item (Symbol wurde ueber JSON zu String -> zurueckwandeln)
          it = tup[1]
          it = it.to_sym if it.is_a?(String)
          applied = pbRegisterItem(rs, it, tup[2])
        when 2 # Pokemon-Wechsel
          applied = pbRegisterSwitch(rs, tup[1])
        when 5 # Rejuv-Spezialmove
          if respond_to?(:pbRegisterSpecialMove)
            applied = pbRegisterSpecialMove(rs, tup[1])
            pbRegisterSpecialMoveTarget(rs, tup[2]) if applied && tup[2] && respond_to?(:pbRegisterSpecialMoveTarget)
          end
        end
      end
      unless applied
        Coop.log_battle("round #{@coop_round}: Partner-Tuple #{tup.inspect} nicht anwendbar -> KI")
        pbAutoChooseMove(rs)
      end
      f = m["flags"] || {}
      rowner = pbGetOwnerIndex(rs)
      # Zuerst eine evtl. von der KI gesetzte Sonderaktion fuer den Gegner-Slot
      # loeschen, dann exakt die Wahl des Partners uebernehmen (sonst Desync: die
      # KI koennte z.B. Mega ausgewaehlt haben, der Partner-Mensch aber nicht).
      @megaEvolution[rside][rowner] = -1 if @megaEvolution[rside][rowner] == rs
      @ultraBurst[rside][rowner]    = -1 if @ultraBurst[rside][rowner] == rs
      @terastal[rside][rowner]      = -1 if @terastal[rside][rowner] == rs
      @zMove[rside][rowner]         = -1 if @zMove[rside][rowner] == rs
      @megaEvolution[rside][rowner] = rs if f["mega"]
      @ultraBurst[rside][rowner]    = rs if f["ub"]
      @terastal[rside][rowner]      = rs if f["tera"]
      @zMove[rside][rowner]         = rs if f["z"]
      Coop.log_battle("round #{@coop_round}: Partner-Wahl angewendet #{tup.inspect} flags=#{f.inspect}")
    end
  rescue Exception => e
    Coop.log_err("coop_exchange_commands", e)
  end

  # Lokale Wahlen als Tuple aufzeichnen (Replay-Muster der Engine).
  alias coop_rec_pbRegisterMove pbRegisterMove
  def pbRegisterMove(idxPokemon, idxMove, showMessage: false)
    r = coop_rec_pbRegisterMove(idxPokemon, idxMove, showMessage: showMessage)
    if r && Coop.lockstep_active? && $coop_local_tuples && idxPokemon == Coop.local_slot
      $coop_local_tuples[idxPokemon] = [0, idxMove, nil]
    end
    r
  end

  alias coop_rec_pbRegisterTarget pbRegisterTarget
  def pbRegisterTarget(idxPokemon, idxTarget)
    r = coop_rec_pbRegisterTarget(idxPokemon, idxTarget)
    if Coop.lockstep_active? && $coop_local_tuples && idxPokemon == Coop.local_slot && $coop_local_tuples[idxPokemon]
      $coop_local_tuples[idxPokemon][2] = idxTarget
    end
    r
  end

  alias coop_rec_pbRegisterSwitch pbRegisterSwitch
  def pbRegisterSwitch(idxPokemon, idxOther)
    r = coop_rec_pbRegisterSwitch(idxPokemon, idxOther)
    if r && Coop.lockstep_active? && $coop_local_tuples && idxPokemon == Coop.local_slot
      $coop_local_tuples[idxPokemon] = [2, idxOther]
    end
    r
  end

  # Zwangswechsel (nach K.O.): lokal per UI + senden, fremd auf Partner warten.
  alias coop_lockstep_pbSwitchInBetween pbSwitchInBetween
  def pbSwitchInBetween(indices, lax, cancancel, agent)
    if Coop.lockstep_active?
      if indices.first == Coop.local_slot
        ret = coop_lockstep_pbSwitchInBetween(indices, lax, cancancel, agent)
        blob = Base64.strict_encode64(Marshal.dump(ret))
        Coop.send_msg({ "t" => "bswitch", "to" => $coop_sync[:partner], "ret" => blob })
        Coop.log_battle("switch-in lokal #{indices.inspect} -> gesendet")
        return ret
      elsif indices.first == Coop.remote_slot
        Coop.log_battle("switch-in fremd #{indices.inspect} -> warte auf Partner")
        m = Coop.wait_bswitch
        if m
          raw = Marshal.load(Base64.decode64(m["ret"]))
          # Der Partner hat den Hash nach SEINEM Slot indiziert (gespiegelt).
          # Auf meinen Gegner-Slot umschreiben, sonst nickt der Wechsel den
          # falschen Slot (oder gar keinen) an -> Crash im Shift-/Sendout-Code.
          if raw.is_a?(Hash)
            remapped = {}
            raw.each_value { |v| remapped[Coop.remote_slot] = v }
            return remapped
          end
          return raw
        end
        Coop.log_battle("switch-in TIMEOUT -> KI (DESYNC-RISIKO)")
        return @ai.pbChooseNewEnemy(indices, agent)
      end
    end
    coop_lockstep_pbSwitchInBetween(indices, lax, cancancel, agent)
  end

  # EXP im Co-op-Kampf: an die LOKALE echte Party ($Trainer.party) vergeben,
  # anteilig (COOP_EXP_PERCENT). Noetig, weil die Engine nur @party1[0] beruecksichtigt
  # -- auf Seite 1 waere das die Klon-Party. Kein pbRandom -> kein Desync.
  # Geld bleibt unangetastet (jeder Rechner vergibt lokal an $Trainer -> normal).
  alias coop_orig_pbGainEXP pbGainEXP
  def pbGainEXP
    return coop_orig_pbGainEXP unless $coop_sync && $coop_sync[:side]
    my_slot = Coop.local_slot
    return unless @battlers[my_slot]
    my_idx = @battlers[my_slot].pokemonIndex
    saved_party = @party1
    saved_parts = {}
    for i in 0...4
      next unless pbIsOpposing?(i)
      saved_parts[i] = @battlers[i].participants
      # nur MEIN aktives Pokemon zaehlt als Teilnehmer (nicht das des Partners)
      @battlers[i].participants = @battlers[i].participants.include?(my_idx) ? [my_idx] : []
    end
    @party1 = [$Trainer.party]   # Engine vergibt an party1[0] -> meine echte Party
    sw = $game_switches[:Percent_Exp_Gains]
    vr = $game_variables[:Exp_Percent]
    $game_switches[:Percent_Exp_Gains] = true
    $game_variables[:Exp_Percent] = Coop::COOP_EXP_PERCENT   # anteilige EXP
    begin
      coop_orig_pbGainEXP
    ensure
      @party1 = saved_party
      saved_parts.each { |i, p| @battlers[i].participants = p }
      $game_switches[:Percent_Exp_Gains] = sw
      $game_variables[:Exp_Percent] = vr
    end
  rescue Exception => e
    Coop.log_err("coop pbGainEXP", e)
  end

  # --- Items im Co-op-Kampf --------------------------------------------------
  # Balls/Battle-Use-Items (Fangen etc.) im Co-op sperren; Medizin/X-Items erlaubt.
  # Beutel wird beim Auswaehlen lokal abgezogen -> jeder aus SEINEM Beutel.
  alias coop_rec_pbRegisterItem pbRegisterItem
  def pbRegisterItem(idxPokemon, item, idxTarget)
    item = item.to_sym if item.is_a?(String)   # JSON-String -> Symbol
    if $coop_sync && $coop_sync[:pvp]
      pbDisplay(_INTL("Items sind im PvP-Duell nicht erlaubt!"))
      return false
    end
    if $coop_sync && $coop_sync[:side]
      useinbattle = (ItemHandlers.hasUseInBattle(item) rescue false)
      if useinbattle
        pbDisplay(_INTL("Dieses Item ist im Co-op-Kampf nicht verfuegbar!"))
        return false
      end
    end
    r = coop_rec_pbRegisterItem(idxPokemon, item, idxTarget)
    if r && $coop_sync && $coop_sync[:side] && $coop_local_tuples && idxPokemon == Coop.local_slot
      $coop_local_tuples[idxPokemon] = [1, item, idxTarget]
    end
    r
  end

  # Effekt des Partner-Items anwenden, aber NIE meinen Beutel veraendern.
  alias coop_bag_pbUseItemOnPokemon pbUseItemOnPokemon
  def pbUseItemOnPokemon(item, pkmnIndex, userPkmn, scene)
    remote = ($coop_sync && $coop_sync[:side] && userPkmn.index == Coop.remote_slot)
    before = remote ? ($PokemonBag.pbQuantity(item) rescue 0) : nil
    r = coop_bag_pbUseItemOnPokemon(item, pkmnIndex, userPkmn, scene)
    coop_restore_bag(item, before) if remote
    r
  end

  alias coop_bag_pbUseItemOnBattler pbUseItemOnBattler
  def pbUseItemOnBattler(item, index, userPkmn, scene)
    remote = ($coop_sync && $coop_sync[:side] && userPkmn.index == Coop.remote_slot)
    before = remote ? ($PokemonBag.pbQuantity(item) rescue 0) : nil
    r = coop_bag_pbUseItemOnBattler(item, index, userPkmn, scene)
    coop_restore_bag(item, before) if remote
    r
  end

  def coop_restore_bag(item, before)
    return if before.nil?
    now = ($PokemonBag.pbQuantity(item) rescue before)
    while now > before
      $PokemonBag.pbDeleteItem(item); now -= 1   # fremde Rueckgabe rueckgaengig
    end
  rescue Exception
  end

  # --- Flucht im Co-op-Kampf: gemeinsam ------------------------------------
  # Gelingt einem die Flucht, flieht auch der Partner (bflee-Signal).
  alias coop_flee_pbRun pbRun
  def pbRun(idxPokemon, duringBattle = false)
    r = coop_flee_pbRun(idxPokemon, duringBattle)
    if r > 0 && $coop_sync && $coop_sync[:side]
      Coop.send_msg({ "t" => "bflee", "to" => $coop_sync[:partner] })
      Coop.log_battle("Flucht gelungen -> Partner benachrichtigt")
    end
    r
  end

  # --- Spezial-Moves (Rejuv) im Co-op ---------------------------------------
  if method_defined?(:pbRegisterSpecialMove)
    alias coop_rec_pbRegisterSpecialMove pbRegisterSpecialMove
    def pbRegisterSpecialMove(idxPokemon, idxMove, showMessages = true)
      if $coop_sync && $coop_sync[:pvp]
        pbDisplay(_INTL("Spezial-Moves sind im PvP-Duell nicht erlaubt!"))
        return false
      end
      r = coop_rec_pbRegisterSpecialMove(idxPokemon, idxMove, showMessages)
      if r && $coop_sync && $coop_sync[:side] && $coop_local_tuples && idxPokemon == Coop.local_slot
        $coop_local_tuples[idxPokemon] = [5, idxMove, nil]
      end
      r
    end
  end
  if method_defined?(:pbRegisterSpecialMoveTarget)
    alias coop_rec_pbRegisterSpecialMoveTarget pbRegisterSpecialMoveTarget
    def pbRegisterSpecialMoveTarget(idxPokemon, idxTarget)
      r = coop_rec_pbRegisterSpecialMoveTarget(idxPokemon, idxTarget)
      if $coop_sync && $coop_sync[:side] && $coop_local_tuples && idxPokemon == Coop.local_slot && $coop_local_tuples[idxPokemon] && $coop_local_tuples[idxPokemon][0] == 5
        $coop_local_tuples[idxPokemon][2] = idxTarget
      end
      r
    end
  end
end

# PvP: die Gegner-KI komplett abschalten. Beide Slots sind menschlich (Slot 0 lokal,
# Slot 1 per Lockstep) -- ohne das wuerde die KI den Gegner-Slot mega-evolvieren und
# Zufall verbrauchen (Desync). Gezielter als isOnline? (bricht nicht den Intro-Ablauf).
class PokeBattle_AI
  alias coop_pvp_processAIturn processAIturn
  def processAIturn(*a)
    if $coop_sync && $coop_sync[:pvp]
      Coop.log_battle("pvp: KI-Zug uebersprungen") rescue nil
      return
    end
    coop_pvp_processAIturn(*a)
  end
end

# Anfragender: Gate vor Wildkaempfen; bei Annahme -> Sync-Kampf (Seed + bstart).
alias coop_orig_pbWildBattleObject pbWildBattleObject
def pbWildBattleObject(*args)
  args[0] = PokeBattle_Pokemon::PokemonBuilder.new(args[0]).build if args[0].is_a?(Hash)
  # Endziel: normales Gras bleibt SOLO. Co-op nur bei Boss-Wildmons (oder Debug).
  is_boss = (args[0].isbossmon rescue false)
  if $coop_force_wild_coop || is_boss
    Coop.coop_battle_gate
    if $coop_battle_partner
      begin
        p = $coop_battle_partner
        seed = rand(2**30)
        mon_b64 = Base64.strict_encode64(Marshal.dump(args[0]))
        Coop.send_msg({ "t" => "bstart", "to" => p[0], "seed" => seed, "kind" => "coop_wild", "mon" => mon_b64 })
        Coop.log_battle("coop bstart sent to #{p[0]} seed=#{seed}")
        Coop.run_coop_wild_battle(args[0], p[0], seed, 0)
        Coop.coop_battle_cleanup
        return true
      rescue Exception => e
        Coop.log_err("coop wild init", e)
        $coop_sync = nil
      end
    end
  end
  result = coop_orig_pbWildBattleObject(*args)
  Coop.coop_battle_cleanup
  result
end

# Trainerkaempfe: Co-op-Gate. Positionsargumente: trainerid, trainername,
# endspeech, doublebattle, trainerparty(=Index 4), canlose, variable, ...
alias coop_orig_pbTrainerBattle pbTrainerBattle
def pbTrainerBattle(*args, **kw, &blk)
  # Nicht auf schon laufende Spezial-Doppel (waitingTrainer) draufsetzen.
  if !$PokemonTemp.waitingTrainer && !$PokemonGlobal.partner
    Coop.coop_battle_gate
    if $coop_battle_partner
      begin
        p = $coop_battle_partner
        trainerid    = args[0]
        trainername  = args[1]
        trainerparty = args[4] || 0
        levelcap     = kw[:levelCap] || 0
        tr = pbLoadTrainer(trainerid, trainername, trainerparty, hasLevelCap: levelcap > 0)
        if tr && Coop::COOP_DEBUG && $coop_debug_boss
          # DEBUG: Gegner staerken, damit der Kampf lang genug fuer Item-/Flucht-Tests ist
          (tr[2] || []).each do |m|
            next unless m
            begin
              m.level = 60
              m.calcStats
              m.hp = m.totalhp
            rescue Exception
            end
          end
          Coop.log_battle("DEBUG: Gegner-Team auf Lv60 geboostet")
        end
        if tr
          seed = rand(2**30)
          opp_b64 = Base64.strict_encode64(Marshal.dump([tr[0], tr[1], tr[2]]))
          Coop.send_msg({ "t" => "bstart", "to" => p[0], "seed" => seed, "kind" => "coop_trainer", "opp" => opp_b64 })
          Coop.log_battle("coop trainer bstart sent to #{p[0]} seed=#{seed} vs #{tr[0].name}")
          Coop.run_coop_trainer_battle(tr[0], tr[1], tr[2], p[0], seed, 0)
          Coop.coop_battle_cleanup
          $game_temp.in_battle = false
          return true
        end
      rescue Exception => e
        Coop.log_err("coop trainer init", e)
        $coop_sync = nil
      end
    end
  end
  coop_orig_pbTrainerBattle(*args, **kw, &blk)
end

# Empfaenger: pro Frame pruefen, ob eine Kampf-Anfrage vorliegt.
# DEBUG: Die Datei coop_debug_invite.txt im Spielordner loest das Kampf-Gate
# manuell aus (zum Testen ohne Spielstand/Pokemon). Wer sie zuerst loescht,
# wird Initiator. Spaeter entfernbar.
class Scene_Map
  alias coop_invite_update update
  def update
    coop_invite_update
    Coop.poll_incoming_invite
    Coop.run_pending_pvp                                             # PvP-Kampf im Feld starten
    Coop.set_name($Trainer.name) if defined?($Trainer) && $Trainer   # Praesenz-Name
    # Weg B: eingehender Startbefehl -> Kampf starten (Partner = Seite 1)
    b = Coop.take_bstart
    if b
      if b[:kind] == "coop_wild"
        mon = Marshal.load(Base64.decode64(b[:mon]))
        Coop.run_coop_wild_battle(mon, b[:from], b[:seed], 1)
      elsif b[:kind] == "coop_trainer"
        opp, opp_items, opp_party = Marshal.load(Base64.decode64(b[:opp]))
        Coop.run_coop_trainer_battle(opp, opp_items, opp_party, b[:from], b[:seed], 1)
      else
        Coop.run_mirror_battle(b)   # alter M2-Spiegeltest
      end
    end
    if Coop::COOP_DEBUG && File.exist?("coop_debug_invite.txt")
      deleted = false
      begin
        File.delete("coop_debug_invite.txt")
        deleted = true
      rescue Exception
        # andere Instanz war schneller -> wir sind der Empfaenger
      end
      if deleted
        Coop.log_battle("DEBUG trigger -> battle gate")
        Coop.coop_battle_gate
        # Debug-Pfad hat keinen echten Kampf dahinter -> direkt aufraeumen
        Coop.coop_battle_cleanup
      end
    end
    # DEBUG: garantierter Wildkampf (unabhaengig von Encounter-Tabellen).
    # Laeuft durch den normalen Sync-Pfad (Gate -> Anfrage -> bstart -> Spiegel).
    if Coop::COOP_DEBUG && File.exist?("coop_debug_wildbattle.txt")
      deleted = false
      begin
        File.delete("coop_debug_wildbattle.txt")
        deleted = true
      rescue Exception
      end
      if deleted
        Coop.log_battle("DEBUG trigger -> wild battle (force coop)")
        $coop_force_wild_coop = true
        begin
          pbWildBattle(:PIKACHU, 5)
        ensure
          $coop_force_wild_coop = false
        end
      end
    end
    # DEBUG: garantierter TRAINERkampf (erster Trainer aus dem Cache).
    if Coop::COOP_DEBUG && File.exist?("coop_debug_trainerbattle.txt")
      deleted = false
      begin
        File.delete("coop_debug_trainerbattle.txt")
        deleted = true
      rescue Exception
      end
      if deleted
        begin
          ttype = $cache.trainers.keys.first
          tname = $cache.trainers[ttype].keys.first
          tid   = $cache.trainers[ttype][tname].keys.first
          Coop.log_battle("DEBUG trigger -> trainer battle (#{ttype}/#{tname}/#{tid})")
          $coop_debug_boss = true
          begin
            pbTrainerBattle(ttype, tname, "", false, tid)
          ensure
            $coop_debug_boss = false
          end
        rescue Exception => e
          Coop.log_err("debug trainer trigger", e)
        end
      end
    end
  rescue Exception => e
    Coop.log_err("scene_map invite hook", e)
  end
end

Coop.start

rescue Exception => e
  begin
    File.open("coop_error.txt", "a") do |f|
      f.write("#{Time.now.strftime('%H:%M:%S')} LOAD: #{e.class}: #{e.message}\n")
      f.write(e.backtrace.join("\n") + "\n") if e.backtrace
    end
  rescue Exception
  end
end
