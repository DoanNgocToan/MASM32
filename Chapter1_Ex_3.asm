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
    nNumberOfChars db 0
    bCharacter db 3 dup(0DH, 0AH, 0),0

    lpNumOfCharsRead dd ?
    lpNumOfCharsWritten dd ?

    msg1        db "Ban hay nhap vao 3 chu cai dau: ", 0
    nl          db 13, 10, 0

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

    invoke WriteConsoleA, hConsoleOutput, addr bCharacter, sizeof bCharacter - 1, addr lpNumOfCharsWritten, 0
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
    invoke WriteConsoleA, hConsoleOutput, addr lpTempBuffer, 1, addr lpNumOfCharsWritten, 0
    jmp INPUT_LOOP

CHECK_EMPTY:
    invoke FlushConsoleInputBuffer, hConsoleInput
    cmp nLengthOfBuffer, 0
    je INPUT_LOOP
    jmp INPUT_DONE

HANDLE_BACKSPACE:
    cmp nLengthOfBuffer, 0
    je INPUT_LOOP
    
    mov byte ptr [edi], 08H
    mov byte ptr [edi + 1], 20H
    mov byte ptr [edi + 2], 08H
    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, 3, addr lpNumOfCharsWritten, 0

    mov byte ptr [edi], 0
    dec nLengthOfBuffer
    jmp INPUT_LOOP

INPUT_DONE:
    mov al, byte ptr [edi]
    cmp nNumberOfChars, 1
    jb FIRST_CHAR
    je SECOND_CHAR
    
    mov byte ptr [bCharacter + 8], al
    jmp PROC_DONE

FIRST_CHAR:
    mov byte ptr [bCharacter + 2], al

    jmp NEW_INPUT_LOOP

SECOND_CHAR:
    mov byte ptr [bCharacter + 5], al

NEW_INPUT_LOOP:
    inc nNumberOfChars
    mov nLengthOfBuffer, 0
    mov byte ptr [edi], 0
    jmp INPUT_LOOP

PROC_DONE:
    pop eax
    pop edi
    ret

INPUT_HANDLER endp

end start