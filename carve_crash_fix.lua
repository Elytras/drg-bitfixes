-- Carve Crash Fix
--
-- Fixes an access violation while terrain is being carved.
--
-- Terrain is a grid of cells, and each cell stores a small BSP tree of planes marking where
-- solid meets empty inside it. A cell that is entirely rock or entirely air needs no planes at
-- all, and the game describes that correctly: pointer NULL, count 0.
--
-- The routines that walk those trees are handed both the pointer and the count, 
-- So obviously neither of 3 ever read it (it's immideately discarded from register). 
-- So when the plane asks for itself to be walked to determine what it is made of off, it crashes on invalid addresses.
-- The faulting addresses: 0x440, 0x630, and 0x3C0 are exactly 16x a plane index, with no base added.
--
-- Each patch tests the pointer and, when it is null, takes the same branch the routine would
-- have taken had it read the count of zero. When the pointer is valid nothing changes - the
-- original instruction still runs at its original address.
--
-- ACSGBuilderBase::ApplyNodeToVolWithCuts hands its tree walkers a NULL plane-array base together
-- with a count of ZERO whenever a subcell is uniform. Three walkers dereference that base BEFORE
-- they look at the count, so one root cause shows up as three faulting addresses:
--
--     +0x440   the three-branch walker    (index 68)
--     +0x630   the fourth-branch walker   (index 99)
--     +0x3C0   CSGLookupPoint             (index 60)   -- two identical copies of it
--
-- Every fix is the same shape: test the base, and if it is null take the branch the walker would
-- have taken anyway once it read the count of zero. On a non-null base the original instruction
-- runs at its original address and nothing else changes.
--
-- NOTHING ABOUT PLACEMENT OR DISTANCE IS HARDCODED. An earlier version baked an absolute arena
-- address and pre-computed every branch displacement, which is unsafe across game updates: a
-- short pattern can still match at a different address, the site bytes still compare equal, and
-- the patch then writes jumps computed for the old layout. Here every address and displacement is
-- derived at runtime from the matched address, and each patch verifies the bytes at BOTH the site
-- and the branch target it is about to jump to before it writes anything.
--
-- The thunks live in the section-alignment slack at the end of .text - mapped and executable
-- because it is part of .text's last page, and unused. It is located by scanning forward for 256
-- consecutive zero bytes; no zero run that long exists anywhere inside .text itself, so the
-- signature is unambiguous. Allocation is self-sequencing: a written thunk is no longer zero, so
-- the next patch lands after it.
--
-- INSTALL: drop this file in  <Deep Rock Galactic>/FSD/Binaries/Win64/bitfix/
-- CHECK:   <Deep Rock Galactic>/FSD/Binaries/Win64/bitfix.txt should show four "guarded" lines.
--          Anything that does not check out prints why and writes nothing.
--
-- STATUS: the reverse engineering is verified and the equivalent guards have hours of runtime as
-- MinHook detours with no recurrence of any of the three faults. THIS FILE has not itself been
-- run under bitfix yet. How often ordinary play reaches the crash is also unmeasured - it was
-- found by generating worlds in a tight loop, which no player does.
--
-- Regenerate with tools/bitfix/make_csg_patch.py; check with tools/bitfix/test_csg_patch.py.

local SLACK_SIG   = 256          -- consecutive zero bytes that identify the end-of-.text slack
local SLACK_SCAN  = 0x4000000    -- give up looking that far past the match
local SLACK_STRIDE = 128         -- <= SLACK_SIG/2, so no qualifying run can be stepped over

local function u32(d)
    if d < 0 then d = d + 0x100000000 end
    return d % 256, math.floor(d / 256) % 256, math.floor(d / 65536) % 256,
           math.floor(d / 16777216) % 256
end

local function bytes_are(ctx, addr, want)
    for i = 1, #want do
        if ctx[addr + i - 1] ~= want[i] then return false, i - 1 end
    end
    return true
end

local function zeros(ctx, addr, n)
    for i = 0, n - 1 do
        if ctx[addr + i] ~= 0 then return false end
    end
    return true
end

-- Walk forward from `from` for a run of SLACK_SIG zeros, then back up to its first byte.
local function find_slack(ctx, from)
    local p = from
    while p - from < SLACK_SCAN do
        if ctx[p] == 0 and zeros(ctx, p, SLACK_SIG) then
            while ctx[p - 1] == 0 do p = p - 1 end
            return p
        end
        p = p + SLACK_STRIDE
    end
    return nil
end

-- First run of `n` zeros at or after `base`, bounded so a full slack cannot walk into .rdata.
local function alloc(ctx, base, n)
    local p = base
    while p - base < 0x1000 do
        if zeros(ctx, p, n) then return p end
        p = p + 1
    end
    return nil
end

local function apply(ctx, p)
    local at   = ctx:address()
    local site = at + p.site_off

    local okb, bad = bytes_are(ctx, site, p.orig)
    if not okb then
        print(string.format("%s: site %X byte +%d is %02X, expected %02X - NOT patching",
                            p.name, site, bad, ctx[site + bad], p.orig[bad + 1]))
        return
    end

    -- The offset to the continue target is only as good as what is actually there. Check it, so a
    -- build that kept the site but moved the loop cannot get a jump into the middle of something.
    local cont
    if p.cont_off then
        cont = site + p.cont_off
        local okc, badc = bytes_are(ctx, cont, p.cont_sig)
        if not okc then
            print(string.format("%s: continue target %X byte +%d is %02X, expected %02X "
                                .. "- the function moved under us, NOT patching",
                                p.name, cont, badc, ctx[cont + badc], p.cont_sig[badc + 1]))
            return
        end
    end

    local slack = find_slack(ctx, at)
    if not slack then
        print(p.name .. ": no end-of-.text slack found - NOT patching")
        return
    end
    local thunk = alloc(ctx, slack, #p.thunk)
    if not thunk then
        print(p.name .. ": slack at " .. string.format("%X", slack) .. " is full - NOT patching")
        return
    end

    -- Build the thunk with real displacements, then the site's jump to it.
    local code = {}
    for i = 1, #p.thunk do code[i] = p.thunk[i] end
    for i = 1, #p.relocs do
        local r = p.relocs[i]
        local target = (r.to == "cont") and cont or (site + p.stub_len)
        local a, b, c, d = u32(target - (thunk + r.off + 4))
        code[r.off + 1], code[r.off + 2], code[r.off + 3], code[r.off + 4] = a, b, c, d
    end
    local a, b, c, d = u32(thunk - (site + 5))
    local stub = { 0xE9, a, b, c, d }
    for i = 6, p.stub_len do stub[i] = 0x90 end

    for i = 1, #code do ctx[thunk + i - 1] = code[i] end
    for i = 1, #stub do ctx[site + i - 1] = stub[i] end
    print(string.format("%s: guarded, site %X -> thunk %X (%d bytes)", p.name, site, thunk, #code))
end


-- CSGHalfEdge tree walker (three-branch), fault +0x440
local walkerA = {
    name = "walkerA", site_off = 0, stub_len = 6,
    orig = {0x81, 0xE7, 0xFF, 0xFF, 0xFF, 0x3F},
    cont_off = 0x2be, cont_sig = {0x8B, 0x95, 0x88, 0x07, 0x00, 0x00, 0x85, 0xD2, 0x7E, 0x13},
    thunk = {0x48, 0x83, 0x7C, 0x24, 0x70, 0x00, 0x0F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x81, 0xE7, 0xFF, 0xFF, 0xFF, 0x3F, 0xE9, 0x00, 0x00, 0x00, 0x00},
    relocs = {{off = 8, to = "cont"}, {off = 19, to = "back"}},
}

-- CSGHalfEdge tree walker (fourth-branch), fault +0x630
local walkerB = {
    name = "walkerB", site_off = 0, stub_len = 7,
    orig = {0x41, 0x81, 0xE7, 0xFF, 0xFF, 0xFF, 0x3F},
    cont_off = 0x1a5, cont_sig = {0x8B, 0x8D, 0x68, 0x07, 0x00, 0x00, 0x85, 0xC9, 0x7E, 0x11},
    thunk = {0x48, 0x85, 0xD2, 0x0F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x41, 0x81, 0xE7, 0xFF, 0xFF, 0xFF, 0x3F, 0xE9, 0x00, 0x00, 0x00, 0x00},
    relocs = {{off = 5, to = "cont"}, {off = 17, to = "back"}},
}

-- CSGLookupPoint, fault +0x3C0
local lookupA = {
    name = "lookupA", site_off = 2, stub_len = 7,
    orig = {0x40, 0x57, 0x8B, 0xC1, 0x48, 0x8B, 0xFA},
    cont_off = nil, cont_sig = nil,
    thunk = {0x48, 0x85, 0xD2, 0x75, 0x07, 0x85, 0xC9, 0x79, 0x03, 0x33, 0xC0, 0xC3, 0x40, 0x57, 0x8B, 0xC1, 0x48, 0x8B, 0xFA, 0xE9, 0x00, 0x00, 0x00, 0x00},
    relocs = {{off = 20, to = "back"}},
}

-- CSGLookupPoint, fault +0x3C0
local lookupB = {
    name = "lookupB", site_off = 2, stub_len = 7,
    orig = {0x40, 0x57, 0x8B, 0xC1, 0x48, 0x8B, 0xFA},
    cont_off = nil, cont_sig = nil,
    thunk = {0x48, 0x85, 0xD2, 0x75, 0x07, 0x85, 0xC9, 0x79, 0x03, 0x33, 0xC0, 0xC3, 0x40, 0x57, 0x8B, 0xC1, 0x48, 0x8B, 0xFA, 0xE9, 0x00, 0x00, 0x00, 0x00},
    relocs = {{off = 20, to = "back"}},
}

-- One pattern matches both copies of CSGLookupPoint. Pick which one this match is by the first
-- byte where they differ - order-independent, which ctx:index() is not.
local function fix_lookup(ctx)
    local b = ctx[ctx:address() + 133]
    if b == 0x8B then
        apply(ctx, lookupA)
    elseif b == 0x81 then
        apply(ctx, lookupB)
    else
        print(string.format("lookup: byte at +133 is %02X, matches neither known copy "
                            .. "- NOT patching", b))
    end
end

return {
    { pattern = '81 E7 FF FF FF 3F 48 C1 E7 04 48 03 7C 24 70 4C 8B 0F', match = function(ctx) apply(ctx, walkerA) end },
    { pattern = '41 81 E7 FF FF FF 3F 49 C1 E7 04 4C 03 FA', match = function(ctx) apply(ctx, walkerB) end },
    { pattern = 'CC CC 40 57 8B C1 48 8B FA C1 E8 1F 84 C0 74 75 45 0F BF 50 04 45 0F BF 58 02 48 89 5C 24 10 41', match = fix_lookup },
}
