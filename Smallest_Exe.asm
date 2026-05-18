.386
.model flat, stdcall

extern MessageBoxA@16:proc

.code
main:
    xor eax, eax
    push eax
    push eax
    push eax
    push eax
    call MessageBoxA@16
    ret
end main

