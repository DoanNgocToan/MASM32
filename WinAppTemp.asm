.386
.model flat, stdcall
option casemap:none

include windows.inc
include kernel32.inc
include user32.inc

includelib kernel32.lib
includelib user32.lib

.data
    szClassname db "MyClassWindow",0
    szWindowName db "MyWindow",0

    hInstance HINSTANCE ?
    hWndMain HWND ?
    CommandLine LPSTR ?
.code
start:
    invoke GetModuleHandle, NULL
    mov hInstance, eax

    invoke GetCommandLine
    mov CommandLine, eax

    invoke WinMain, hInstance, NULL, CommandLine, SW_SHOWDEFAULT
    invoke ExitProcess, eax

WinMain PROC hInst:HINSTANCE, hPrevInst:HINSTANCE, lpCmdLine:LPSTR, nCmdShow:DWORD
    LOCAL wc:WNDCLASSEX
    LOCAL msg:MSG
    mov wc.cbSize, sizeof WNDCLASSEX
    mov wc.style, CS_HREDRAW or CS_VREDRAW
    mov wc.lpfnWndProc, OFFSET WndProc
    mov wc.cbClsExtra, NULL
    mov wc.cbWndExtra, NULL
    push hInst
    pop wc.hInstance
    mov wc.hbrBackground, COLOR_WINDOW+1
    mov wc.lpszMenuName, NULL
    mov wc.lpszClassName, OFFSET szClassName
    
    invoke LoadCursor, NULL, IDC_ARROW
    mov wc.hCursor, eax

    invoke LoadIcon, NULL, IDI_APPLICATION
    mov wc.hIcon, eax
    mov wx.hIconSm, eax

    invoke RegisterClassEx, addr wc
    invoke CreateWindowEx, NULL, addr szClassName, addr szWindowName, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, NULL, NULL, hInst, NULL 

    mov hWndMain, eax
    invoke ShowWindow, hWndMain, nCmdShow
    invoke UpdateWindow, hWndMain

    .WHILE TRUE
        invoke GetMessage, addr msg, NULL, 0, 0
        .BREAK .IF (!eax)
        invoke TranslateMessage, addr msg
        invoke DispatchMessage, addr msg
    .ENDW

    mov eax, msg.wParam
    ret
WinMain ENDP

WinProc PROC hWnd:HWND, uMsg:UINT, wParam:WPARAM, lParam:LPARAM
    .IF uMsg == WM_CREATE
        invoke CreateControls, hwndMain
        xor eax, eax
        ret
    .ELSEIF uMsg == WM_COMMAND
        mov eax, wParam
        .IF eax == 1
            invoke MessageBox, NULL, addr szWindowName, addr szClassName, MB_OK
        .ENDIF
    .ELSEIF uMsg == WM_DESTROY
        invoke PostQuitMessage, NULL
        xor eax, eax
        ret
    .ELSE
        invoke DefWindowProc, hWnd, uMsg, wParam, lParam
        ret
    .ENDIF
    xor eax, eax
    ret
WinProc ENDP