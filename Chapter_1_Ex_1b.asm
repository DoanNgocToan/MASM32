.386
.model flat, stdcall
option casemap:none

include windows.inc
include kernel32.inc

includelib kernel32.lib

.data
    dwMode dd ?

    hConsoleInput dd ?
    hConsoleOutput dd ?

    lpTempBuffer db 32 dup(?)
    lpFinalBuffer db 32 dup(?)

    nNumOfCharsToRead dd 1
    nNumOfCharsToWrite dd 1
    nLengthOfBuffer db 0

    lpNumOfCharsRead dd ?
    lpNumOfCharsWritten dd ?

    msg db 13,10, "Press any key to exit...", 0
.code
start:
    invoke GetStdHandle, STD_INPUT_HANDLE           
    mov hConsoleInput, eax

    invoke GetStdHandle, STD_OUTPUT_HANDLE
    mov hConsoleOutput, eax

    invoke GetConsoleMode, hConsoleInput, addr dwMode

    mov eax, ENABLE_LINE_INPUT                                      ;Enable RAW_INPUT mode
    not eax
    and dwMode, eax
    
    invoke SetConsoleMode, hConsoleInput, addr dwMode

    call INPUT_HANDLER

    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, nNumOfCharsToWrite, addr lpNumOfCharsWritten, 0
    invoke WriteConsoleA, hConsoleOutput, addr msg, sizeof msg - 1, addr lpNumOfCharsWritten, 0
    invoke CloseHandle, hConsoleOutput

    invoke ReadConsoleA, hConsoleInput, addr lpTempBuffer, 1, addr lpNumOfCharsRead, 0
    invoke CloseHandle, hConsoleInput
    invoke ExitProcess, 0

; >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
; Usage: Handle input in RAW_INPUT mode
; Register Usage: edi, eax
; Return Value: None
; >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
INPUT_HANDLER PROC

    push edi
    push eax

    mov edi, offset lpFinalBuffer
INPUT_LOOP:
    invoke ReadConsoleA, hConsoleInput, addr lpTempBuffer, 1, addr lpNumOfCharsRead, 0
    mov al, byte ptr [lpTempBuffer]

    cmp al, 0DH
    je CHECK_EMPTY

    cmp al, 08H
    je HANDLE_BACKSPACE

    cmp nLengthOfBuffer, 1
    jae INPUT_DONE

    cmp al, "A"
    jb INPUT_LOOP

    cmp al, "Z"
    ja INPUT_LOOP

    mov byte ptr [edi], al
    inc nLengthOfBuffer
    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, 1, addr lpNumOfCharsWritten, 0
    jmp INPUT_LOOP

CHECK_EMPTY:
    cmp nLengthOfBuffer, 0
    je INPUT_LOOP
    invoke ReadConsoleA, hConsoleInput, addr lpTempBuffer, 1, addr lpNumOfCharsRead, 0
    jmp INPUT_DONE

HANDLE_BACKSPACE:
    cmp nLengthOfBuffer, 0
    je INPUT_LOOP

    dec nLengthOfBuffer
    mov byte ptr [edi], 08H
    mov byte ptr [edi + 1], 20H
    mov byte ptr [edi + 2], 08H
    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, 3, addr lpNumOfCharsWritten, 0

    mov byte ptr [edi], 0
    jmp INPUT_LOOP

INPUT_DONE:
    mov byte ptr [edi + 1], 0
    
    or  byte ptr [edi], 20H                                         ; Convert uppercase to lowercase by setting the 6th bit
    
    pop eax
    pop edi
    ret

INPUT_HANDLER endp

end start