# Rejuvenation Co-op -- Multiplayer-Eintrag im Pausemenue + linkes Untermenue-Panel.
# Nutzt Rejuvenations offizielle MenuHandlers-Registry (siehe MenuHandlers.rb).
# Gehoert nach patch/Mods/ (laeuft nach der Engine).
#
# "Multiplayer" im Pausemenue oeffnet ein eigenes Kommando-Fenster LINKS
# (im selben Stil wie das Hauptmenue rechts) mit PvP & Trading.
# PvP/Trading sind vorerst Platzhalter -- die Logik folgt spaeter.

begin
  # Linkes Untermenue-Panel als eigene Szenen-Methode (spiegelt pbShowCommands,
  # aber positioniert das Fenster links statt rechts).
  class PokemonMenu_Scene
    def pbShowCoopSubmenu(commands)
      ret = -1
      win = Window_CommandPokemon.new(commands, tts: false)
      win.viewport = @viewport
      win.resizeToFit(commands)
      win.x = 0
      win.y = 0
      win.index = 0
      win.visible = true
      lastread = nil
      loop do
        win.update
        if defined?(tts) && commands[win.index] != lastread
          tts(commands[win.index], true) rescue nil
          lastread = commands[win.index]
        end
        Graphics.update
        Input.update
        pbUpdateSceneMap
        if Input.trigger?(Input::B)
          ret = -1
          break
        elsif Input.trigger?(Input::C)
          ret = win.index
          break
        end
      end
      win.dispose
      return ret
    end
  end

  MenuHandlers.add(:pause_menu, :coop_multiplayer,
    name:  proc { _INTL("Multiplayer") },
    order: 15,   # gleich nach Pokédex (10), vor Pokémon (20)
    effect: proc { |scene, screen|
      menu_result = nil
      loop do
        cmd = scene.pbShowCoopSubmenu([_INTL("PvP"), _INTL("Trading"), _INTL("Zurück")])
        case cmd
        when 0   # PvP -> Untermenue Request / Receive / Statistik
          if defined?(Coop)
            loop do
              w, l = (Coop.pvp_stats rescue [0, 0])
              pcmd = scene.pbShowCoopSubmenu([
                _INTL("Herausfordern"), _INTL("Anfragen"),
                _INTL("Bilanz: {1}S / {2}N", w, l), _INTL("Zurück")])
              case pcmd
              when 0 then Coop.pvp_request_flow
              when 1 then Coop.pvp_receive_flow
              else break
              end
              # Steht ein Kampf an -> Pausemenue schliessen, Kampf laeuft im Feld.
              if Coop.pvp_pending?
                menu_result = :break
                break
              end
            end
          else
            Kernel.pbMessage(_INTL("PvP nicht verfuegbar."))
          end
        when 1   # Trading -> Untermenue Request / Receive
          if defined?(Coop)
            loop do
              tcmd = scene.pbShowCoopSubmenu([_INTL("Request"), _INTL("Receive"), _INTL("Zurück")])
              case tcmd
              when 0 then Coop.trade_request_flow
              when 1 then Coop.trade_receive_flow
              else break
              end
            end
          else
            Kernel.pbMessage(_INTL("Trading nicht verfuegbar."))
          end
        else
          break   # Zurück / B -> zurueck ins Pausemenue
        end
        break if menu_result
      end
      next menu_result   # :break schliesst das Pausemenue -> PvP-Kampf laeuft im Feld
    }
  )
rescue Exception => e
  begin
    File.open("coop_error.txt", "a") do |f|
      f.write("#{Time.now.strftime('%H:%M:%S')} coop_menu load: #{e.class}: #{e.message}\n")
      f.write(e.backtrace.join("\n") + "\n") if e.backtrace
    end
  rescue Exception
  end
end
