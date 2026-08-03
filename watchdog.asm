; ================================================================
; watchdog.asm  —  Primary Watchdog (MASM32)
;
; Build:
;   ml /c /coff watchdog.asm
;   link /subsystem:windows /entry:WatchdogProc watchdog.obj ^
;        kernel32.lib advapi32.lib
;
; MUST match main.asm:
;   MUTEX_XOR_KEY  — both binaries must use the same constant
;
; Registry values written by setup_wmi.ps1 before first run:
;   HKLM\...\FontDPI  FontPath   = absolute path to main.exe
;   HKLM\...\FontDPI  FontSmooth = absolute path to watchdog.exe (self)
;
; Logic per poll cycle (every WD_POLL_MS ms):
;   1. Recompute mutex name for current time window
;   2. OpenMutexA(szMainMutexBuf)
;      ├─ Success → main alive → CloseHandle → sleep
;      └─ Failure → main dead  → RestartMainProc → sleep
; ================================================================

.686
.model flat, stdcall
option casemap:none

include \masm32\include\windows.inc
include \masm32\include\kernel32.inc
include \masm32\include\advapi32.inc

includelib \masm32\lib\kernel32.lib
includelib \masm32\lib\advapi32.lib

; ── Constants (MUST match main.asm) ─────────────────────────────
MUTEX_XOR_KEY   EQU 0DEAD1337h
MUTEX_PREFIX    EQU 7            ; len("Global\")
WD_POLL_MS      EQU 30000        ; poll every 30 seconds
MUTEX_ALL_ACCESS EQU 1F0001h
REGKEY_ACCESS   EQU 000F003Fh   ; KEY_ALL_ACCESS

; ================================================================
.data

; ── Main process mutex name buffer ───────────────────────────────
; "Global\" (7 bytes) + 8 uppercase hex chars + null
; The hex portion is recomputed by CalcMutexNames on every poll.
; MUST produce the same string as CalcMutexName in main.asm.
szMainMutexBuf  db "Global\", 8 dup(' '), 0    ; 16 bytes

; ── Watchdog self-guard mutex ────────────────────────────────────
; Same base formula + 'W' suffix to distinguish from main mutex.
; Prevents duplicate watchdog instances.
; Layout: "Global\" + 8 hex chars + 'W' + null  (17 bytes)
szWDMutexBuf    db "Global\", 8 dup(' '), "W", 0
hWDMutex        dd 0

; ── Registry ─────────────────────────────────────────────────────
szRegPath       db "SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontDPI", 0
szRegValPath    db "FontPath", 0     ; main.exe absolute path
hRegKey         dd 0
dwRegDisp       dd 0
dwPathSz        dd 260

; ── Buffers ──────────────────────────────────────────────────────
szMainPath      db 260 dup(0)        ; main.exe path (from Registry)
szHexChars      db "0123456789ABCDEF"
sysTime         SYSTEMTIME <>

; ── STARTUPINFO (68 bytes) for CreateProcessA ───────────────────
; Field offsets:
;   0: cb(4)  4:lpReserved(4)  8:lpDesktop(4)  12:lpTitle(4)
;  16: dwX(4) 20:dwY(4)       24:dwXSize(4)    28:dwYSize(4)
;  32: dwXCountChars(4)       36:dwYCountChars(4)
;  40: dwFillAttribute(4)     44:dwFlags(4)
;  48: wShowWindow(2)         50:cbReserved2(2)
;  52: lpReserved2(4)         56:hStdIn(4)
;  60: hStdOut(4)             64:hStdErr(4)
stStartup       db 68 dup(0)
stProcInfo      db 16 dup(0)         ; PROCESS_INFORMATION

; ================================================================
.code

; ════════════════════════════════════════════════════════════════
; UTILITY (duplicated from main.asm — separate compilation unit)
; ════════════════════════════════════════════════════════════════

ZeroMem PROC USES eax ecx edi, pBuf:DWORD, nSize:DWORD
    cld
    xor  eax, eax
    mov  edi, pBuf
    mov  ecx, nSize
    rep  stosb
    ret
ZeroMem ENDP

; ── DwordToHex8 ──────────────────────────────────────────────────
; Writes 8 uppercase hex chars at pDst. Does NOT write a null
; terminator — the caller is responsible for the trailing byte.
; This avoids overwriting a suffix character ('W') in szWDMutexBuf.
; ─────────────────────────────────────────────────────────────────
DwordToHex8 PROC USES eax ecx edx edi, dwVal:DWORD, pDst:DWORD
    mov  edi, pDst
    mov  eax, dwVal
    mov  ecx, 8
D2H_Loop:
    rol  eax, 4
    mov  edx, eax
    and  edx, 0Fh
    movzx edx, byte ptr szHexChars[edx]
    mov  byte ptr [edi], dl
    inc  edi
    dec  ecx
    jnz  D2H_Loop
    ; Deliberately NO null write here — see header comment
    ret
DwordToHex8 ENDP

; ════════════════════════════════════════════════════════════════
; CalcMutexNames
; Computes the current mutex name for BOTH buffers using the same
; formula as main.asm:  hex( (wHour/3) XOR MUTEX_XOR_KEY )
;
; After this call:
;   szMainMutexBuf = "Global\XXXXXXXX\0"       (16 bytes)
;   szWDMutexBuf   = "Global\XXXXXXXXW\0"      (17 bytes)
;
; Key design: copy the 8 hex bytes from szMainMutexBuf into
; szWDMutexBuf instead of calling DwordToHex8 twice. This avoids
; DwordToHex8 ever writing into the 'W' or null position of the
; WD buffer.
; ════════════════════════════════════════════════════════════════
CalcMutexNames PROC USES eax ecx edx esi edi
    invoke GetSystemTime, addr sysTime
    movzx eax, sysTime.wHour       ; 0..23
    mov   ecx, 3
    xor   edx, edx
    div   ecx                      ; eax = hour_slot (0..7)
    xor   eax, MUTEX_XOR_KEY       ; same XOR as main.asm

    ; ── Step 1: write 8 hex chars into szMainMutexBuf+7 ────────
    invoke DwordToHex8, eax, addr szMainMutexBuf + MUTEX_PREFIX
    ; Add null terminator for szMainMutexBuf (offset 15)
    mov byte ptr szMainMutexBuf + MUTEX_PREFIX + 8, 0

    ; ── Step 2: copy same 8 hex chars into szWDMutexBuf+7 ──────
    ; 'W' at offset 15 and null at offset 16 are preserved.
    cld
    lea  esi, szMainMutexBuf + MUTEX_PREFIX
    lea  edi, szWDMutexBuf  + MUTEX_PREFIX
    mov  ecx, 8
    rep  movsb
    ; [edi] now points at offset 15 — the 'W' was not touched ✓
    ret
CalcMutexNames ENDP

; ════════════════════════════════════════════════════════════════
; ReadMainPath
; Reads the main.exe absolute path from Registry into szMainPath.
; Returns: eax = 1 on success, 0 on failure.
; ════════════════════════════════════════════════════════════════
ReadMainPath PROC USES ebx ecx edx
    mov  dwPathSz, 260

    invoke RegCreateKeyExA,
           HKEY_LOCAL_MACHINE, addr szRegPath,
           0, NULL,
           REG_OPTION_NON_VOLATILE, REGKEY_ACCESS,
           NULL, addr hRegKey, addr dwRegDisp
    test eax, eax
    jnz  RMP_Fail

    invoke RegQueryValueExA,
           hRegKey, addr szRegValPath,
           NULL, NULL,
           addr szMainPath, addr dwPathSz
    invoke RegCloseKey, hRegKey

    test eax, eax
    jnz  RMP_Fail
    mov  eax, 1
    ret
RMP_Fail:
    xor  eax, eax
    ret
ReadMainPath ENDP

; ════════════════════════════════════════════════════════════════
; RestartMainProc
; Spawns szMainPath as a completely detached hidden process.
;
; Flags: CREATE_NO_WINDOW (0x08000000) | DETACHED_PROCESS (0x00000008)
;   = 0x08000008
; Combined with STARTF_USESHOWWINDOW + SW_HIDE in STARTUPINFO,
; the spawned process has no console and no visible window.
;
; Handle bookkeeping: both process and thread handles are closed
; immediately — we do not track or wait for main.exe here. The
; Named Mutex is how we detect its presence next poll cycle.
; ════════════════════════════════════════════════════════════════
RestartMainProc PROC USES eax
    ; Zero both structs; then set required fields
    invoke ZeroMem, addr stStartup,  68
    invoke ZeroMem, addr stProcInfo, 16

    mov dword ptr stStartup,    68   ; cb = sizeof(STARTUPINFO) = 68
    mov dword ptr stStartup+44,  1   ; dwFlags = STARTF_USESHOWWINDOW
    ; wShowWindow at offset 48 remains 0 = SW_HIDE (already zero)

    invoke CreateProcessA,
           addr szMainPath, NULL,    ; application path, no separate cmdline
           NULL, NULL,               ; default security for process/thread
           FALSE,                    ; do not inherit handles
           08000008h,                ; CREATE_NO_WINDOW | DETACHED_PROCESS
           NULL,                     ; inherit environment
           NULL,                     ; inherit current directory
           addr stStartup,
           addr stProcInfo
    test eax, eax
    jz   RMP_Done

    ; Close handles — we don't wait for or monitor this process
    mov  eax, dword ptr stProcInfo      ; PROCESS_INFORMATION.hProcess
    invoke CloseHandle, eax
    mov  eax, dword ptr stProcInfo + 4  ; PROCESS_INFORMATION.hThread
    invoke CloseHandle, eax

RMP_Done:
    ret
RestartMainProc ENDP

; ════════════════════════════════════════════════════════════════
; ENTRY POINT
; ════════════════════════════════════════════════════════════════
WatchdogProc PROC

    ; ── 1. Compute both mutex names for current time window ─────
    call CalcMutexNames

    ; ── 2. Guard: abort if another watchdog instance is running ─
    ; Uses szWDMutexBuf ("Global\XXXXXXXXW") as unique identifier.
    invoke OpenMutexA, MUTEX_ALL_ACCESS, FALSE, addr szWDMutexBuf
    test eax, eax
    jnz  WD_Dup

    ; ── 3. Claim watchdog self-guard mutex ───────────────────────
    invoke CreateMutexA, NULL, TRUE, addr szWDMutexBuf
    mov  hWDMutex, eax

    ; ── 4. Locate main.exe (path stored in Registry by setup) ───
    call ReadMainPath
    test eax, eax
    jz   WD_Exit      ; no path configured → nothing to watch

    ; ════════════════════════════════════════════════════════════
    ; MAIN POLL LOOP
    ;
    ; Every WD_POLL_MS (30 s):
    ;   a. Recompute mutex names — window may have changed
    ;   b. Try OpenMutexA on main process mutex
    ;   c. If handle returned  → process alive → close handle
    ;   d. If NULL returned    → process dead  → restart
    ; ════════════════════════════════════════════════════════════
WD_Loop:

    ; Recompute — necessary because mutex name changes every 3 h
    call CalcMutexNames

    invoke OpenMutexA, MUTEX_ALL_ACCESS, FALSE, addr szMainMutexBuf
    test eax, eax
    jz   WD_Dead

    ; Main alive: close the handle we just opened and go back to sleep.
    ; Important: do NOT hold the handle — holding it would interfere
    ; with main.exe's CloseHandle(hMutex) on graceful exit.
    invoke CloseHandle, eax
    jmp  WD_Sleep

WD_Dead:
    ; Brief pause before spawn: if something is actively killing
    ; main.exe in a tight loop, this reduces re-spawn frequency.
    invoke Sleep, 500
    call  RestartMainProc

WD_Sleep:
    invoke Sleep, WD_POLL_MS
    jmp   WD_Loop

WD_Exit:
WD_Dup:
    invoke ExitProcess, 0

WatchdogProc ENDP

END WatchdogProc
; ================================================================
; END OF FILE
; ================================================================
