-- DRG: "FSDVirtualMem::Commit failed with error: 487" on a terrain carve thread
--
-- The terrain keeps every mesh vertex in one pool (pool-VertexPositions, 6 bytes a vertex) inside a
-- fixed 960 MiB address reservation, and every BSP plane in another (pool-Planes, 16 bytes a plane,
-- 1 GiB). A chunk that is re-meshed abandons its old entries and appends new ones; a compactor
-- reclaims the abandoned space. In a mission that compactor only runs on frames with no terrain op in
-- flight or queued, and moves at most 500 ranges / 5000 entries per such frame, so a pass rarely
-- finishes under heavy digging. The vertex pool then walks off the end of its reservation and the
-- game dies with error 487; with only the vertex pool raised, the planes pool is next ("ExpandingArray
-- out of range (MAXSIZE 67108864)"). (Full trace: ue-mods WORLDGEN_JOURNAL.md, 2026-11-09/10.)
--
-- For both pools this file does two things, each independent and each harmless on its own:
--
--   1. Bigger pools (POOL_MIB below): each pool's size limit (MAXSIZE) at both of its checks, and the
--      address reservation behind it, grow with POOL_MIB. This buys time, it is not the fix.
--   2. Bigger compactor budgets (RAISE_BUDGET): each pool's per-frame caps go from 500 ranges / 5000
--      entries to 16384 ranges and about 6 MB moved per frame. The compactor still runs only where the
--      game already runs it, on the game thread, on a frame with no op in flight, so it never overlaps
--      a carve; passes just finish. This is the fix: in a test dig the stock pool kept climbing while
--      the patched one stayed flat.
--
-- Every write is either inside a matched pattern or at a fixed offset that is read and checked first.
-- A pattern that no longer matches (a game update) writes nothing, and the game behaves as stock.
--
-- INSTALL: drop this file in  <Deep Rock Galactic>/FSD/Binaries/Win64/bitfix/
-- CHECK:   bitfix.txt should show four "vertex_pool:" and four "planes_pool:" lines (reserve, grow
--          limit, compactor limit, compactor budget).
--
-- Check with tools/bitfix/test_csg_vertex_pool.py.

------------------------------------------------------------------------------------------------------
-- SETTING: the vertex pool's size in MiB. Stock is 960; 1920 doubles it; the most it takes is 2048.
--   The planes pool grows by the same factor, up to just under 2 GiB (about 2x).
--   Raising it costs address space only: memory is committed as a pool really fills, so a mission
--   that never needed more than stock uses exactly what stock does. Values below 960, above the
--   maximum, or not a whole number are refused: bitfix.txt says so and nothing at all is patched.
local POOL_MIB = 1920
------------------------------------------------------------------------------------------------------

local RAISE_BUDGET = true

-- Limits are whole numbers of the arrays' 0x40000-entry grow blocks; a reserve is the entry size times
-- the limit plus one spare 64 KiB block (the allocator commits one block past the end of a range), so
-- it lands on the 64 KiB granularity by construction. Every reserve stays below 2^31 bytes.
-- ponytail: the 2^31 cap keeps any 32-bit byte offset positive; the code paths read so far are 64-bit,
-- so more likely works too, but nobody has traced every reader of the pools.
local CAP = 0x7FFFFFFF
local BAD_SETTING
local function limits(oldMax, elem, mib)
    local max = oldMax * mib // 960 // 0x40000 * 0x40000
    while elem * max + 0x10000 > CAP do max = max - 0x40000 end
    if max <= oldMax then return oldMax, elem * oldMax end      -- stock size: leave it as it ships
    return max, elem * max + 0x10000
end

local mib = math.tointeger(POOL_MIB)
if not mib then
    BAD_SETTING = "POOL_MIB is not a whole number"
elseif mib < 960 then
    BAD_SETTING = string.format("POOL_MIB %d is below stock 960", mib)
elseif 6 * (mib * 0x100000 // 6 // 0x40000 * 0x40000) + 0x10000 > CAP then
    BAD_SETTING = string.format("POOL_MIB %d is above the maximum 2048", mib)
end

-- Each pool: its stock limit and reserve, the patched ones, and where its compactor's budget sits
-- relative to its compactor pattern (test rXb,rXb; jne; cmp ebp,1F4h; jge; cmp r14d,1388h; jge).
local POOLS = {
    vertex = { tag = "vertex_pool", elem = 6, oldMax = 0x0A000000, oldReserve = 0x3C000000,
               budgetVerts = 0x100000, budgetAt = -0x1E6,
               budgetBytes = { 0x45, 0x84, 0xE4, 0x75, 0x19, 0x81, 0xFD, 0xF4, 0x01, 0x00, 0x00, 0x0F, 0x8D,
                               -1, -1, -1, -1, 0x41, 0x81, 0xFE, 0x88, 0x13, 0x00, 0x00, 0x0F, 0x8D } },
    planes = { tag = "planes_pool", elem = 16, oldMax = 0x04000000, oldReserve = 0x40000000,
               budgetVerts = 0x60000, budgetAt = -0x1FB,
               budgetBytes = { 0x45, 0x84, 0xFF, 0x75, 0x19, 0x81, 0xFD, 0xF4, 0x01, 0x00, 0x00, 0x0F, 0x8D,
                               -1, -1, -1, -1, 0x41, 0x81, 0xFE, 0x88, 0x13, 0x00, 0x00, 0x0F, 0x8D } },
}
if not BAD_SETTING then
    for _, p in pairs(POOLS) do p.newMax, p.newReserve = limits(p.oldMax, p.elem, mib) end
end

local OLD_RANGES, NEW_RANGES = 0x1F4, 0x4000
local OLD_ENTRIES = 0x1388
local BUDGET_RANGES = 0x07                -- imm32 offsets inside budgetBytes
local BUDGET_ENTRIES = 0x14

local function rd32(ctx, a)
    return ctx[a] | (ctx[a + 1] << 8) | (ctx[a + 2] << 16) | (ctx[a + 3] << 24)
end

-- Rewrite one imm32, but only if it still holds the value we expect.
local function set32(ctx, a, old, new, tag, what)
    if rd32(ctx, a) ~= old then
        print(string.format("%s: %s at %X is %X, not %X - NOT patching", tag, what, a, rd32(ctx, a), old))
        return false
    end
    for i = 0, 3 do ctx[a + i] = (new >> (8 * i)) & 0xFF end
    return true
end

-- A bad setting patches nothing; say so once.
local told = false
local function refused()
    if BAD_SETTING and not told then
        print("vertex_pool: " .. BAD_SETTING .. " - NOT patching anything")
        told = true
    end
    return BAD_SETTING ~= nil
end

local function reserve(p, immAt)
    return function(ctx)
        if refused() then return end
        local at = ctx:address()
        if set32(ctx, at + immAt, p.oldReserve, p.newReserve, p.tag, "reserve") then
            print(string.format("%s: reserve %X -> %X at %X", p.tag, p.oldReserve, p.newReserve, at))
        end
    end
end

local function grow(p, cmpAt, msgAt)
    return function(ctx)
        if refused() then return end
        local at = ctx:address()
        if set32(ctx, at + cmpAt, p.oldMax, p.newMax, p.tag, "grow limit") then
            set32(ctx, at + msgAt, p.oldMax, p.newMax, p.tag, "grow message")
            print(string.format("%s: grow limit %X -> %X at %X", p.tag, p.oldMax, p.newMax, at))
        end
    end
end

local function compactor(p, cmpAt, msgAt)
    return function(ctx)
        if refused() then return end
        local at = ctx:address()
        if set32(ctx, at + cmpAt, p.oldMax, p.newMax, p.tag, "compactor limit") then
            set32(ctx, at + msgAt, p.oldMax, p.newMax, p.tag, "compactor message")
            print(string.format("%s: compactor limit %X -> %X at %X", p.tag, p.oldMax, p.newMax, at))
        end
        if not RAISE_BUDGET then return end
        local b = at + p.budgetAt
        for i = 1, #p.budgetBytes do
            if p.budgetBytes[i] >= 0 and ctx[b + i - 1] ~= p.budgetBytes[i] then
                print(string.format("%s: compactor budget at %X is not where it was - NOT patching", p.tag, b))
                return
            end
        end
        set32(ctx, b + BUDGET_RANGES, OLD_RANGES, NEW_RANGES, p.tag, "budget ranges")
        set32(ctx, b + BUDGET_ENTRIES, OLD_ENTRIES, p.budgetVerts, p.tag, "budget entries")
        print(string.format("%s: compactor budget %d/%d -> %d/%d at %X",
                            p.tag, OLD_RANGES, OLD_ENTRIES, NEW_RANGES, p.budgetVerts, b))
    end
end

local V, P = POOLS.vertex, POOLS.planes
return {
    -- DeepCSGPoolSet ctor, pool-VertexPositions: lea rcx,[rbx+3A0h]; mov edx,3C000000h; ...
    { pattern = '48 8D 8B A0 03 00 00 BA 00 00 00 3C 48 8B 00 4C 89 61 20', match = reserve(V, 0x08) },
    -- ExpandingArray<VertexPositions>::Grow: cmp edx,0A000000h; jl; lea rax,[rip]; mov [rsp+28h],0A000000h
    { pattern = '8B DA 48 8B F9 81 FA 00 00 00 0A 7C 37 48 8D 05 ?? ?? ?? ?? C7 44 24 28 00 00 00 0A',
      match = grow(V, 0x07, 0x18) },
    -- DeepArrayPool<VertexPositions>::Compact: cmp esi,r10d; jle; cmp esi,0A000000h; jl; ...
    { pattern = '41 3B F2 0F 8E ?? ?? ?? ?? 81 FE 00 00 00 0A 7C 3B 48 8D 05 ?? ?? ?? ?? C7 44 24 28 00 00 00 0A',
      match = compactor(V, 0x0B, 0x1C) },

    -- DeepCSGPoolSet ctor, pool-Planes: lea rcx,[rbx+10h]; xor r12d,r12d; mov edx,40000000h; ...
    { pattern = '48 8D 4B 10 45 33 E4 BA 00 00 00 40 48 8B 00 4C 89 61 20', match = reserve(P, 0x08) },
    -- ExpandingArray<FDeepCSGPlane>::Grow: the same shape as two other grows, told apart by its
    -- 16-byte stride (shl rdx,4) after the commit size is rounded
    { pattern = '8B DA 48 8B F9 81 FA 00 00 00 04 7C 37 48 8D 05 ?? ?? ?? ?? C7 44 24 28 00 00 00 04 '
             .. '41 B9 01 00 00 00 48 89 44 24 20 4C 8D 05 ?? ?? ?? ?? BA 84 00 00 00 48 8D 0D ?? ?? ?? ?? '
             .. 'E8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 8D 83 FF FF 03 00 99 81 E2 FF FF 03 00 8D 1C 02 48 63 57 0C '
             .. '81 E3 00 00 FC FF 8B CB 2B CA 48 C1 E2 04',
      match = grow(P, 0x07, 0x18) },
    -- DeepArrayPool<FDeepCSGPlane>::Compact: movsxd rsi,[rdi+0FCh] (pool-Faces' has a plain mov); ...
    { pattern = '48 63 B7 FC 00 00 00 3B 77 08 0F 8E ?? ?? ?? ?? 44 8B 57 0C 41 3B F2 7E ?? 81 FE 00 00 00 04 '
             .. '7C 3B 48 8D 05 ?? ?? ?? ?? C7 44 24 28 00 00 00 04',
      match = compactor(P, 0x1B, 0x2C) },
}
