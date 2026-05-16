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
    nNumberOfNumbers db 0
    nNumber db 3 dup(0)

    lpNumOfCharsRead dd ?
    lpNumOfCharsWritten dd ?

    msg1        db "?",0
    msg2        db "Tong cua ",0
    msg3        db " va ",0
    msg4        db " la: ",0
    msg5        db ".", 13 , 10, "Press any key to continue...", 0
    msgFail     db 13, 10, "Tong hai so nguyen duong phai be hon 10", 13, 10, "Press any key to retry...", 13, 10, 0
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

    invoke  WriteConsoleA, hConsoleOutput, addr msg2, sizeof msg2 - 1, addr lpNumOfCharsWritten, 0
    invoke WriteConsoleA, hConsoleOutput, addr nNumber[0], 1, addr lpNumOfCharsWritten, 0
    invoke WriteConsoleA, hConsoleOutput, addr msg3, sizeof msg3 - 1, addr lpNumOfCharsWritten, 0
    invoke WriteConsoleA, hConsoleOutput, addr nNumber[1], 1, addr lpNumOfCharsWritten, 0
    invoke WriteConsoleA, hConsoleOutput, addr msg4, sizeof msg4 - 1, addr lpNumOfCharsWritten, 0
    invoke WriteConsoleA, hConsoleOutput, addr nNumber[2], 1, addr lpNumOfCharsWritten, 0
    invoke WriteConsoleA, hConsoleOutput, addr msg5, sizeof msg5 - 1, addr lpNumOfCharsWritten, 0
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
    mov al, [lpTempBuffer]

    cmp al, 0DH
    je CHECK_EMPTY

    cmp al, 08H
    je HANDLE_BACKSPACE

    cmp nLengthOfBuffer, 1
    jae INPUT_DONE

    cmp al, "0"
    jb INPUT_LOOP

    cmp al, "9"
    ja INPUT_LOOP

    mov byte ptr [edi], al
    inc nLengthOfBuffer
    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, 1, addr lpNumOfCharsWritten, 0
    jmp INPUT_LOOP

CHECK_EMPTY:
    ; Remove "LF" character from the input buffer
    invoke FlushConsoleInputBuffer, hConsoleInput

    cmp nLengthOfBuffer, 0
    je INPUT_LOOP
    jmp INPUT_DONE

HANDLE_BACKSPACE:
    cmp nLengthOfBuffer, 0
    je INPUT_LOOP

    ; Move cursor back, print space, move cursor back again to simulate backspace
    mov byte ptr [edi], 08H
    mov byte ptr [edi + 1], 20H
    mov byte ptr [edi + 2], 08H
    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, 3, addr lpNumOfCharsWritten, 0
    mov byte ptr [edi], 0
    dec nLengthOfBuffer
    jmp INPUT_LOOP

INPUT_DONE:
    cmp nNumberOfNumbers, 0
    je FIRST_NUMBER
    mov al, byte ptr [edi]
    mov byte ptr [nNumber + 1], al
    jmp CHECK_SUM

FIRST_NUMBER:
    mov al, byte ptr [edi]
    mov byte ptr [nNumber], al
    inc nNumberOfNumbers
    mov nLengthOfBuffer, 0
    mov byte ptr [edi], 0
    jmp INPUT_LOOP

CHECK_SUM:
    mov al, nNumber[0]
    add al, nNumber[1]
    ; Convert from ASCII to numeric value
    sub al, 30H 
    ; Check if the sum is above 9 
    cmp al, 39H 
    ja SUM_FAIL
    mov byte ptr [nNumber + 2], al
    jmp SUM_SUCCESS

SUM_FAIL:
    invoke WriteConsoleA, hConsoleOutput, addr msgFail, sizeof msgFail - 1, addr lpNumOfCharsWritten, 0
    invoke ReadConsoleA, hConsoleInput, addr lpTempBuffer, 1, addr lpNumOfCharsRead, 0
    invoke WriteConsoleA, hConsoleOutput, addr msg1, sizeof msg1 - 1, addr lpNumOfCharsWritten, 0
    mov nLengthOfBuffer, 0
    mov nNumberOfNumbers, 0
    jmp INPUT_LOOP

SUM_SUCCESS:
    pop eax
    pop edi
    ret

INPUT_HANDLER endp

end start