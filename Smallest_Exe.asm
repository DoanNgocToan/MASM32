.386
.model flat, stdcall

extern MessageBoxA@16:proc

.code
main:
    push 0
    push 0
    push 0
    push 0
    call MessageBoxA@16
end main

