# DRG bitfixes

Byte patches for Deep Rock Galactic, written for [bitfix](https://github.com/trumank/bitfix): fixes for
crashes and limits in the game itself, for players who run no other mod framework.

## Install

1. Install bitfix (its proxy DLL next to `FSD-Win64-Shipping.exe`, see its README).
2. Drop the `.lua` files you want into `<Deep Rock Galactic>/FSD/Binaries/Win64/bitfix/`.
3. Start the game and read `<Deep Rock Galactic>/FSD/Binaries/Win64/bitfix.txt`: each patch prints what
   it changed, or why it changed nothing.

Every patch checks the bytes it is about to change before it writes them. After a game update that moves
the code, a patch no longer matches and writes nothing: the game then behaves as stock, never half-patched.
Each file's header says what it fixes, how, and which lines `bitfix.txt` should show.

## Patches

| File | What it fixes |
| --- | --- |
| `terrain_memory_crash_fix.lua` | **Terrain Memory Crash Fix.** "FSDVirtualMem::Commit failed with error: 487" (or "ExpandingArray out of range (MAXSIZE 67108864)") during heavy terrain destruction, such as chains of exploders. The terrain's vertex and plane pools get a bigger reserve (`POOL_MIB` at the top of the file, default 1920, stock 960) and their cleanup gets a bigger per-frame budget, so it finishes. |
| `carve_crash_fix.lua` | **Carve Crash Fix.** An access violation (at 0x440, 0x630 or 0x3C0) while terrain is carved: a cell that is all rock or all air has no planes, and three routines read that empty plane list. |
| `chunk_spawn_crash_fix.lua` | **Chunk Spawn Crash Fix.** "access violation (write of 0x248)" in `AResourceChunk::SpawnChunk` when a resource chunk fails to spawn (often a mod pointing at a chunk class that is not installed). |
| `critter_cull_crash_fix.lua` | **Critter Cull Crash Fix.** A host-side crash, ACCESS_VIOLATION reading 0x130, blamed on flying critters. |
| `aggro_cap.lua` | **Aggro Cap.** Raises how many enemies may attack one target at once, without the out-of-bounds read that a plain cap bump gives. |

## Status against the current game build

Checked on 2026-11-11 against FSD CL-158958 by searching the current `FSD-Win64-Shipping.exe` for each
patch's pattern and checking every byte each patch verifies before it writes: all five apply.
`aggro_cap.lua` now finds its sites by scanning near its match instead of at fixed distances, so it
survives the code moving between builds (fixed distances are what broke it on CL-158958).
