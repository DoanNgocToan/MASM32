.386
.model flat, stdcall
option casemap:none

include windows.inc
include kernel32.inc
includelib kernel32.lib

.data
    screenInfo CONSOLE_SCREEN_BUFFER_INFO <>
    dwMode dd ?

    hConsoleInput dd ?
    hConsoleOutput dd ?

    lpTempBuffer db 256 dup(0)
    lpFinalBuffer db 256 dup(0)

    nNumberOfCharsToRead dd 1
    nNumberOfCharsToWrite dd 1

    nLengthOfBuffer db 0

    lpNumberOfCharsRead dd ?
    lpNumberOfCharsWritten dd ?

    msg1 db 13, 10, "Press any key to exit...", 0

.code
start:
    invoke GetStdHandle, STD_OUTPUT_HANDLE
    mov hConsoleOutput, eax                                                                                             ; Get the handle for standard output

    invoke GetStdHandle, STD_INPUT_HANDLE                                                                               ; Get the handle for standard input
    mov hConsoleInput, eax

    invoke GetConsoleMode, hConsoleInput, addr dwMode
    mov eax, ENABLE_LINE_INPUT
    not eax
    and dwMode, eax                                                                                                     ; Disable echo input and line input modes
    or dwMode, ENABLE_ECHO_INPUT
    invoke SetConsoleMode, hConsoleInput, dwMode

    call INPUT_HANDLER                                                                                                  ; Call the input handler to process the input character

    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, nNumberOfCharsToWrite, addr lpNumberOfCharsWritten, 0     ; Display the character entered by the user
    invoke WriteConsoleA, hConsoleOutput, addr msg1, sizeof msg1 - 1, addr lpNumberOfCharsWritten, 0                    ; Display the exit message    
    invoke CloseHandle, hConsoleOutput                                                                                  ; Close the handle for standard output  

    invoke ReadConsoleA, hConsoleInput, addr lpTempBuffer, 1, addr lpNumberOfCharsRead, 0                               ; Wait for user input before closing the console
    invoke CloseHandle, hConsoleInput                                                                                   ; Close the handle for standard input               
    invoke ExitProcess, 0

; >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
; Usage: Copy characters from lpTempBuffer to lpFinalBuffer
; Register Usage:
;   ESI - Source index (points to lpTempBuffer)
;   EDI - Destination index (points to lpFinalBuffer)
;   ECX - Counter for the number of characters to copy
;   EAX - Temporary register for character manipulation
; Return Value: None 
; >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

INPUT_HANDLER proc
    push edi
    push eax

    mov edi, offset lpFinalBuffer

INPUT_LOOP:
    invoke ReadConsoleA, hConsoleInput, addr lpTempBuffer, 1, addr lpNumberOfCharsRead, 0                                ; Read a character from the console input into lpBuffer
    mov al, lpTempBuffer[0]

    cmp al, 0dh
    je CHECK_EMPTY

    cmp al, 08h
    je HANDLE_BACKSPACE

    cmp al, 1Fh
    jbe INPUT_LOOP

    cmp al, 7Fh
    je INPUT_LOOP
    
    cmp nLengthOfBuffer, 1
    jae INPUT_DONE
    mov byte ptr [edi], al
    inc nLengthOfBuffer
    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, 1, addr lpNumberOfCharsWritten, 0
    jmp INPUT_LOOP
CHECK_EMPTY:
    cmp nLengthOfBuffer, 0
    je INPUT_LOOP

    ;invoke ReadConsoleA, hConsoleInput, addr lpTempBuffer, 1, addr lpNumberOfCharsRead, 0                                ; Read the newline character from the console input to clear the buffer
    jmp INPUT_DONE      
HANDLE_BACKSPACE:
    cmp nLengthOfBuffer, 0
    je INPUT_LOOP

    dec nLengthOfBuffer
    mov byte ptr [edi], 08H
    mov byte ptr [edi + 1], 20H
    mov byte ptr [edi + 2], 08H
    invoke WriteConsoleA, hConsoleOutput, addr lpFinalBuffer, 3, addr lpNumberOfCharsWritten, 0
    mov byte ptr [edi], 0
    jmp INPUT_LOOP
INPUT_DONE:
    mov byte ptr [edi + 1], 0

    pop eax
    pop edi
    ret
INPUT_HANDLER endp

end start