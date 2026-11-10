-- DRG: AResourceChunk::SpawnChunk crashes when the chunk fails to spawn
--
-- SpawnChunk loads the resource's chunk class, spawns it deferred, and then, whether or not that
-- worked, writes the chunk's value into the actor (+0x248) and calls FinishSpawning on it. When
-- the class does not load (a mod points a resource at a chunk class that is not installed) or the
-- spawn returns nothing, that actor is null: "access violation (write of 0x248)" in
-- AResourceChunk::SpawnChunk, typically while a mission generates. Generation's caller already
-- handles a null return, so the fix makes the failure paths return null.
--
-- Both failure paths meet at `xor ebx, ebx` just before the write. That becomes a short jump back
-- to the class-check failure block, whose spawn-parameters setup is dead code (nothing reads it),
-- and the block's first four bytes become `xor eax, eax; jmp <epilogue>`. The success path jumps
-- past both and is untouched. Every write is inside the matched pattern; the only byte read
-- outside it, the epilogue the jump lands on, is checked before anything is written.
--
-- INSTALL: drop this file in  <Deep Rock Galactic>/FSD/Binaries/Win64/bitfix/
-- CHECK:   <Deep Rock Galactic>/FSD/Binaries/Win64/bitfix.txt should show one "guarded" line.
--          Anything that does not check out prints why and writes nothing.
--
-- Check with tools/bitfix/test_spawn_chunk_guard.py.

local FAIL_BLOCK = 0x00   -- lea rcx, [rsp+20h]: the class-check failure block
local JOIN       = 0x1D   -- xor ebx, ebx: where every failure path meets
local EPILOGUE   = 0x3D   -- mov rcx, [rsp+80h]: the stack-cookie check, after `mov rax, rbx`
local EPILOGUE_BYTES = { 0x48, 0x8B, 0x8C, 0x24, 0x80, 0x00, 0x00, 0x00 }

local function guard(ctx)
    local at = ctx:address()
    for i = 1, #EPILOGUE_BYTES do
        if ctx[at + EPILOGUE + i - 1] ~= EPILOGUE_BYTES[i] then
            print(string.format("spawn_chunk: epilogue at %X is not where it was - NOT patching",
                                at + EPILOGUE))
            return
        end
    end
    -- xor eax, eax; jmp short <epilogue>
    local rel = EPILOGUE - (FAIL_BLOCK + 4)
    ctx[at + FAIL_BLOCK], ctx[at + FAIL_BLOCK + 1] = 0x31, 0xC0
    ctx[at + FAIL_BLOCK + 2], ctx[at + FAIL_BLOCK + 3] = 0xEB, rel
    -- jmp short <fail block>
    ctx[at + JOIN], ctx[at + JOIN + 1] = 0xEB, (FAIL_BLOCK - (JOIN + 2)) % 256
    print(string.format("spawn_chunk: guarded at %X", at))
end

return {
    { pattern = '48 8D 4C 24 20 E8 ?? ?? ?? ?? 80 4C 24 49 04 0F 57 C0 F3 0F 7F 44 24 30 C6 44 24 48 00 '
             .. '33 DB 45 33 C9 F3 0F 11 B3 48 02 00 00', match = guard },
}
