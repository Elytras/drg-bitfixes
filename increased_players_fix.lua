-- DRG: for lobbies a player-count mod has raised above four players
--
-- The game updates its telemetry state (mission_id, mission_type, mp_state, num_players, character,
-- player_level, season_level) from one function that reads the lobby and the local player's save data.
-- This patch is for player-count mods that crash in it. Telemetry is all it feeds: nothing in play reads
-- these values back.
--
-- The fix makes that function return at once (its first byte becomes `ret`). The telemetry state is then
-- never updated; the game is otherwise unchanged.
--
-- The pattern is the function's entry: mov rax,rsp; mov [rax+8],rcx; push rbp; push <reg>;
-- lea rbp,[rax-N]; sub rsp,M; cmp qword [rcx+30h],0; mov <reg>,rcx; je. The pushed register and the frame
-- sizes are left open: CL-165596 grew the frame (0x198 -> 0x238) and saves rbx where CL-158958 saved rdi.
-- It matches once in either build; a build where it matches nothing writes nothing.
--
-- INSTALL: drop this file in  <Deep Rock Galactic>/FSD/Binaries/Win64/bitfix/
-- CHECK:   bitfix.txt should show one "increased_players_fix: telemetry state updater disabled" line.
return {
  {
    pattern = '48 8b c4 48 89 48 08 55 ?? 48 8d a8 ?? ?? ff ff 48 81 ec ?? ?? 00 00 48 83 79 30 00 48 8b ?? 0f 84',
    match = function(ctx)
      ctx[ctx:address()] = 0xC3
      print(('increased_players_fix: telemetry state updater disabled at %X'):format(ctx:address()))
    end
  }
}
