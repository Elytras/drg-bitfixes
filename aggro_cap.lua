-- bitfix/aggro_cap.lua
--
-- Raises how many enemies may hold an attack slot on one target at a time, WITHOUT the
-- out-of-bounds read that just bumping the cap gives you.
--
-- UAttackerPositioningComponent hands each attacker a slot index and turns that index into a
-- world position by looking it up in a shared ring table. THREE things cap it, and the obvious
-- one is the lesser one:
--
--   1. MaxAttackers (+0xB4), the component's own int32. The native ctor writes 32.
--   2. The ring tables themselves -- two file-static TArray<FVector> globals the ctor fills
--      with exactly 32 entries each and never rebuilds. 32 is not a tuning number, it is that
--      length. Ground table at 0x1464991B8, flying at 0x1464991C8.
--   3. Target selection. UPlayerAttackPositionComponent::GetScore weights a target by
--      `max(0, 32 - attackers) / 32 * proximity^2`, so at 32 attackers the score hits exactly
--      zero and the target stops attracting anyone new. Raising (1) lifts that function's OWN
--      `MaxAttackers + 1 <= attackers -> not attackable` test, but not this falloff -- so
--      without patching it too, the cap is still 32 in practice.
--
-- Every bounds check in this class -- the three cost calls, the swap loops, and the FINAL
-- position hand-out -- tests MaxAttackers. The ring COUNT (0x1464991C0) is read nowhere
-- outside the ctor, and the slot->position getter indexes the table with no check of its own.
-- So a patch that only raises the 32 in the ctor makes the game read past the end of a
-- 32-element array on the path that decides where an enemy actually walks. That is what makes
-- a naive "increased aggro" patch stutter and misbehave: garbage positions produce garbage
-- costs, the slot assignment never settles, and the horde re-paths every frame.
--
-- Since a byte patch cannot allocate a bigger table, this WRAPS instead: slot 32 reuses ring
-- position 0, slot 33 position 1, and so on. Attackers past the first 32 double up on ring
-- spots rather than reading garbage. The cost function still adds +800 past slot 8 and again
-- past slot 16, so the inner ring stays the preferred one and the assignment still converges.
--
-- Four patches, applied together or not at all:
--
--   ctor       mov [rdi+0B4h], 32  ->  MAX_ATTACKERS
--   getter     the ground slot->position getter (vtable +0x418), masked to the 32-entry table.
--              Every ground path -- all three cost calls AND the final hand-out -- funnels
--              through this one function, so one patch covers all of them.
--   score      the two `mov edi, 32` falloff constants in GetScore (alive branch and downed
--              branch), raised with the cap. The /32 normaliser next to them is left alone: it
--              scales every live and downed target identically, so the relative ordering the
--              selection roll actually uses does not change.
--   flying     GetFlyingAttackerPosition inlines its own indexing of the flying table instead
--              of calling a getter, so there is no single place to mask. Its nine slot bounds
--              are pinned to a literal 32 instead: flying attackers keep vanilla behaviour and
--              can never index that table out of bounds.
--
-- The getter needs 4 bytes it does not have, so its first instruction moves up into the 15
-- bytes of 0xCC alignment padding ahead of the function and the entry becomes a 2-byte jump
-- into it. The entry address itself does not move, which matters because it is only ever
-- reached through a vtable (four classes share it).
--
--   anchor+0   ] 15 bytes of  ->  (3 spare)
--   anchor+3   ] alignment    ->  and    r9d, 31            41 83 E1 1F
--   anchor+7   ] padding      ->  movss  xmm2, [rsp+28h]    F3 0F 10 54 24 28
--   anchor+13  ]              ->  jmp    entry+6            EB 06
--   anchor+15  movss xmm2,..  ->  jmp    anchor+3           EB F2
--   anchor+17                 ->  nop                       0F 1F 40 00   (unreachable)
--   anchor+21  addss xmm2,[rcx+0F8h] ... untouched, same addresses
--
-- ON SURVIVING A GAME UPDATE. There are no image RVAs in this file. The only address it knows
-- at runtime is ctx:address() -- where the pattern matched -- and all 14 sites are signed
-- offsets from that. (The absolute addresses in the comments are navigation aids for opening
-- the exe in a disassembler at the build this was first written against, FSD CL-150580; nothing in
-- the code reads them.) Two things then have to hold, and both fail safely:
--
--   * The pattern must still match. It deliberately covers the 15 bytes of alignment padding
--     ahead of the getter, so a build that leaves fewer bytes there simply stops matching --
--     bitfix logs `scan results: [[]]` in bitfix.txt and this file writes nothing.
--   * The other 13 sites must still sit at the same distance from it. If the game shifts them
--     relative to each other, the expected bytes at those offsets no longer match. EVERY site
--     is read back and checked FIRST; one mismatch prints which site and returns without
--     writing anything at all. There is no partial application -- which matters, because
--     raising the cap without the bounds handling is exactly the bug this file exists to avoid.
--
-- So a stale offset degrades to a silent no-op plus a line in bitfix.txt, never a wild write.
-- If aggro stops feeling different after a game update, read that log.
--
-- Not covered on purpose: UCustomObjectAttackerPositioning / UEscortMuleAttackerPositioning
-- use a DIFFERENT getter (CalculateSlotPosition) over a per-instance, asset-sized
-- AttackerPositions array, also unchecked. Those assets must already author their own
-- MaxAttackers -- if they relied on the ctor's 32 with fewer positions they would be reading
-- out of bounds in vanilla today -- so raising the ctor default should not reach them. If a
-- doretta or a pod ever behaves oddly with this installed, that is the thing to suspect first.
--
-- Compared with the max_attackers.lua example in the bitfix repo, which does two writes: the
-- ctor default (the same byte this file writes) and the two GetScore falloff constants, both
-- to 200. That gets (1) and (3) right and leaves (2) untouched, so slots 32..199 index 12
-- bytes at a time past the end of a 384-byte table -- up to ~2.2 KB of whatever follows it,
-- read as positions. The example is where the GetScore gate came from; this file keeps that
-- and adds the bounds handling.
--
-- Framework users do not need this: SharedLib/game/AggroCap.cpp in the ue-mods framework grows
-- the real tables instead of wrapping, so slots past 32 get their own positions.

--- How many attackers may hold a slot on one target. 32 is vanilla. The slot-assignment pass is
--- O(N^2) per target per tick, so this is not free -- 64 is a comfortable bump, 96 is pushing it.
local MAX_ATTACKERS = 64

--- The one thing resolved by search: the ground ring-position getter, preceded by its alignment
--- padding. Everything else is measured from where this matched.
local PATTERN =
    'CC CC CC CC CC CC CC CC CC CC CC CC CC CC CC ' .. -- 15 bytes of alignment padding
    'F3 0F 10 54 24 28 ' ..                            -- movss  xmm2, [rsp+28h]  (attacker radius)
    'F3 0F 58 91 F8 00 00 00 ' ..                      -- addss  xmm2, [rcx+0F8h] (personal sphere)
    '49 63 C1 ' ..                                     -- movsxd rax, r9d         (the slot)
    '4C 8D 0C 40 ' ..                                  -- lea    r9, [rax+rax*2]  (3 floats/entry)
    '0F 28 C2 ' ..                                     -- movaps xmm0, xmm2
    '48 8B 05'                                         -- mov    rax, [rip+..]    (the ring table)

local function bytes(hex)
    local t = {}
    for h in hex:gmatch('%x%x') do t[#t + 1] = tonumber(h, 16) end
    return t
end

--- { offset-from-the-match, expected, replacement, description }. Same length either way -- every
--- rewrite fits in place, so nothing here shifts an address or a branch. Trailing comments are the
--- absolute addresses on FSD CL-150580, for disassembler navigation only. Offsets re-derived
--- for CL-154534: the flying and score sites moved -0x120, the ctor +0x90, the anchor not at all.
local SITES = {
    -- The ground getter: mask the slot to the 32-entry table (see the diagram above).
    { 0x3, 'CC CC CC CC CC CC CC CC CC CC CC CC',     -- 1415482D4
        '41 83 E1 1F F3 0F 10 54 24 28 EB 06', 'ground getter head' },
    { 0xF, 'F3 0F 10 54 24 28',                       -- 1415482E0
        'EB F2 0F 1F 40 00', 'ground getter entry' },

    -- GetFlyingAttackerPosition: pin its slot bounds to the flying table's real length.
    { 0x96C4, '3B 9F B4 00 00 00',    '81 FB 20 00 00 00',    'flying bound 1' },  -- 141551AB5
    { 0x9862, '8B 87 B4 00 00 00',    'B8 20 00 00 00 90',    'flying bound 2' },  -- 141551C53
    { 0x99F6, '8B 87 B4 00 00 00',    'B8 20 00 00 00 90',    'flying bound 3' },  -- 141551DE7
    { 0x9B96, '44 8B A7 B4 00 00 00', '41 BC 20 00 00 00 90', 'flying bound 4' },  -- 141551F87
    { 0x9C78, '44 8B A7 B4 00 00 00', '41 BC 20 00 00 00 90', 'flying bound 5' },  -- 141552069
    { 0x9D63, '44 8B A7 B4 00 00 00', '41 BC 20 00 00 00 90', 'flying bound 6' },  -- 141552154
    { 0x9E4E, '44 8B A7 B4 00 00 00', '41 BC 20 00 00 00 90', 'flying bound 7' },  -- 14155223F
    { 0x9F73, '3B 9F B4 00 00 00',    '81 FB 20 00 00 00',    'flying bound 8' },  -- 141552364
    { 0xA09E, '3B 9F B4 00 00 00',    '81 FB 20 00 00 00',    'flying bound 9' },  -- 14155248F

    -- GetScore: the target-attractiveness falloff, which otherwise zeroes out at 32 attackers
    -- and quietly re-imposes the cap. %s becomes MAX_ATTACKERS, little-endian.
    { 0xBE97, 'BF 20 00 00 00',       'BF %s',                'score falloff (alive)' }, -- 141554288
    { 0xBEF9, 'BF 20 00 00 00',       'BF %s',                'score falloff (downed)' }, -- 1415542EA

    -- The ctor's default. Behind the anchor, hence the negative offset.
    { -0xDDDF, 'C7 87 B4 00 00 00 20 00 00 00', -- 14153A462
        'C7 87 B4 00 00 00 %s', 'MaxAttackers default' },
}

return {
    aggro_cap = {
        pattern = PATTERN,
        match = function(ctx)
            local cap = MAX_ATTACKERS
            if cap < 32 then cap = 32 elseif cap > 128 then cap = 128 end

            local anchor = ctx:address()
            local plan = {}

            -- Already patched? A second match, or a re-apply, would otherwise trip the byte
            -- checks below and print a scary "unrecognised" line for what is really a no-op.
            -- anchor+3 is 0xCC before the patch and 0x41 after, so it tells the two apart.
            if ctx[anchor + 3] == 0x41 and ctx[anchor + 4] == 0x83 then
                print('aggro_cap: already applied, nothing to do')
                return
            end

            -- Verify EVERY site before writing ANY of them: a half-applied patch would raise
            -- the cap without the bounds handling, which is worse than doing nothing.
            for _, site in ipairs(SITES) do
                local addr, old, hex, what = anchor + site[1], bytes(site[2]), site[3], site[4]

                if hex:find('%%s') then -- little-endian imm32 from MAX_ATTACKERS
                    hex = hex:format(('%02X %02X %02X %02X'):format(
                        cap % 256, math.floor(cap / 256) % 256,
                        math.floor(cap / 65536) % 256, math.floor(cap / 16777216) % 256))
                end
                local new = bytes(hex)

                for i = 1, #old do
                    if ctx[addr + i - 1] ~= old[i] then
                        print(('aggro_cap: %s at %X unrecognised (byte %d), NOTHING written')
                            :format(what, addr, i))
                        return
                    end
                end
                plan[#plan + 1] = { addr = addr, new = new }
            end

            for _, w in ipairs(plan) do
                for i = 1, #w.new do ctx[w.addr + i - 1] = w.new[i] end
            end

            print(('aggro_cap: MaxAttackers 32 -> %d, target-score falloff raised to match, ' ..
                'ground ring index wrapped to 32, flying bounds pinned to 32 ' ..
                '(%d sites patched)'):format(cap, #plan))
        end
    }
}
