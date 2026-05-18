; ================================================================
; tiny_peb.asm — PEB Walking để gọi MessageBoxA + ExitProcess
; Hoàn toàn không dùng Import Table
;
; Build:
;   ml.exe  /c /coff /Fo tiny_peb.obj tiny_peb.asm
;   link.exe /SUBSYSTEM:WINDOWS /ENTRY:main /NODEFAULTLIB tiny_peb.obj
;
; Kết quả: PE file có ImportDirectory = {0, 0}
;          NumberOfRvaAndSizes có thể đặt = 0
; ================================================================
.386
.model flat, stdcall
option casemap:none

; ----------------------------------------------------------------
; Data — chỉ chứa các chuỗi dùng để lookup tên hàm/DLL
; (merge vào .text sau bằng /MERGE:.data=.text trong link.exe)
; ----------------------------------------------------------------
.data
    s_user32       db "user32.dll",   0
    s_LoadLibraryA db "LoadLibraryA", 0
    s_ExitProcess  db "ExitProcess",  0
    s_MessageBoxA  db "MessageBoxA",  0

.code

; ================================================================
; PROC find_export
; Tìm địa chỉ hàm trong Export Table của một DLL đã load
;
; Tham số (stdcall):
;   hModule  — base address của DLL (DWORD)
;   szFunc   — tên hàm cần tìm, ANSI null-terminated (DWORD ptr)
;
; Trả về: EAX = địa chỉ hàm  |  0 nếu không tìm thấy
;
; Sơ đồ Export Directory (IMAGE_EXPORT_DIRECTORY):
;   +18h  NumberOfNames       — số hàm có tên
;   +1Ch  AddressOfFunctions  — RVA[] địa chỉ các hàm
;   +20h  AddressOfNames      — RVA[] tên các hàm
;   +24h  AddressOfNameOrdinals — WORD[] chỉ số vào Functions[]
;
; Thuật toán:
;   Duyệt Names[i] cho đến khi khớp szFunc
;   → ordinal = NameOrdinals[i]
;   → addr    = base + Functions[ordinal]
; ================================================================
find_export proc uses ebx ecx edx esi edi,
                 hModule :DWORD,
                 szFunc  :DWORD
    local pExpDir :DWORD        ; cache địa chỉ Export Directory

    mov   ebx, hModule

    ; ── Bước 1: Đến PE header ──────────────────────────────────
    ; [base + 0x3C] = e_lfanew = offset từ đầu file đến "PE\0\0"
    mov   eax, [ebx+3Ch]        ; e_lfanew
    add   eax, ebx              ; EAX = PE header

    ; ── Bước 2: Lấy Export Directory ──────────────────────────
    ; DataDirectory[0].VirtualAddress nằm tại PE+78h
    ; (PE+18h = Optional Header, +60h trong OptHdr = DataDir[0])
    mov   eax, [eax+78h]        ; Export RVA
    test  eax, eax
    jz    fe_fail               ; DLL không có export table
    add   eax, ebx              ; RVA → địa chỉ ảo
    mov   pExpDir, eax          ; lưu lại để dùng khi match

    ; ── Bước 3: Chuẩn bị vòng lặp ─────────────────────────────
    mov   ecx, [eax+18h]        ; NumberOfNames (loop counter)
    test  ecx, ecx
    jz    fe_fail

    mov   edx, [eax+20h]        ; AddressOfNames RVA
    add   edx, ebx              ; EDX = DWORD[] của RVA các tên
    xor   esi, esi              ; ESI = index i = 0

    ; ── Bước 4: Duyệt từng tên ────────────────────────────────
fe_loop:
    ; Lấy địa chỉ chuỗi tên thứ i
    mov   eax, [edx+esi*4]      ; Names[i] = RVA của tên hàm
    add   eax, ebx              ; → địa chỉ thật

    ; So sánh byte-by-byte với szFunc
    push  ecx                   ; giữ counter
    push  edx                   ; giữ con trỏ mảng
    push  esi                   ; giữ index i
    mov   edi, eax              ; EDI = tên hàm trong DLL
    mov   esi, szFunc           ; ESI = tên hàm cần tìm

fe_cmp:
    mov   al, [esi]
    cmp   al, [edi]
    jne   fe_no_match
    test  al, al                ; nếu cả hai = '\0' → khớp hoàn toàn
    jz    fe_matched
    inc   esi
    inc   edi
    jmp   fe_cmp

fe_matched:
    pop   esi                   ; ESI = index i (cần cho tra ordinal)
    pop   edx
    pop   ecx

    mov   eax, pExpDir          ; Lấy lại Export Directory

    ; Tra ordinal: NameOrdinals[i] → chỉ số vào Functions[]
    ; (Lưu ý: ordinal này KHÔNG trừ Base, dùng trực tiếp)
    mov   edi, [eax+24h]        ; AddressOfNameOrdinals RVA
    add   edi, ebx              ; EDI = WORD[]
    movzx ecx, word ptr [edi+esi*2]  ; ordinal = NameOrdinals[i]

    ; Lấy RVA hàm → địa chỉ thật
    mov   edi, [eax+1Ch]        ; AddressOfFunctions RVA
    add   edi, ebx              ; EDI = DWORD[]
    mov   eax, [edi+ecx*4]      ; Functions[ordinal] = function RVA
    add   eax, ebx              ; → địa chỉ hàm thật
    ret                         ; EAX = địa chỉ hàm ✓

fe_no_match:
    pop   esi                   ; khôi phục index
    pop   edx
    pop   ecx
    inc   esi                   ; i++
    dec   ecx
    jnz   fe_loop               ; còn tên chưa kiểm tra

fe_fail:
    xor   eax, eax              ; không tìm thấy → EAX = 0
    ret

find_export endp


; ================================================================
; PROC get_kernel32
; Tìm base address của kernel32.dll bằng cách duyệt PEB
;
; Trả về: EAX = DllBase của kernel32.dll  |  0 nếu thất bại
;
; Cấu trúc PEB (x86):
;   FS:[30h]              → PEB*
;   PEB  + 0Ch            → PEB_LDR_DATA*
;   LDR  + 14h            → InMemoryOrderModuleList (LIST_ENTRY head)
;
; Mỗi node trong list là LDR_DATA_TABLE_ENTRY.InMemoryOrderLinks
; Vì truy cập qua InMemoryOrderLinks (tại offset +8 trong entry),
; các offset phải trừ 8 so với đầu entry:
;   DllBase     = entry+18h → từ InMemOrderLinks = +10h
;   DllName.Len = entry+2Ch → từ InMemOrderLinks = +24h  (WORD, bytes)
;   DllName.Buf = entry+30h → từ InMemOrderLinks = +28h  (PWSTR unicode)
;
; Điều kiện nhận dạng kernel32.dll (Unicode, case-insensitive):
;   Length == 0x18 (24 bytes = 12 ký tự × 2)
;   char[0] ∈ {'k','K'}   → (WORD[buf+0] | 0x20) == 0x6B
;   char[6]='3', char[7]='2' → DWORD[buf+12] == 0x00320033
;
;   Lý do đủ duy nhất: chỉ kernel32.dll có length=24 VÀ "k" đầu
;   VÀ "32" ở đúng vị trí đó trong số các DLL thường gặp.
; ================================================================
get_kernel32 proc uses ebx ecx esi edi

    ; ── Lấy PEB qua FS register ───────────────────────────────
    ; FS:[0x30] là cách chuẩn trên x86 Windows (từ NT3.1 đến nay)
    assume fs:nothing
    mov   eax, fs:[30h]         ; EAX = PEB*
    assume fs:error
    mov   eax, [eax+0Ch]        ; EAX = PEB.Ldr (PEB_LDR_DATA*)

    ; ── Xác định sentinel của danh sách ────────────────────────
    ; InMemoryOrderModuleList tại Ldr+14h là LIST_ENTRY head (sentinel)
    ; Khi Flink quay về địa chỉ này → đã duyệt hết vòng
    lea   ebx, [eax+14h]        ; EBX = &sentinel
    mov   esi, [ebx]            ; ESI = Flink = InMemOrderLinks entry đầu

    ; ── Duyệt circular linked list ─────────────────────────────
k32_loop:
    cmp   esi, ebx              ; ESI == sentinel → hết list
    je    k32_fail

    ; Kiểm tra DllBase != 0 (entry hợp lệ)
    mov   eax, [esi+10h]        ; DllBase
    test  eax, eax
    jz    k32_next

    ; Kiểm tra Length == 24 (0x18) bytes Unicode
    ; Loại ngay: ntdll(18 bytes), kernel.exe(không load), v.v.
    movzx ecx, word ptr [esi+24h]   ; BaseDllName.Length
    cmp   ecx, 18h
    jne   k32_next

    ; Lấy buffer Unicode
    mov   edi, [esi+28h]            ; BaseDllName.Buffer (PWSTR)

    ; Kiểm tra char[0]: 'k'=6Bh hoặc 'K'=4Bh
    ; OR 0x20 chuyển uppercase → lowercase (đúng cho ký tự ASCII)
    movzx eax, word ptr [edi]       ; Unicode WORD của char đầu
    or    ax, 20h
    cmp   ax, 6Bh                   ; 'k' ?
    jne   k32_next

    ; Kiểm tra DWORD tại buf+12 chứa Unicode "32"
    ; Memory: 33 00 32 00 → DWORD little-endian = 0x00320033
    ;         '3'    '2'
    cmp   dword ptr [edi+12], 00320033h
    jne   k32_next

    ; ✓ kernel32.dll tìm thấy!
    mov   eax, [esi+10h]            ; EAX = DllBase
    ret

k32_next:
    mov   esi, [esi]                ; Flink → module tiếp theo
    jmp   k32_loop

k32_fail:
    xor   eax, eax
    ret

get_kernel32 endp


; ================================================================
; PROC main — Entry Point
; ================================================================
main proc
    local h32   :DWORD      ; kernel32 base
    local hU32  :DWORD      ; user32 base (từ LoadLibraryA)
    local pLib  :DWORD      ; LoadLibraryA
    local pExit :DWORD      ; ExitProcess
    local pMbox :DWORD      ; MessageBoxA

    ; ── Zero-init locals (MASM không tự làm) ───────────────────
    xor   eax, eax
    mov   h32,  eax
    mov   hU32, eax
    mov   pLib, eax
    mov   pExit,eax
    mov   pMbox,eax

    ; ── 1. Tìm kernel32 qua PEB ────────────────────────────────
    call  get_kernel32
    test  eax, eax
    jz    done
    mov   h32, eax

    ; ── 2. Tìm LoadLibraryA trong kernel32 ─────────────────────
    ; Cần LoadLibraryA để load user32.dll vì user32 KHÔNG được
    ; loader tự load (không có entry trong Import Table)
    push  offset s_LoadLibraryA     ; arg2: szFunc
    push  h32                       ; arg1: hModule
    call  find_export               ; → EAX = &LoadLibraryA
    test  eax, eax
    jz    done
    mov   pLib, eax

    ; ── 3. Tìm ExitProcess trong kernel32 ──────────────────────
    push  offset s_ExitProcess
    push  h32
    call  find_export
    test  eax, eax
    jz    done
    mov   pExit, eax

    ; ── 4. Load user32.dll vào process ─────────────────────────
    push  offset s_user32
    mov   eax, pLib
    call  eax                       ; LoadLibraryA("user32.dll")
    test  eax, eax                  ; EAX = hUser32 (= DllBase)
    jz    done
    mov   hU32, eax

    ; ── 5. Tìm MessageBoxA trong user32 ────────────────────────
    push  offset s_MessageBoxA
    push  hU32
    call  find_export
    test  eax, eax
    jz    done
    mov   pMbox, eax

    ; ── 6. Gọi MessageBoxA(NULL, NULL, NULL, MB_OK) ─────────────
    push  0                         ; uType    = MB_OK
    push  0                         ; lpCaption= NULL (chuỗi rỗng)
    push  0                         ; lpText   = NULL (chuỗi rỗng)
    push  0                         ; hWnd     = NULL
    mov   eax, pMbox
    call  eax

    ; ── 7. Thoát ───────────────────────────────────────────────
done:
    mov   eax, pExit
    test  eax, eax
    jz    no_exit
    push  0
    call  eax                       ; ExitProcess(0) — không return

no_exit:
    xor   eax, eax
    ret                             ; Fallback: trả về OS loader

main endp

end main