/* devname: checks that the display name ("\\.\DISPLAY1") arrives padded with zeros.
 * Windows fills the rest of the field with zeros; some programs read all 32 characters (the
 * FFXIV benchmark launcher), and garbage behind the name then cuts their command line.
 * The field is filled with 0xCC before every call: if 0xCC stays, the function only writes up
 * to the terminating zero; other content means it copies garbage from a buffer of its own.
 * Build: x86_64-w64-mingw32-gcc -O2 -o devname.exe devname.c -ldxgi -luuid */
#define COBJMACROS
#include <windows.h>
#include <dxgi.h>
#include <stdio.h>
#include <string.h>

static int report(const char *what, const WCHAR *name, size_t count)
{
    size_t len = wcsnlen(name, count), i;
    int clean = 1;

    printf("%-28s \"%ls\", then:", what, name);
    for (i = len + 1; i < count; i++)
        if (name[i]) clean = 0;
    for (i = len + 1; i < len + 7 && i < count; i++) printf(" %04x", name[i]);
    printf(" ... %s\n", clean ? "OK, zeros" : (name[len + 1] == 0xcccc ? "not written (0xCC)" : "GARBAGE"));
    return clean;
}

int main(void)
{
    MONITORINFOEXW mi;
    DXGI_OUTPUT_DESC desc;
    IDXGIFactory *factory;
    IDXGIAdapter *adapter;
    IDXGIOutput *output;
    HMONITOR mon = MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY);
    int ok = 1;

    memset(&mi, 0xcc, sizeof(mi));
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(mon, (MONITORINFO *)&mi)) ok &= report("GetMonitorInfoW:", mi.szDevice, CCHDEVICENAME);

    if (FAILED(CreateDXGIFactory(&IID_IDXGIFactory, (void **)&factory))) { printf("CreateDXGIFactory failed\n"); return 1; }
    if (FAILED(IDXGIFactory_EnumAdapters(factory, 0, &adapter))) { printf("no adapter\n"); return 1; }
    if (FAILED(IDXGIAdapter_EnumOutputs(adapter, 0, &output))) { printf("no output\n"); return 1; }
    memset(&desc, 0xcc, sizeof(desc));
    if (SUCCEEDED(IDXGIOutput_GetDesc(output, &desc))) ok &= report("IDXGIOutput::GetDesc:", desc.DeviceName, ARRAYSIZE(desc.DeviceName));
    printf("%s\n", ok ? "OK" : "ERROR: garbage or an unwritten rest in the display name");
    return ok ? 0 : 1;
}
