/* d3d9-reset: changes the back buffer size with IDirect3DDevice9::Reset many times while drawing
 * the way a deferred renderer does: four render target textures at once, a D24S8 depth buffer, a
 * lighting pass that samples them, a blur into a quarter-size texture, StretchRect, a dynamic
 * vertex buffer locked with D3DLOCK_DISCARD and a managed texture. Everything in D3DPOOL_DEFAULT
 * is released before each Reset and created again after it, as games must. Fails when Present or
 * Reset report a lost or removed device, or when TestCooperativeLevel does.
 *   d3d9-reset [resets] [fullscreen]   default 60 resets in a window; "fullscreen" switches
 *                                      the display mode between 1440x900, 1280x800, 1024x640
 * Build: i686-w64-mingw32-gcc -O2 -o d3d9-reset32.exe d3d9-reset.c -ld3d9 -ld3dcompiler_47 -lgdi32
 *        x86_64-w64-mingw32-gcc -O2 -o d3d9-reset.exe d3d9-reset.c -ld3d9 -ld3dcompiler_47 -lgdi32 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct vertex { float x, y, z, rhw, u, v; };

static const char shader[] =
    "sampler2D s0 : register(s0);\n"
    "sampler2D s1 : register(s1);\n"
    "sampler2D s2 : register(s2);\n"
    "sampler2D s3 : register(s3);\n"
    "sampler2D sz : register(s4);\n"
    "float4 px : register(c0);\n"
    "struct mrt { float4 c0 : COLOR0; float4 c1 : COLOR1; float4 c2 : COLOR2; float4 c3 : COLOR3; };\n"
    "mrt gbuffer(float2 uv : TEXCOORD0) {\n"
    "    mrt o; float4 t = tex2D(s0, uv * 4);\n"
    "    o.c0 = t; o.c1 = float4(uv, 0.5, 1); o.c2 = t.bgra; o.c3 = float4(1 - uv, 0.25, 1); return o; }\n"
    "float4 light(float2 uv : TEXCOORD0) : COLOR {\n"
    "    float z = tex2D(sz, uv).r;\n"
    "    return tex2D(s0, uv) * tex2D(s1, uv) + tex2D(s2, uv) * 0.5 + tex2D(s3, uv) * z; }\n"
    "float4 blur(float2 uv : TEXCOORD0) : COLOR {\n"
    "    float4 c = 0; int i;\n"
    "    for (i = -3; i <= 3; i++) c += tex2D(s0, uv + float2(i, i) * px.xy);\n"
    "    return c / 7; }\n"
    "float4 combine(float2 uv : TEXCOORD0) : COLOR { return tex2D(s0, uv) * 0.7 + tex2D(s1, uv) * 0.3; }\n";

static const int sizes[3][2] = {{1440, 900}, {1280, 800}, {1024, 640}};

static IDirect3D9 *d3d;
static IDirect3DDevice9 *dev;
static IDirect3DPixelShader9 *ps_gbuffer, *ps_light, *ps_blur, *ps_combine;
static IDirect3DTexture9 *gbuf[4], *lit, *small, *ztex, *managed;
static IDirect3DSurface9 *depth;
static IDirect3DVertexBuffer9 *vb;
static int width, height;

static IDirect3DPixelShader9 *compile(const char *entry)
{
    ID3DBlob *blob = NULL, *errors = NULL;
    IDirect3DPixelShader9 *ps = NULL;
    HRESULT hr = D3DCompile(shader, sizeof(shader) - 1, "d3d9-reset", NULL, NULL, entry, "ps_3_0", 0, 0, &blob, &errors);
    if (FAILED(hr))
    {
        printf("D3DCompile %s: hr=0x%08lx %s\n", entry, hr, errors ? (char *)ID3D10Blob_GetBufferPointer(errors) : "");
        exit(1);
    }
    if (FAILED(IDirect3DDevice9_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(blob), &ps))) { printf("CreatePixelShader %s failed\n", entry); exit(1); }
    ID3D10Blob_Release(blob);
    return ps;
}

static int create_default_resources(void)
{
    HRESULT hr = S_OK;
    int i;
    for (i = 0; i < 4 && SUCCEEDED(hr); i++)
        hr = IDirect3DDevice9_CreateTexture(dev, width, height, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A8R8G8B8, D3DPOOL_DEFAULT, &gbuf[i], NULL);
    if (SUCCEEDED(hr)) hr = IDirect3DDevice9_CreateTexture(dev, width, height, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A16B16G16R16F, D3DPOOL_DEFAULT, &lit, NULL);
    if (SUCCEEDED(hr)) hr = IDirect3DDevice9_CreateTexture(dev, width / 4, height / 4, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A16B16G16R16F, D3DPOOL_DEFAULT, &small, NULL);
    /* a depth buffer the lighting pass can sample, like INTZ; fall back to a plain one */
    if (SUCCEEDED(hr))
    {
        if (SUCCEEDED(IDirect3DDevice9_CreateTexture(dev, width, height, 1, D3DUSAGE_DEPTHSTENCIL, (D3DFORMAT)MAKEFOURCC('I','N','T','Z'), D3DPOOL_DEFAULT, &ztex, NULL)))
            IDirect3DTexture9_GetSurfaceLevel(ztex, 0, &depth);
        else
            hr = IDirect3DDevice9_CreateDepthStencilSurface(dev, width, height, D3DFMT_D24S8, D3DMULTISAMPLE_NONE, 0, TRUE, &depth, NULL);
    }
    if (SUCCEEDED(hr)) hr = IDirect3DDevice9_CreateVertexBuffer(dev, 64 * sizeof(struct vertex), D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY,
                                                                D3DFVF_XYZRHW | D3DFVF_TEX1, D3DPOOL_DEFAULT, &vb, NULL);
    if (FAILED(hr)) printf("creating resources at %dx%d: hr=0x%08lx\n", width, height, hr);
    return SUCCEEDED(hr);
}

static void release_default_resources(void)
{
    int i;
    for (i = 0; i < 4; i++) if (gbuf[i]) { IDirect3DTexture9_Release(gbuf[i]); gbuf[i] = NULL; }
    if (lit) { IDirect3DTexture9_Release(lit); lit = NULL; }
    if (small) { IDirect3DTexture9_Release(small); small = NULL; }
    if (depth) { IDirect3DSurface9_Release(depth); depth = NULL; }
    if (ztex) { IDirect3DTexture9_Release(ztex); ztex = NULL; }
    if (vb) { IDirect3DVertexBuffer9_Release(vb); vb = NULL; }
}

/* a w x h quad from the dynamic vertex buffer, locked with DISCARD every time */
static void quad(int w, int h)
{
    struct vertex *v;
    if (FAILED(IDirect3DVertexBuffer9_Lock(vb, 0, 4 * sizeof(*v), (void **)&v, D3DLOCK_DISCARD))) return;
    v[0] = (struct vertex){-0.5f, -0.5f, 0.5f, 1.0f, 0.0f, 0.0f};
    v[1] = (struct vertex){w - 0.5f, -0.5f, 0.5f, 1.0f, 1.0f, 0.0f};
    v[2] = (struct vertex){-0.5f, h - 0.5f, 0.5f, 1.0f, 0.0f, 1.0f};
    v[3] = (struct vertex){w - 0.5f, h - 0.5f, 0.5f, 1.0f, 1.0f, 1.0f};
    IDirect3DVertexBuffer9_Unlock(vb);
    IDirect3DDevice9_SetStreamSource(dev, 0, vb, 0, sizeof(*v));
    IDirect3DDevice9_DrawPrimitive(dev, D3DPT_TRIANGLESTRIP, 0, 2);
}

static void set_target(int index, IDirect3DTexture9 *tex)
{
    IDirect3DSurface9 *s = NULL;
    if (tex) IDirect3DTexture9_GetSurfaceLevel(tex, 0, &s);
    IDirect3DDevice9_SetRenderTarget(dev, index, s);
    if (s) IDirect3DSurface9_Release(s);
}

static HRESULT frame(int n)
{
    IDirect3DSurface9 *back, *src;
    float c[4] = {4.0f / width, 4.0f / height, 0, 0};
    RECT r = {0, 0, width / 2, height / 2};
    int i;

    IDirect3DDevice9_GetBackBuffer(dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back);
    IDirect3DDevice9_BeginScene(dev);
    for (i = 0; i < 4; i++) set_target(i, gbuf[i]);
    IDirect3DDevice9_SetDepthStencilSurface(dev, depth);
    IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL, D3DCOLOR_XRGB(n % 256, 0, 0), 1.0f, 0);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, D3DZB_TRUE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZWRITEENABLE, TRUE);
    IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)managed);
    IDirect3DDevice9_SetPixelShader(dev, ps_gbuffer);
    quad(width, height);
    for (i = 1; i < 4; i++) set_target(i, NULL);

    /* lighting: samples the four g-buffer textures and the depth buffer, which stays bound read-only */
    set_target(0, lit);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZWRITEENABLE, FALSE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZFUNC, D3DCMP_ALWAYS);
    for (i = 0; i < 4; i++) IDirect3DDevice9_SetTexture(dev, i, (IDirect3DBaseTexture9 *)gbuf[i]);
    if (ztex) IDirect3DDevice9_SetTexture(dev, 4, (IDirect3DBaseTexture9 *)ztex);
    IDirect3DDevice9_SetPixelShader(dev, ps_light);
    quad(width, height);
    for (i = 0; i < 5; i++) IDirect3DDevice9_SetTexture(dev, i, NULL);
    IDirect3DDevice9_SetDepthStencilSurface(dev, NULL);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, D3DZB_FALSE);

    /* blur into a quarter-size texture */
    set_target(0, small);
    IDirect3DDevice9_SetPixelShaderConstantF(dev, 0, c, 1);
    IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)lit);
    IDirect3DDevice9_SetPixelShader(dev, ps_blur);
    quad(width / 4, height / 4);

    /* combine into the back buffer, then StretchRect a part of the lit image onto it */
    IDirect3DDevice9_SetRenderTarget(dev, 0, back);
    IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)lit);
    IDirect3DDevice9_SetTexture(dev, 1, (IDirect3DBaseTexture9 *)small);
    IDirect3DDevice9_SetPixelShader(dev, ps_combine);
    quad(width, height);
    IDirect3DDevice9_SetTexture(dev, 0, NULL);
    IDirect3DDevice9_SetTexture(dev, 1, NULL);
    IDirect3DTexture9_GetSurfaceLevel(gbuf[0], 0, &src);
    IDirect3DDevice9_StretchRect(dev, src, NULL, back, &r, D3DTEXF_LINEAR);
    IDirect3DSurface9_Release(src);
    IDirect3DDevice9_EndScene(dev);
    IDirect3DSurface9_Release(back);
    return IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
}

static void fill_params(D3DPRESENT_PARAMETERS *pp, HWND hwnd, BOOL fullscreen)
{
    memset(pp, 0, sizeof(*pp));
    pp->Windowed = !fullscreen;
    pp->SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp->BackBufferFormat = D3DFMT_X8R8G8B8;
    pp->BackBufferWidth = width;
    pp->BackBufferHeight = height;
    pp->BackBufferCount = 1;
    pp->hDeviceWindow = hwnd;
    pp->PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    if (fullscreen) pp->FullScreen_RefreshRateInHz = 0;
}

int main(int argc, char **argv)
{
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    D3DPRESENT_PARAMETERS pp;
    D3DLOCKED_RECT lr;
    int resets = argc > 1 ? atoi(argv[1]) : 60, fullscreen = argc > 2 && !strcmp(argv[2], "fullscreen");
    int i, f, ok = 1, frames = 0;
    HRESULT hr;
    HWND hwnd;
    MSG msg;

    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = inst;
    wc.lpszClassName = L"d3d9reset";
    RegisterClassW(&wc);
    width = sizes[0][0]; height = sizes[0][1];
    if (!fullscreen) { width = 800; height = 500; }
    hwnd = CreateWindowW(L"d3d9reset", L"freequay d3d9 reset", fullscreen ? WS_POPUP | WS_VISIBLE : WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                         0, 0, width, height, NULL, NULL, inst, NULL);

    if (!(d3d = Direct3DCreate9(D3D_SDK_VERSION))) { printf("Direct3DCreate9 failed\n"); return 1; }
    fill_params(&pp, hwnd, fullscreen);
    hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    printf("CreateDevice %dx%d%s: hr=0x%08lx\n", width, height, fullscreen ? " fullscreen" : "", hr);
    if (FAILED(hr)) return 1;
    ps_gbuffer = compile("gbuffer");
    ps_light = compile("light");
    ps_blur = compile("blur");
    ps_combine = compile("combine");
    IDirect3DDevice9_CreateTexture(dev, 64, 64, 0, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &managed, NULL);
    IDirect3DTexture9_LockRect(managed, 0, &lr, NULL, 0);
    for (i = 0; i < 64 * 64; i++) ((DWORD *)lr.pBits)[(i / 64) * (lr.Pitch / 4) + i % 64] = ((i / 64) ^ (i % 64)) & 8 ? 0xffc08040 : 0xff204080;
    IDirect3DTexture9_UnlockRect(managed, 0);
    IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW | D3DFVF_TEX1);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
    if (!create_default_resources()) return 1;

    for (i = 0; i <= resets && ok; i++)
    {
        for (f = 0; f < 20 && ok; f++, frames++)
        {
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
            hr = frame(frames);
            if (hr == D3DERR_DEVICELOST || hr == D3DERR_DEVICEREMOVED || hr == D3DERR_DRIVERINTERNALERROR)
            {
                printf("Present after reset %d, frame %d: hr=0x%08lx\n", i, f, hr);
                ok = 0;
            }
        }
        if (i == resets || !ok) break;
        release_default_resources();
        width = fullscreen ? sizes[(i + 1) % 3][0] : 640 + 37 * ((i * 7) % 11);
        height = fullscreen ? sizes[(i + 1) % 3][1] : 400 + 23 * ((i * 5) % 13);
        if (!fullscreen) SetWindowPos(hwnd, NULL, 0, 0, width, height, SWP_NOMOVE | SWP_NOZORDER);
        fill_params(&pp, hwnd, fullscreen);
        hr = IDirect3DDevice9_Reset(dev, &pp);
        if (FAILED(hr)) { printf("Reset %d to %dx%d: hr=0x%08lx\n", i + 1, width, height, hr); ok = 0; break; }
        hr = IDirect3DDevice9_TestCooperativeLevel(dev);
        if (FAILED(hr)) { printf("TestCooperativeLevel after reset %d: hr=0x%08lx\n", i + 1, hr); ok = 0; break; }
        if (!create_default_resources()) { ok = 0; break; }
    }
    printf("%d resets, %d frames\n", i, frames);

    release_default_resources();
    IDirect3DTexture9_Release(managed);
    IDirect3DPixelShader9_Release(ps_combine);
    IDirect3DPixelShader9_Release(ps_blur);
    IDirect3DPixelShader9_Release(ps_light);
    IDirect3DPixelShader9_Release(ps_gbuffer);
    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d3d);
    DestroyWindow(hwnd);
    printf("%s\n", ok ? "OK" : "ERROR: the device was lost");
    return ok ? 0 : 1;
}
