--[[
    execInstanceVariable_bypass.lua - bitfix patch for UE 4.27
    ==========================================================
    Allows Kismet InstanceVariable reads through Properties
    owned by a top-level UScriptStruct (ChainDepth == 0) to
    succeed without the fast-IsA class-chain check. All other
    reads keep their original guard behavior unchanged.

    Why: the ReadProperty library emits
        EX_Context(<pun to UObject*>, EX_InstanceVariable(P))
    where P is a Property owned by FScreenMessageString (Key
    @ offset 0). The guard normally rejects struct-owned
    properties because a UScriptStruct is never in a UClass's
    inheritance chain; this patch adds a narrow bypass keyed
    on OwnerChainDepth == 0, which is a natural marker of the
    struct-owned case (no normal BP-compiled InstanceVariable
    ever has ChainDepth-0 owner - the compiler emits
    StructMemberContext for those).

    Blast radius: zero. The `jg` (ChainDepth mismatch) branch
    is left untouched, so any real ChainDepth failure still
    hits the error path as before. Only the second guard
    (`jne` on ClassChain entry compare) is rerouted through
    the cave, and the cave tests eax = OwnerChainDepth: if
    non-zero (i.e. Owner is a real UClass), it falls through
    to the same error target. If zero, only then does it
    treat the read as legitimate.

    Cross-version stability: same signature as the previous
    revision - anchored on UE 4.27-invariant field offsets
    (FField::Owner @ 0x10, UStruct chain fields @ 0x30/0x38,
    FProperty::Offset_Internal @ 0x4C).

    Patch layout:
      Cave at (match - 65), i.e. immediately before the
      function entry in the alignment padding zone:

        85 C9                 test ecx, ecx           ; rcx = OwnerChainDepth
        74 64                 jz  +0x64  -> success (0x?291D)
        E9 8F 00 00 00        jmp +0x8F  -> error   (0x?294D)

    Why rcx and not rax: at the point jne fires, rax was
    just overwritten with the ClassChain array pointer
    (mov rax, [rdx+0x30] at match+29). The OwnerChainDepth
    value that was originally in rax survives in rcx
    (mov rcx, rax at match+26). Testing eax would test the
    low 32 bits of a heap pointer -- always non-zero, cave
    would always fall through to error.

      Single-byte redirect at match+38 (the low byte of the
      `jne rel8` at match+37): original 0x30 -> patched 0x98,
      moving the jne target from the error path (0x?294D) back
      into the cave (0x?28B5).

    Byte map (offsets from match start):
        [ 0..2]  4D 85 C9        test r9, r9              ; if (Property != NULL)
        [ 3]     74              jz  ??                   ; -> error
        [ 4]     ??              (rel8 to error, wildcard)
        [ 5..8]  4D 8B 41 10     mov r8, [r9 + 0x10]      ; FField::Owner container
        [ 9..12] 48 8B 51 10     mov rdx, [rcx + 0x10]    ; Object->ClassPrivate
        [13..16] 49 83 C0 30     add r8, 0x30             ; -> UStruct chain start
        [17..20] 49 63 40 08     movsxd rax, [r8 + 0x08]  ; ChainDepth
        [21..23] 3B 42 38        cmp eax, [rdx + 0x38]    ; against Object->Class->ChainDepth
        [24]     7F              jg  ??                   ; UNTOUCHED (real ChainDepth mismatch)
        [25]     ??              (rel8, wildcard)
        [26..28] 48 8B C8        mov rcx, rax
        [29..32] 48 8B 42 30     mov rax, [rdx + 0x30]    ; ClassChain array
        [33..36] 4C 39 04 C8     cmp [rax + rcx*8], r8
        [37]     75              jne ??  <-- PATCH POINT
        [38]     ??              rel8: 0x30 -> 0x98 (retarget to cave)
        [39..42] 4D 63 41 4C     movsxd r8, [r9 + 0x4C]   ; success path
]]

return {{
    pattern = "4D 85 C9 74 ?? 4D 8B 41 10 48 8B 51 10 49 83 C0 30 49 63 40 08 3B 42 38 7F ?? 48 8B C8 48 8B 42 30 4C 39 04 C8 75 ?? 4D 63 41 4C",

    match = function(ctx)
        local base = ctx:address()

        -- Verify jne is at the expected offset and that its rel8
        -- displacement is still `+0x30` (the classic target-vs-
        -- next-instruction distance to the error path). A change
        -- here means MSVC reordered the check body; better to
        -- no-op than to patch the wrong branch.
        if ctx[base + 37] ~= 0x75 then
            print(string.format(
                "execInstanceVariable_bypass: match+37 = %02X, " ..
                "expected 75 (jne). Skipping patch.",
                ctx[base + 37]))
            return
        end
        if ctx[base + 38] ~= 0x30 then
            print(string.format(
                "execInstanceVariable_bypass: match+38 = %02X, " ..
                "expected 30 (jne rel8 to error). Compiler " ..
                "reshuffled - refresh the anchor.",
                ctx[base + 38]))
            return
        end

        -- Cave lives 65 bytes before the match start (11-byte
        -- alignment padding zone between the previous function
        -- and execInstanceVariable). Confirm it's still CC-fill
        -- before writing - if any real code has moved into it,
        -- the pattern would still match but the cave slot is
        -- gone.
        local cave = base - 65   -- 0x?28B5 relative to match at 0x?28F6
        for off = 0, 8 do
            if ctx[cave + off] ~= 0xCC then
                print(string.format(
                    "execInstanceVariable_bypass: padding at " ..
                    "cave+%d is %02X, expected CC. Skipping.",
                    off, ctx[cave + off]))
                return
            end
        end

        if ctx:index() > 0 then
            print(string.format(
                "execInstanceVariable_bypass: unexpected match " ..
                "at index %d. Only patching index 0.",
                ctx:index()))
            return
        end

        -- Write the cave:
        --   test ecx, ecx           ; rcx = OwnerChainDepth (saved by mov rcx, rax)
        --   jz  +0x64  -> success (match + 39)
        --   jmp +0x8F  -> error   (match + 87)
        ctx[cave + 0] = 0x85    -- test ecx, ecx
        ctx[cave + 1] = 0xC9
        ctx[cave + 2] = 0x74    -- jz rel8
        ctx[cave + 3] = 0x64    -- rel8 = +0x64
        ctx[cave + 4] = 0xE9    -- jmp rel32
        ctx[cave + 5] = 0x8F    -- rel32 = 0x0000008F (little-endian)
        ctx[cave + 6] = 0x00
        ctx[cave + 7] = 0x00
        ctx[cave + 8] = 0x00

        -- Redirect jne from the error path back into the cave.
        -- Original: 75 30 (jne  +0x30 -> 0x?294D)
        -- Patched:  75 98 (jne  -0x68 -> 0x?28B5)
        ctx[base + 38] = 0x98

        print(string.format(
            "execInstanceVariable_bypass: guard bypass installed " ..
            "(match 0x%X, cave 0x%X)", base, cave))
    end
}}
