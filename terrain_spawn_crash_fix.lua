-- DRG CL-166125: the terrain-point sampler crashes on a chunk triangle group whose index array is missing
--
-- When something wants N free spots on the cave surface (enemy spawns, through
-- UTerrainPlacementComponent::IsTerrainSuitableAndFreeOfBlockers), sub_141577D90 walks one CSG
-- chunk's triangle groups and picks random points on them, weighted by area. Each group says how many
-- entries it has, and the entries live in a pool array looked up by a handle. When that handle is
-- the "none" value (0x7FFFFFFF), the lookup gives a null base, but the group still claims entries.
-- The loop then reads [null + 2 + 4*i + 1]: "access violation (read of 0x3)" at FSD+0x1578230, on
-- the game thread, mid-mission. Seen in a player's report, 2026-11-23 (docs/re/CRASH_REPORTS.md).
--
-- The same loop is compiled into three sibling samplers (sub_141577D90, sub_141578C50,
-- sub_14158FCA0 on CL-166125), so the pattern matches three times and each copy gets its own guard.
--
-- The fix skips such a group. Right before the loop head MSVC left 12 bytes of alignment padding,
-- which run once on loop entry, with r10 already holding the array base. They become
-- `test r10, r10; jz <next group>; nop`. <next group> is the game's own "this group is done" code:
-- it reloads the group counter into r10 (which held the base) and steps to the next group, and the
-- loop's existing early-out jge lands 5 bytes past it. That jge is how we find it. The
-- caller already copes with fewer candidate points than it wanted.
--
-- Every write is inside the matched pattern; the bytes at <next group> are checked before anything
-- is written. The pattern covers the padding, so a later build without it (or a second run) is a no-op.
--
-- INSTALL: drop this file in  <Deep Rock Galactic>/FSD/Binaries/Win64/bitfix/
-- CHECK:   <Deep Rock Galactic>/FSD/Binaries/Win64/bitfix.txt should show three "guarded" lines.
--          Anything that does not check out prints why and writes nothing.
--
-- Check with tools/bitfix/test_csg_sampler_guard.py.

local JGE  = 0x1A   -- jge rel32: the "no entries in this group" early-out
local PAD  = 0x3A   -- 12 bytes of alignment padding before the loop head
local NEXT_GROUP_BYTES = { 0x4C, 0x8B, 0x54, 0x24, -1,     -- mov r10, [rsp+XXh]  (group counter; 60h or 68h)
                           0x49, 0x83, 0xC3, 0x1C }        -- add r11, 1Ch        (the jge lands here)

local function rd32(ctx, a)
    return ctx[a] | (ctx[a + 1] << 8) | (ctx[a + 2] << 16) | (ctx[a + 3] << 24)
end

local function guard(ctx)
    local at = ctx:address()
    local rel = rd32(ctx, at + JGE + 2)
    if rel >= 0x80000000 then rel = rel - 0x100000000 end
    local nextGroup = at + JGE + 6 + rel - 5
    for i = 1, #NEXT_GROUP_BYTES do
        if NEXT_GROUP_BYTES[i] >= 0 and ctx[nextGroup + i - 1] ~= NEXT_GROUP_BYTES[i] then
            print(string.format("csg_sampler: next-group code at %X is not where it was - NOT patching", nextGroup))
            return
        end
    end
    -- test r10, r10 ; jz rel32 <nextGroup> ; nop dword ptr [rax]
    local jz = (nextGroup - (at + PAD + 9)) & 0xFFFFFFFF
    local code = { 0x4D, 0x85, 0xD2, 0x0F, 0x84,
                   jz & 0xFF, (jz >> 8) & 0xFF, (jz >> 16) & 0xFF, (jz >> 24) & 0xFF,
                   0x0F, 0x1F, 0x00 }
    for i = 1, #code do ctx[at + PAD + i - 1] = code[i] end
    print(string.format("csg_sampler: guarded at %X", at + PAD))
end

return {
    { pattern = '49 63 53 EC 41 8B 43 F8 45 8B 43 E8 03 C2 4C 63 C8 89 95 ?? ?? ?? ?? 49 3B D1 0F 8D ?? ?? ?? ?? '
             .. '4C 8B 55 ?? 4C 2B CA 4C 89 4D ?? 49 8B C9 49 8D 42 02 48 8D 04 90 48 89 45 ?? '
             .. '0F 1F 40 00 0F 1F 84 00 00 00 00 00 0F B6 58 01 0F B6 00', match = guard },
}
