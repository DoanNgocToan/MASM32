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
    
    nLengthOfBuffer db 0

    lpNumOfCharsRead dd ?
    lpNumOfCharsWritten dd ?

    msg1        db "Ban hay nhap vao 1 chu so hex: ", 0
    msg2        db 13, 10, "Dang thap phan cua no la: ", 0

.code
start:

    invoke GetStdHandle, STD_INPUT_HANDLE
    mov hConsoleInput, eax

    invoke GetStdHandle, STD_OUTPUT_HANDLE
    mov hConsoleOutput, eax

    ;Enable RAW_INPUT mode
    invoke GetConsoleMode, hConsoleInput, addr dwMode
    mov eax, ENABLE_LINE_INPUT
    not eax
    and dwMode, eax
    invoke SetConsoleMode, hConsoleInput, addr dwMode

    invoke WriteConsoleA, hConsoleOutput, addr msg1, sizeof msg1 - 1, addr lpNumOfCharsWritten, 0

    call INPUT_HANDLER

    invoke WriteConsoleA, hConsoleOutput, addr msg2, sizeof msg2 - 1, addr lpNumOfCharsWritten, 0
    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, sizeof lpFinalBuffer - 1, addr lpNumOfCharsWritten, 0
    invoke CloseHandle, hConsoleOutput

    invoke ReadConsoleA, hConsoleInput, addr lpTempBuffer, 1, addr lpNumOfCharsRead, 0
    invoke CloseHandle, hConsoleInput
    invoke ExitProcess, 0

INPUT_HANDLER proc
    push edi
    push eax

    mov edi, offset lpFinalBuffer
INPUT_LOOP:
    invoke ReadConsoleA, hConsoleInput, addr lpTempBuffer, 1, addr lpNumOfCharsRead, 0
    mov al, [lpTempBuffer]

    cmp al, 0DH 
    je CHECK_EMPTY

    cmp al, 08H
    je HANDLE_BACKSPACE

    cmp nLengthOfBuffer, 1
    jae INPUT_DONE

    cmp al, "A"
    jb INPUT_LOOP

    cmp al, "F"
    ja INPUT_LOOP
    inc nLengthOfBuffer
    mov [edi], al
    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, 1, addr lpNumOfCharsWritten, 0
    jmp INPUT_LOOP

CHECK_EMPTY:
    invoke FlushConsoleInputBuffer, hConsoleInput
    cmp nLengthOfBuffer, 0
    je INPUT_LOOP
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
    sub byte ptr [edi], 17
    mov al, byte ptr [edi]

    mov byte ptr [edi], "1"
    mov byte ptr [edi + 1], al
    mov byte ptr [edi + 2], 0
    pop eax
    pop edi
    ret

INPUT_HANDLER endp

end start