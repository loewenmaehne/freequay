/* winlist: lists the windows of a bottle with process, size, class and title. A stand-in for
 * screenshots while the terminal may not record the screen.
 *   winlist        visible top-level windows
 *   winlist -c     plus the visible child windows (buttons, text fields ...)
 * Build: x86_64-w64-mingw32-gcc -O2 -municode -o winlist.exe winlist.c */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int children;

static void put(const WCHAR *s)
{
    char buf[1024];
    int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, buf, sizeof(buf), NULL, NULL);
    if (n > 1) fwrite(buf, 1, n - 1, stdout);
}

static void show(HWND hwnd, int depth)
{
    WCHAR title[256] = L"", cls[128] = L"", exe[MAX_PATH] = L"?", line[256];
    DWORD pid = 0, len = MAX_PATH;
    HANDLE proc;
    RECT r;

    GetWindowTextW(hwnd, title, ARRAYSIZE(title));
    GetClassNameW(hwnd, cls, ARRAYSIZE(cls));
    GetWindowRect(hwnd, &r);
    GetWindowThreadProcessId(hwnd, &pid);
    if ((proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)))
    {
        if (QueryFullProcessImageNameW(proc, 0, exe, &len))
        {
            WCHAR *name = wcsrchr(exe, '\\');
            if (name) memmove(exe, name + 1, (wcslen(name + 1) + 1) * sizeof(WCHAR));
        }
        CloseHandle(proc);
    }
    swprintf(line, ARRAYSIZE(line), L"%*s%ls %ldx%ld @%ld,%ld [%ls] ", depth * 2, L"", exe,
             r.right - r.left, r.bottom - r.top, r.left, r.top, cls);
    put(line);
    put(title);
    put(L"\n");
}

static BOOL CALLBACK child_proc(HWND hwnd, LPARAM depth)
{
    if (IsWindowVisible(hwnd)) show(hwnd, (int)depth);
    return TRUE;
}

static BOOL CALLBACK top_proc(HWND hwnd, LPARAM unused)
{
    if (!IsWindowVisible(hwnd)) return TRUE;
    show(hwnd, 0);
    if (children) EnumChildWindows(hwnd, child_proc, 1);
    return TRUE;
}

int wmain(int argc, WCHAR **argv)
{
    children = argc > 1 && !wcscmp(argv[1], L"-c");
    EnumWindows(top_proc, 0);
    return 0;
}
