/* rulecheck: prints what the compatibility rules changed for this program: own path, command
 * line, the variables named on the command line (%NAME), whether the CPU reports AVX (Rosetta
 * does so with ROSETTA_ADVERTISE_AVX=1), and where d3d11.dll and dxgi.dll come from.
 * Build: x86_64-w64-mingw32-gcc -O2 -municode -o rulecheck.exe rulecheck.c */
#include <windows.h>
#include <stdio.h>
#include <cpuid.h>

int wmain( int argc, WCHAR **argv )
{
    WCHAR buf[4096];
    HMODULE mod;
    int i;

    GetModuleFileNameW( NULL, buf, ARRAYSIZE(buf) );
    wprintf( L"exe: %ls\n", buf );
    wprintf( L"cmdline: %ls\n", GetCommandLineW() );
    for (i = 1; i < argc; i++)
    {
        if (argv[i][0] != L'%') continue;
        if (GetEnvironmentVariableW( argv[i] + 1, buf, ARRAYSIZE(buf) )) wprintf( L"env %ls=%ls\n", argv[i] + 1, buf );
        else wprintf( L"env %ls unset\n", argv[i] + 1 );
    }
    {
        unsigned int a, b, c, d;
        __cpuid( 1, a, b, c, d );
        wprintf( L"avx: %ls\n", (c & bit_AVX) ? L"yes" : L"no" );
    }
    if ((mod = LoadLibraryW( L"d3d11.dll" )) && GetModuleFileNameW( mod, buf, ARRAYSIZE(buf) ))
    {
        HMODULE dxgi = GetModuleHandleW( L"dxgi.dll" );
        IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((char *)mod + ((IMAGE_DOS_HEADER *)mod)->e_lfanew);
        wprintf( L"d3d11: %ls, image size %#lx\n", buf, nt->OptionalHeader.SizeOfImage );
        if (dxgi && GetModuleFileNameW( dxgi, buf, ARRAYSIZE(buf) )) wprintf( L"dxgi: %ls\n", buf );
    }
    fflush( stdout );
    return 0;
}
