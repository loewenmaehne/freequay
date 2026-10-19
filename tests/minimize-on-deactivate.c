/* minimize-on-deactivate: a borderless window the size of the screen that minimizes itself when
 * the program loses the focus, as Source games and Direct3D 9 in fullscreen do. On Windows the
 * taskbar brings it back; on the Mac Cmd+Tab back to the program or a click on its Dock icon has
 * to. Every message that matters is printed with the state of the window, and the program ends
 * by itself after a while.
 *   minimize-on-deactivate [-a | -k] [-m W H | -d W H] [-t seconds]
 *   -a        minimize on WM_ACTIVATE(WA_INACTIVE) instead of WM_ACTIVATEAPP(FALSE)
 *   -k        minimize already on the Tab key of Cmd+Tab, before macOS has switched apps: the
 *             moment a fast game can hit by chance, every time
 *   -m W H    switch the display to W x H and back before minimizing, as Direct3D 9 does in
 *             exclusive fullscreen, and to W x H again when the program is active again
 *   -d W H    a Direct3D 9 device in exclusive fullscreen at W x H instead, which draws all the
 *             time; Direct3D 9 itself then switches the mode and minimizes the window, and the
 *             program resets the lost device when it is back
 *   -t s      end after s seconds (default 300)
 * Build: x86_64-w64-mingw32-gcc -O2 -mwindows -o minimize-on-deactivate.exe minimize-on-deactivate.c -ld3d9
 *        i686-w64-mingw32-gcc -O2 -mwindows -o minimize-on-deactivate32.exe minimize-on-deactivate.c -ld3d9 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static BOOL on_activate, on_tab, change_mode, use_d3d9;
static int mode_w, mode_h, width, height;
static DWORD start;
static IDirect3DDevice9 *device;
static D3DPRESENT_PARAMETERS present;

static void say(HWND hwnd, const char *what)
{
    RECT r = {0};
    if (hwnd) GetWindowRect(hwnd, &r);
    printf("%6.2f %-34s iconic=%d visible=%d foreground=%d active=%d rect=%ldx%ld@%ld,%ld\n",
           (GetTickCount() - start) / 1000.0, what, hwnd && IsIconic(hwnd),
           hwnd && IsWindowVisible(hwnd), hwnd && GetForegroundWindow() == hwnd,
           hwnd && GetActiveWindow() == hwnd, r.right - r.left, r.bottom - r.top, r.left, r.top);
    fflush(stdout);
}

static void set_mode(BOOL on)
{
    DEVMODEA dm = {.dmSize = sizeof(dm)};
    LONG ret;

    if (!change_mode) return;
    if (on)
    {
        dm.dmPelsWidth = mode_w;
        dm.dmPelsHeight = mode_h;
        dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
        ret = ChangeDisplaySettingsExA(NULL, &dm, NULL, CDS_FULLSCREEN, NULL);
    }
    else ret = ChangeDisplaySettingsExA(NULL, NULL, NULL, 0, NULL);
    printf("       display mode %s: %ld\n", on ? "set" : "restored", ret);
}

static void minimize(HWND hwnd, const char *why)
{
    char what[64];

    if (IsIconic(hwnd)) return;
    set_mode(FALSE);
    snprintf(what, sizeof(what), "minimize (%s)", why);
    say(hwnd, what);
    ShowWindow(hwnd, SW_MINIMIZE);
    say(hwnd, "minimized");
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    char what[64];

    switch (msg)
    {
    case WM_ACTIVATEAPP:
        snprintf(what, sizeof(what), "WM_ACTIVATEAPP(%s)", wp ? "TRUE" : "FALSE");
        say(hwnd, what);
        if (!wp && !on_activate && !device) minimize(hwnd, "app deactivated");
        else if (wp && change_mode)
        {
            /* as wined3d: the mode again and the size of the backbuffer */
            set_mode(TRUE);
            SetWindowPos(hwnd, NULL, 0, 0, width, height, SWP_NOACTIVATE | SWP_NOZORDER);
        }
        break;
    case WM_ACTIVATE:
        snprintf(what, sizeof(what), "WM_ACTIVATE(%s%s)",
                 LOWORD(wp) == WA_INACTIVE ? "WA_INACTIVE" : LOWORD(wp) == WA_CLICKACTIVE ?
                 "WA_CLICKACTIVE" : "WA_ACTIVE", HIWORD(wp) ? ", minimized" : "");
        say(hwnd, what);
        if (LOWORD(wp) == WA_INACTIVE && on_activate && !device) minimize(hwnd, "window deactivated");
        break;
    case WM_SIZE:
        snprintf(what, sizeof(what), "WM_SIZE(%s)", wp == SIZE_MINIMIZED ? "SIZE_MINIMIZED" :
                 wp == SIZE_RESTORED ? "SIZE_RESTORED" : wp == SIZE_MAXIMIZED ? "SIZE_MAXIMIZED" : "other");
        say(hwnd, what);
        break;
    case WM_SYSCOMMAND:
        snprintf(what, sizeof(what), "WM_SYSCOMMAND(%s)", (wp & 0xfff0) == SC_RESTORE ? "SC_RESTORE" :
                 (wp & 0xfff0) == SC_MINIMIZE ? "SC_MINIMIZE" : "other");
        say(hwnd, what);
        break;
    case WM_TIMER:
        say(hwnd, "time is up");
        DestroyWindow(hwnd);
        return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
        if (wp == VK_TAB && on_tab && !device)
        {
            minimize(hwnd, "Tab pressed");
            return 0;
        }
        if (msg == WM_SYSKEYDOWN) break;
        if (wp == VK_ESCAPE) DestroyWindow(hwnd);
        return 0;
    case WM_PAINT:
    {
        PAINTSTRUCT ps;
        if (device) break;  /* Direct3D draws */
        HDC dc = BeginPaint(hwnd, &ps);
        RECT r;
        GetClientRect(hwnd, &r);
        FillRect(dc, &r, GetStockObject(DKGRAY_BRUSH));
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(255, 255, 255));
        DrawTextA(dc, "minimize-on-deactivate: switch away and back. Esc ends.", -1, &r,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_DESTROY:
        set_mode(FALSE);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

/* one frame; while the device is lost (the window minimized) it waits, and resets it once the
 * program is active again, as games do */
static void draw(HWND hwnd)
{
    static HRESULT last = D3D_OK;
    HRESULT hr = IDirect3DDevice9_TestCooperativeLevel(device);
    char what[64];

    if (hr != last)
    {
        snprintf(what, sizeof(what), "device %s", hr == D3D_OK ? "ok" : hr == D3DERR_DEVICELOST ?
                 "lost" : hr == D3DERR_DEVICENOTRESET ? "not reset" : "error");
        say(hwnd, what);
        last = hr;
    }
    if (hr == D3DERR_DEVICENOTRESET)
    {
        hr = IDirect3DDevice9_Reset(device, &present);
        snprintf(what, sizeof(what), "device reset: %#lx", hr);
        say(hwnd, what);
    }
    if (hr != D3D_OK)
    {
        Sleep(20);
        return;
    }
    IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(64, 64, 64), 1.0f, 0);
    IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
}

int main(int argc, char **argv)
{
    WNDCLASSA wc = {0};
    HWND hwnd;
    MSG msg;
    int i, seconds = 300;

    start = GetTickCount();
    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "-a")) on_activate = TRUE;
        else if (!strcmp(argv[i], "-k")) on_tab = TRUE;
        else if (!strcmp(argv[i], "-m") && i + 2 < argc)
        {
            change_mode = TRUE;
            mode_w = atoi(argv[++i]);
            mode_h = atoi(argv[++i]);
        }
        else if (!strcmp(argv[i], "-d") && i + 2 < argc)
        {
            use_d3d9 = TRUE;
            mode_w = atoi(argv[++i]);
            mode_h = atoi(argv[++i]);
        }
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) seconds = atoi(argv[++i]);
        else
        {
            fprintf(stderr, "usage: minimize-on-deactivate [-a | -k] [-m W H | -d W H] [-t seconds]\n");
            return 2;
        }
    }

    set_mode(TRUE);
    /* in exclusive fullscreen the window has the size of the mode, as the backbuffer */
    width = change_mode || use_d3d9 ? mode_w : GetSystemMetrics(SM_CXSCREEN);
    height = change_mode || use_d3d9 ? mode_h : GetSystemMetrics(SM_CYSCREEN);

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "minimize-on-deactivate";
    RegisterClassA(&wc);

    /* the style wined3d gives a window in fullscreen: popup with a system menu, no caption */
    hwnd = CreateWindowExA(WS_EX_TOPMOST, wc.lpszClassName, "minimize-on-deactivate",
                           WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX, 0, 0, width, height,
                           NULL, NULL, wc.hInstance, NULL);
    if (!hwnd)
    {
        printf("CreateWindowEx failed: %lu\n", GetLastError());
        return 1;
    }
    printf("%d-bit, screen %dx%d, minimize on %s\n", (int)sizeof(void *) * 8, width, height,
           use_d3d9 ? "Direct3D 9's own" : on_tab ? "Tab" : on_activate ? "WM_ACTIVATE" : "WM_ACTIVATEAPP");
    ShowWindow(hwnd, SW_SHOW);
    SetForegroundWindow(hwnd);
    UpdateWindow(hwnd);
    say(hwnd, "shown");
    SetTimer(hwnd, 1, seconds * 1000, NULL);

    if (use_d3d9)
    {
        IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
        HRESULT hr;

        present.BackBufferWidth = mode_w;
        present.BackBufferHeight = mode_h;
        present.BackBufferFormat = D3DFMT_X8R8G8B8;
        present.BackBufferCount = 1;
        present.SwapEffect = D3DSWAPEFFECT_DISCARD;
        present.hDeviceWindow = hwnd;
        present.Windowed = FALSE;
        present.FullScreen_RefreshRateInHz = 0;
        present.PresentationInterval = D3DPRESENT_INTERVAL_ONE;
        hr = d3d ? IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                           D3DCREATE_SOFTWARE_VERTEXPROCESSING, &present, &device) : E_FAIL;
        printf("       Direct3D 9 fullscreen device %dx%d: %#lx\n", mode_w, mode_h, hr);
        if (FAILED(hr)) return 1;
        say(hwnd, "device created");
    }

    for (;;)
    {
        if (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
        {
            if (msg.message == WM_QUIT) break;
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        else if (device) draw(hwnd);
        else WaitMessage();
    }
    if (device) IDirect3DDevice9_Release(device);
    say(NULL, "end");
    return 0;
}
