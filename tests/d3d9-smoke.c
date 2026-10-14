/* d3d9-smoke: opens a window and draws a colored triangle with Direct3D 9 (fixed-function
 * pipeline as in older games). Reads the image back, checks two pixels, saves it as
 * d3d9-smoke.bmp and presents for 3 seconds.
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d9-smoke.exe d3d9-smoke.c -ld3d9 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>

#define W 640
#define H 360

struct vertex { float x, y, z, rhw; DWORD color; };

static void save_bmp(const char *path, const unsigned char *bgra, INT pitch)
{
    BITMAPFILEHEADER fh = {0};
    BITMAPINFOHEADER ih = {0};
    FILE *f = fopen(path, "wb");
    int x, y;

    if (!f) return;
    fh.bfType = 0x4d42;
    fh.bfOffBits = sizeof(fh) + sizeof(ih);
    fh.bfSize = fh.bfOffBits + W * H * 3;
    ih.biSize = sizeof(ih);
    ih.biWidth = W;
    ih.biHeight = H;
    ih.biPlanes = 1;
    ih.biBitCount = 24;
    fwrite(&fh, sizeof(fh), 1, f);
    fwrite(&ih, sizeof(ih), 1, f);
    for (y = H - 1; y >= 0; y--)
        for (x = 0; x < W; x++) fwrite(bgra + y * pitch + x * 4, 3, 1, f);
    fclose(f);
}

static void draw(IDirect3DDevice9 *dev, const struct vertex *tri)
{
    IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(51, 153, 255), 1.0f, 0);
    IDirect3DDevice9_BeginScene(dev);
    IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW | D3DFVF_DIFFUSE);
    IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLELIST, 1, tri, sizeof(*tri));
    IDirect3DDevice9_EndScene(dev);
}

int main(void)
{
    static const struct vertex tri[3] =
    {
        {W * 0.50f, H * 0.10f, 0.5f, 1.0f, D3DCOLOR_XRGB(255, 0, 0)},
        {W * 0.85f, H * 0.85f, 0.5f, 1.0f, D3DCOLOR_XRGB(0, 255, 0)},
        {W * 0.15f, H * 0.85f, 0.5f, 1.0f, D3DCOLOR_XRGB(0, 0, 255)},
    };
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    D3DPRESENT_PARAMETERS pp = {0};
    D3DADAPTER_IDENTIFIER9 id;
    D3DLOCKED_RECT lr;
    IDirect3D9 *d3d;
    IDirect3DDevice9 *dev = NULL;
    IDirect3DSurface9 *back = NULL, *sysmem = NULL;
    DWORD start;
    HRESULT hr;
    HWND hwnd;
    int frames = 0, ok = 1;

    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = inst;
    wc.lpszClassName = L"d3d9smoke";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"d3d9smoke", L"freequay d3d9 smoke", WS_OVERLAPPED | WS_CAPTION | WS_VISIBLE,
                         100, 100, W, H, NULL, NULL, inst, NULL);

    if (!(d3d = Direct3DCreate9(D3D_SDK_VERSION)))
    {
        printf("Direct3DCreate9 failed\n");
        return 1;
    }
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id)))
        printf("adapter: %s\n", id.Description);

    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = W;
    pp.BackBufferHeight = H;
    pp.hDeviceWindow = hwnd;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_ONE;
    hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                 D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    printf("CreateDevice: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    draw(dev, tri);
    IDirect3DDevice9_GetBackBuffer(dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back);
    IDirect3DDevice9_CreateOffscreenPlainSurface(dev, W, H, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &sysmem, NULL);
    hr = IDirect3DDevice9_GetRenderTargetData(dev, back, sysmem);
    if (SUCCEEDED(hr) && SUCCEEDED(IDirect3DSurface9_LockRect(sysmem, &lr, NULL, D3DLOCK_READONLY)))
    {
        const unsigned char *corner = lr.pBits;
        const unsigned char *center = (const unsigned char *)lr.pBits + (H / 2) * lr.Pitch + (W / 2) * 4;
        /* X8R8G8B8 is stored as B, G, R in memory */
        printf("pixel top left: %u %u %u (background, expected 51 153 255)\n", corner[2], corner[1], corner[0]);
        printf("pixel center: %u %u %u (triangle, blended color)\n", center[2], center[1], center[0]);
        if (abs(corner[2] - 51) > 3 || abs(corner[1] - 153) > 3 || corner[0] < 250) ok = 0;
        if (center[0] == corner[0] && center[1] == corner[1] && center[2] == corner[2]) ok = 0;
        save_bmp("d3d9-smoke.bmp", lr.pBits, lr.Pitch);
        IDirect3DSurface9_UnlockRect(sysmem);
    }
    else
    {
        printf("readback: hr=0x%08lx\n", hr);
        ok = 0;
    }

    start = GetTickCount();
    while (GetTickCount() - start < 3000)
    {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        draw(dev, tri);
        hr = IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
        if (FAILED(hr))
        {
            printf("Present: hr=0x%08lx\n", hr);
            return 1;
        }
        frames++;
    }
    printf("frames: %d in 3 s\n", frames);
    printf("%s\n", ok ? "OK" : "ERROR: the image is wrong");
    return ok ? 0 : 1;
}
