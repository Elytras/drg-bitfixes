-- bitfix/critter_cull_crash_fix.lua
--
-- Fixes a host-side crash: ACCESS_VIOLATION reading 0x130, FSD-Win64-Shipping.exe+0x163A159.
-- (The crash reporter blames AAFlyingBug::GetMidZpointFromCielingAndFloor / UDashPoints::
-- TickComponent, but those are just the nearest preceding symbols. Both frames are really
-- UEnemySpawnManager.)
--
-- Nothing ever removes an entry from UEnemySpawnManager::ActiveCritters (+0x170).
-- RegisterSpawnedEnemy adds to it; EnemyDestroyed only unregisters from ActiveEnemies and
-- ActiveSwarmerEnemies, and DestroyAllEnemies only clears those plus CritcalEnemies. Dead
-- critters linger as raw APawn* until GC nulls the slot, so the list fills with nullptr and
-- never shrinks. Once Num hits MaxActiveCritters, TickComponent runs the "cull the critter
-- furthest from any player" selector, which reads Enemy->RootComponent (+0x130) with no null
-- check on Enemy -- it checks RootComponent right after, so the missing one looks like an
-- oversight. Every long mission gets there eventually.
--
-- The fix adds that check and skips the entry. There is no room at the fault site (12 bytes,
-- both checks need 17), but the compiler left 13 bytes of alignment padding contiguous with
-- the loop head, so the head moves up into it:
--
--   A143  ┐ 13 bytes of  ->  mov    rbp, rbx           48 8B EB
--   A146  │ alignment    ->  movaps xmm7, xmm6         0F 28 FE
--   A149  ┘ NOPs         ->  mov    rbx, [rdi]         48 8B 1F
--   A14C                 ->  test   rbx, rbx           48 85 DB
--   A14F                 ->  jnz    .load              75 08
--   A150  mov rbp, rbx   ->  mov    rbx, rbp           48 8B DD
--   A153  movaps ...     ->  jmp    A20E               E9 B5 00 00 00
--   A156  mov rbx,[rdi]  ->  (consumed above)
--   A159  mov rax,[rbx+130h] / test rax,rax / jz A190  -- untouched, same addresses
--
-- plus 4 bytes retargeting the loop's back-edge rel32 from A150 to A143.
--
-- A null entry restores the previous best (what the loop's own `cmovbe rbx, rbp` would do)
-- and jumps to the tail, so it is skipped. Routing it into the RootComponent fallback would
-- be shorter but wrong: that default vector is the world origin, so a null would win the
-- "furthest" contest, be returned as the cull target, and get rejected by the caller --
-- culling would stall forever instead of crashing.
--
-- Both null checks survive; no caps, gameplay values, stack or unwind changes.
--
-- The pattern covers the padding on purpose: a build that leaves fewer than 13 bytes there
-- will not match, and writing nothing is the correct failure mode. The back-edge write is
-- outside the pattern, so it is verified before it is applied.

--- UEnemySpawnManager: select furthest-out-of-range enemy to cull (unnamed in the PDB)
local PATTERN =
    'F3 44 0F 10 16 F3 44 0F 10 5E 04 ' ..   -- movss xmm10,[rsi] / xmm11,[rsi+4]
    'F3 44 0F 10 66 08 F3 44 0F 10 46 0C ' .. -- movss xmm12,[rsi+8] / xmm8,[rsi+0Ch]
    '0F 1F 40 00 66 0F 1F 84 00 00 00 00 00 ' .. -- 13 bytes of alignment padding
    '48 8B EB 0F 28 FE 48 8B 1F ' ..         -- loop head
    '48 8B 83 30 01 00 00 48 85 C0 74 2B'    -- mov rax,[rbx+130h] (faults) / test / jz

local HEAD_OFF, BRANCH_OFF = 0x17, 0xE9      -- pattern -> padding, pattern -> back-edge jnz

local HEAD = {
    0x48, 0x8B, 0xEB,               -- mov    rbp, rbx
    0x0F, 0x28, 0xFE,               -- movaps xmm7, xmm6
    0x48, 0x8B, 0x1F,               -- mov    rbx, [rdi]
    0x48, 0x85, 0xDB,               -- test   rbx, rbx      ; entry null?
    0x75, 0x08,                     -- jnz    .load
    0x48, 0x8B, 0xDD,               -- mov    rbx, rbp      ; restore previous best
    0xE9, 0xB5, 0x00, 0x00, 0x00,   -- jmp    A20E          ; loop tail, entry skipped
}

local BRANCH_OLD = { 0x0F, 0x85, 0x35, 0xFF, 0xFF, 0xFF }   -- jnz A150
local BRANCH_REL = { 0x28, 0xFF, 0xFF, 0xFF }               -- -> A143

return {
    critter_cull_null_entry = {
        pattern = PATTERN,
        match = function(ctx)
            local base, branch = ctx:address(), ctx:address() + BRANCH_OFF

            for i = 1, #BRANCH_OLD do
                if ctx[branch + i - 1] ~= BRANCH_OLD[i] then
                    print(('critter_cull_crash_fix: loop branch at %X unrecognised, skipped')
                        :format(branch))
                    return
                end
            end

            for i = 1, #HEAD do ctx[base + HEAD_OFF + i - 1] = HEAD[i] end
            for i = 1, #BRANCH_REL do ctx[branch + 2 + i - 1] = BRANCH_REL[i] end

            print(('critter_cull_crash_fix: patched loop head at %X'):format(base + HEAD_OFF))
        end
    }
}
