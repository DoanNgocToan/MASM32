.386
.model flat, stdcall
option casemap:none

WinMain proto :DWORD, :DWORD, :DWORD, :DWORD
include windows.inc
include kernel32.inc
include user32.inc
include comctl32.inc

includelib kernel32.lib
includelib user32.lib
includelib comctl32.lib

ThreadContext STRUCT
    lpPath LPDWORD 0
    fTerminateThread dd 0
    rowIdx dd 0
ThreadContext ENDS

.data
    IDC_EDIT equ 1001
    IDC_BTN  equ 1002
    IDC_LIST equ 1003

    szClass db "MyWindowClass",0
    szEdit db "EDIT",0
    szButton db "BUTTON",0
    szListView db "SysListView32",0
    szTitle db "Find All Files",0
    szDir db "Directory",0
    szEditText  db "C:\",0
    szStartBtn db "Start",0
    szStopBtn  db "Stop",0
    szAllFiles db "*.*",0
    szSlash db "\",0
    szWindowTheme db "Explorer",0

    isRunning dd 0
    pathBuffer db 260 dup(0)

    icex INITCOMMONCONTROLSEX <sizeof INITCOMMONCONTROLSEX, ICC_WIN95_CLASSES>

.data?
    hInstance HINSTANCE ?
    hWndMain  HINSTANCE ?
    hEdit     HINSTANCE ?
    hBtn      HINSTANCE ?
    hList     HINSTANCE ?
    hThread   HINSTANCE ?

    lpThreadId   LPDWORD ?

    CommandLine LPSTR ?
    ThreadCtx ThreadContext <>
.code
start:
    invoke InitCommonControlsEx, addr icex
    invoke GetModuleHandle,NULL 
    mov hInstance,eax
    invoke GetCommandLine
    mov CommandLine,eax
    invoke WinMain, hInstance, NULL, CommandLine, SW_SHOWDEFAULT
    invoke ExitProcess,eax

; INIT LISTVIEW
InitListView PROC
    LOCAL lvc:LVCOLUMN

    mov lvc.imask, LVCF_TEXT or LVCF_WIDTH
    mov lvc.lx, 350
    mov lvc.pszText, OFFSET szDir

    invoke SendMessage, hList, LVM_INSERTCOLUMN, 0, addr lvc
    ret
InitListView ENDP


; ADD ITEM

AddItem PROC lpPath:LPDWORD, rowIndex:DWORD
    LOCAL lvi:LVITEM

    mov lvi.imask, LVIF_TEXT

    push rowIndex
    pop lvi.iItem

    mov lvi.iSubItem, 0

    push lpPath
    pop lvi.pszText

    invoke SendMessage, hList, LVM_INSERTITEM, 0, addr lvi
    inc rowIndex
    ret
AddItem ENDP


; FIND ALL FILES

FindAllFiles PROC uses esi ebx, lpCurrPath:DWORD, lpThreadCtx:DWORD
    LOCAL fd:WIN32_FIND_DATA
    LOCAL hFind:HANDLE
    LOCAL szSearchPath[260]:BYTE
    LOCAL szFullPath[260]:BYTE
    LOCAL tmp:DWORD

    mov ebx, lpThreadCtx
    assume ebx:PTR ThreadContext

    invoke lstrcpy, addr szSearchPath, lpCurrPath
    invoke lstrcat, addr szSearchPath, addr szSlash
    invoke lstrcat, addr szSearchPath, addr szAllFiles

    invoke FindFirstFile, addr szSearchPath, addr fd
    mov hFind, eax

    .IF eax != INVALID_HANDLE_VALUE
    _find_loop:
        test DWORD PTR [ebx].fTerminateThread, 1
        jnz _find_close

        lea esi, fd.cFileName
        cmp byte ptr [esi], '.'
        je _skip_file

        ; build full path
        invoke lstrcpy, addr szFullPath, lpCurrPath
        invoke lstrcat, addr szFullPath, addr szSlash
        invoke lstrcat, addr szFullPath, addr fd.cFileName

        mov eax, fd.dwFileAttributes
        mov tmp, eax
        and tmp, FILE_ATTRIBUTE_DIRECTORY

        .IF tmp != 0
            invoke FindAllFiles, addr szFullPath, lpThreadCtx
        .ELSE
            invoke AddItem, addr szFullPath, [ebx].rowIdx
            inc DWORD PTR [ebx].rowIdx
        .ENDIF

    _skip_file:
        invoke FindNextFile, hFind, addr fd
        test eax,eax
        jnz _find_loop
    _find_close:
        invoke FindClose, hFind
    .ENDIF
    ret
FindAllFiles ENDP


; THREAD

ThreadProc PROC uses ebx, lpThreadCtx:DWORD
    mov ebx, lpThreadCtx
    assume ebx:PTR ThreadContext
    
    invoke FindAllFiles, [ebx].lpPath, lpThreadCtx
    and isRunning, 0

    ; gửi message về main để reset UI
    invoke PostMessage, hWndMain, WM_USER+1, 0, 0
    ret
ThreadProc ENDP


; CREATE CONTROLS

CreateControls PROC hWnd:HWND
    ; EDIT
    invoke CreateWindowEx, WS_EX_CLIENTEDGE, addr szEdit, addr szEditText, WS_CHILD or WS_VISIBLE or ES_AUTOHSCROLL or ES_LEFT, 10, 10 , 680, 25, hWnd, IDC_EDIT, hInstance, NULL
    mov hEdit, eax

    ; BUTTON
    invoke CreateWindowEx, NULL, addr szButton, addr szStartBtn, WS_CHILD or WS_VISIBLE, 700, 10, 80, 25, hWnd, IDC_BTN, hInstance, NULL
    mov hBtn, eax

    ; LISTVIEW
    invoke CreateWindowEx, WS_EX_CLIENTEDGE or LVS_EX_FULLROWSELECT or LVS_EX_GRIDLINES or LVS_EX_DOUBLEBUFFER, addr szListView, NULL, WS_CHILD or WS_VISIBLE or LVS_REPORT, 10, 50, 765, 500, hWnd, IDC_LIST, hInstance, NULL
    mov hList, eax

    invoke InitListView
    ret
CreateControls ENDP

; WINMAIN

WinMain PROC hInst:HINSTANCE, hPrevInst:HINSTANCE, lpCmdLine:LPSTR, nCmdShow:DWORD
    LOCAL wc:WNDCLASSEX
    LOCAL msg:MSG

    mov wc.cbSize,SIZEOF WNDCLASSEX
    mov wc.style, CS_HREDRAW or CS_VREDRAW
    mov wc.lpfnWndProc, OFFSET WndProc
    mov wc.cbClsExtra, NULL
    mov wc.cbWndExtra, NULL
    push hInst
    pop wc.hInstance
    mov wc.hbrBackground,COLOR_WINDOW+1
    mov wc.lpszMenuName,NULL
    mov wc.lpszClassName, OFFSET szClass

    invoke LoadCursor,0,IDC_ARROW
    mov wc.hCursor,eax
    invoke LoadIcon,0,IDI_APPLICATION
    mov wc.hIcon,eax
    mov wc.hIconSm,eax

    invoke RegisterClassEx, addr wc

    invoke CreateWindowEx, NULL, addr szClass, addr szTitle, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 800, 600, NULL, NULL, hInst, NULL

    mov hWndMain,eax

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

; WNDPROC

WndProc PROC hWnd:HWND, uMsg:UINT, wParam:WPARAM, lParam:LPARAM

    .IF uMsg == WM_CREATE
        invoke CreateControls, hWnd

    .ELSEIF uMsg == WM_COMMAND
        mov eax, wParam
        and eax, 0FFFFh         ; get control ID
        cmp ax, IDC_BTN
        jne _not_btn_clicked

        mov eax, wParam
        shr eax, 16             ; get notification code
        cmp al, BN_CLICKED      
        jne _not_btn_clicked

        test isRunning, 1
        jz _start_thread

        or DWORD PTR [ThreadCtx.fTerminateThread], 1
        invoke SetWindowText, hBtn, addr szStartBtn
        invoke EnableWindow, hEdit, TRUE
        and isRunning, 0
        ret

        _start_thread:
            invoke GetWindowText, hEdit, addr pathBuffer, 260
            
            invoke lstrlen, addr pathBuffer
            cmp eax, 3
            jz _no_strip
            jl _invalid_path

            lea ecx, pathBuffer
            add ecx, eax
            dec ecx

            cmp byte ptr [ecx], '\'
            jne _no_strip

            mov byte ptr [ecx], 0
            _no_strip:
                or isRunning, 1
                invoke EnableWindow, hEdit, FALSE
                invoke SetWindowText, hBtn, addr szStopBtn

                invoke SendMessage, hList, LVM_DELETEALLITEMS, 0, 0
                
                mov ThreadCtx.lpPath, OFFSET pathBuffer
                and DWORD PTR [ThreadCtx.fTerminateThread], 0
                and DWORD PTR [ThreadCtx.rowIdx], 0

                invoke CreateThread, NULL, 0 ,addr ThreadProc, addr ThreadCtx, 0, lpThreadId
                mov hThread, eax
            _invalid_path:
        _not_btn_clicked:
        
        ret
    .ELSEIF uMsg == WM_USER+1
        ; thread done
        invoke SetWindowText, hBtn, addr szStartBtn
        invoke EnableWindow, hEdit, TRUE

    .ELSEIF uMsg == WM_DESTROY
        .IF hThread != NULL
            and isRunning, 0
            invoke WaitForSingleObject, hThread, INFINITE
            invoke CloseHandle, hThread
        .ENDIF
        invoke PostQuitMessage,0
        ret
    .ELSE
        invoke DefWindowProc, hWnd, uMsg, wParam, lParam
        ret
    .ENDIF
    xor eax,eax
    ret
WndProc ENDP

end start