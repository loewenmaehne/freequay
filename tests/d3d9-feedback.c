/* d3d9-feedback: samples a texture that is bound as the render target at the same time, which
 * Direct3D 9 games do and DXVK supports with a barrier before each such draw. Apple GPUs render in
 * tiles and write a tile to memory only when the Metal render pass is done with it, so the read
 * sees the texture as it was before the pass unless the pass is split at that barrier (patch
 * moltenvk-0003) or the draw samples a copy (patch dxvk-0004, what DXVK does on MoltenVK).
 * Four checks on 1024x768 A8R8G8B8 render target textures:
 *   accumulate  16 full-screen draws into one pass, each reads its own pixel and adds 1/32:
 *               expects 128 everywhere; without either patch every draw sees 0 and leaves 8
 *   neighbor    a pattern, then one draw that reads the pixel to the right: expects the pattern
 *               shifted by one pixel. Within that one draw a tiler that is only split still reads
 *               a few pixels of a neighboring tile it already finished (OpenGL on the M1 does as
 *               well), so up to 0.1 % wrong pixels pass; with the copy there are none
 *   pingpong    40 passes between two textures, each reads the other one: no feedback at all
 *   mip         draws into mip 1 while sampling mip 0 of the same texture
 * Wrong pixels are counted per check, with their place within 32-pixel tiles.
 * Build: i686-w64-mingw32-gcc -O2 -o d3d9-feedback32.exe d3d9-feedback.c -ld3d9 -ld3dcompiler_47
 *        x86_64-w64-mingw32-gcc -O2 -o d3d9-feedback.exe d3d9-feedback.c -ld3d9 -ld3dcompiler_47 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 1024
#define H 768

struct vertex { float x, y, z, rhw, u, v; };

static const char shader[] =
    "sampler2D s0 : register(s0);\n"
    "float4 step : register(c0);\n"      /* x: one texel; z: amount to add */
    "float4 add(float2 uv : TEXCOORD0) : COLOR { return tex2D(s0, uv) + step.z; }\n"
    "float4 right(float2 uv : TEXCOORD0) : COLOR { return tex2D(s0, uv + float2(step.x, 0)); }\n"
    "float4 copy(float2 uv : TEXCOORD0) : COLOR { return tex2D(s0, uv); }\n"
    "float4 lod0(float2 uv : TEXCOORD0) : COLOR { return tex2Dlod(s0, float4(uv, 0, 0)); }\n"
    /* the pattern: a different value in every pixel of a 256-pixel period, in all channels */
    "float4 pattern(float2 uv : TEXCOORD0) : COLOR {\n"
    "    float2 p = floor(uv * float2(1024, 768));\n"
    "    return float4(frac(p.x / 256), frac(p.y / 256), frac((p.x + p.y) / 256), 1) * 256.0 / 255.0; }\n";

static IDirect3DDevice9 *dev;

struct result { int bad, col32[32], row32[32]; };

static IDirect3DPixelShader9 *compile(const char *entry)
{
    ID3DBlob *blob = NULL, *errors = NULL;
    IDirect3DPixelShader9 *ps = NULL;
    HRESULT hr = D3DCompile(shader, sizeof(shader) - 1, "d3d9-feedback", NULL, NULL, entry, "ps_3_0", 0, 0, &blob, &errors);
    if (FAILED(hr))
    {
        printf("D3DCompile %s: hr=0x%08lx %s\n", entry, hr, errors ? (char *)ID3D10Blob_GetBufferPointer(errors) : "");
        exit(1);
    }
    if (FAILED(IDirect3DDevice9_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(blob), &ps))) { printf("CreatePixelShader %s failed\n", entry); exit(1); }
    ID3D10Blob_Release(blob);
    return ps;
}

/* full-screen quad over a w x h target, with texel centers at the pixel centers */
static void quad(int w, int h)
{
    struct vertex v[4] =
    {
        {-0.5f,     -0.5f,     0.5f, 1.0f, 0.0f, 0.0f},
        {w - 0.5f,  -0.5f,     0.5f, 1.0f, 1.0f, 0.0f},
        {-0.5f,     h - 0.5f,  0.5f, 1.0f, 0.0f, 1.0f},
        {w - 0.5f,  h - 0.5f,  0.5f, 1.0f, 1.0f, 1.0f},
    };
    IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLESTRIP, 2, v, sizeof(*v));
}

static void target(IDirect3DTexture9 *tex, UINT level)
{
    IDirect3DSurface9 *s;
    IDirect3DTexture9_GetSurfaceLevel(tex, level, &s);
    IDirect3DDevice9_SetRenderTarget(dev, 0, s);
    IDirect3DSurface9_Release(s);
}

/* reads a level of a render target texture into memory, as BGRA rows of w pixels */
static unsigned char *readback(IDirect3DTexture9 *tex, UINT level, int w, int h)
{
    IDirect3DSurface9 *s, *sysmem;
    D3DLOCKED_RECT lr;
    unsigned char *out = malloc(w * h * 4);
    int y;
    IDirect3DTexture9_GetSurfaceLevel(tex, level, &s);
    IDirect3DDevice9_CreateOffscreenPlainSurface(dev, w, h, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM, &sysmem, NULL);
    if (FAILED(IDirect3DDevice9_GetRenderTargetData(dev, s, sysmem)) ||
        FAILED(IDirect3DSurface9_LockRect(sysmem, &lr, NULL, D3DLOCK_READONLY)))
    {
        printf("readback failed\n");
        exit(1);
    }
    for (y = 0; y < h; y++) memcpy(out + y * w * 4, (BYTE *)lr.pBits + y * lr.Pitch, w * 4);
    IDirect3DSurface9_UnlockRect(sysmem);
    IDirect3DSurface9_Release(sysmem);
    IDirect3DSurface9_Release(s);
    return out;
}

/* the value pattern() writes at pixel x, y, in BGRA */
static void expected_pattern(int x, int y, unsigned char *bgra)
{
    bgra[2] = x % 256; bgra[1] = y % 256; bgra[0] = (x + y) % 256; bgra[3] = 255;
}

static int same(int a, int b) { return abs(a - b) <= 2; }

static void wrong(struct result *r, int x, int y)
{
    r->bad++;
    r->col32[x % 32]++;
    r->row32[y % 32]++;
}

/* prints a check's result; passes with at most max_bad wrong pixels */
static int report(const char *name, const struct result *r, int total, int max_bad)
{
    int i, ok = r->bad <= max_bad;
    printf("%-10s %s: %d of %d pixels wrong", name, ok ? "ok" : "ERROR", r->bad, total);
    if (r->bad)
    {
        printf("; x mod 32:");
        for (i = 0; i < 32; i++) if (r->col32[i]) printf(" %d:%d", i, r->col32[i]);
        printf("; y mod 32:");
        for (i = 0; i < 32; i++) if (r->row32[i]) printf(" %d:%d", i, r->row32[i]);
    }
    printf("\n");
    return ok;
}

/* compares a w x h image with the pattern, shifted dx pixels to the left */
static void check_pattern(struct result *r, const unsigned char *img, int w, int h, int dx)
{
    unsigned char e[4];
    int x, y;
    memset(r, 0, sizeof(*r));
    for (y = 0; y < h; y++) for (x = 0; x < w; x++)
    {
        const unsigned char *p = img + (y * w + x) * 4;
        expected_pattern(x + dx < w ? x + dx : w - 1, y, e);
        if (!same(p[0], e[0]) || !same(p[1], e[1]) || !same(p[2], e[2])) wrong(r, x, y);
    }
}

int main(void)
{
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    D3DPRESENT_PARAMETERS pp = {0};
    D3DADAPTER_IDENTIFIER9 id;
    IDirect3D9 *d3d;
    IDirect3DTexture9 *a, *b, *m;
    IDirect3DPixelShader9 *ps_add, *ps_right, *ps_copy, *ps_lod0, *ps_pattern;
    IDirect3DSurface9 *back;
    struct result r;
    unsigned char *img, e[4];
    int ok = 1, i, x, y;
    float c[4];
    HWND hwnd;
    HRESULT hr;

    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = inst;
    wc.lpszClassName = L"d3d9feedback";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"d3d9feedback", L"freequay d3d9 feedback", WS_OVERLAPPED | WS_CAPTION | WS_VISIBLE,
                         100, 100, 640, 360, NULL, NULL, inst, NULL);

    if (!(d3d = Direct3DCreate9(D3D_SDK_VERSION))) { printf("Direct3DCreate9 failed\n"); return 1; }
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id)))
        printf("adapter: %s\n", id.Description);
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = 640;
    pp.BackBufferHeight = 360;
    pp.hDeviceWindow = hwnd;
    hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                 D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    printf("CreateDevice: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    ps_add = compile("add");
    ps_right = compile("right");
    ps_copy = compile("copy");
    ps_lod0 = compile("lod0");
    ps_pattern = compile("pattern");
    if (FAILED(IDirect3DDevice9_CreateTexture(dev, W, H, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A8R8G8B8, D3DPOOL_DEFAULT, &a, NULL)) ||
        FAILED(IDirect3DDevice9_CreateTexture(dev, W, H, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A8R8G8B8, D3DPOOL_DEFAULT, &b, NULL)) ||
        FAILED(IDirect3DDevice9_CreateTexture(dev, W, H, 2, D3DUSAGE_RENDERTARGET, D3DFMT_A8R8G8B8, D3DPOOL_DEFAULT, &m, NULL)))
    {
        printf("CreateTexture failed\n");
        return 1;
    }
    IDirect3DDevice9_GetBackBuffer(dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back);
    IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW | D3DFVF_TEX1);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, D3DZB_FALSE);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MIPFILTER, D3DTEXF_NONE);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_ADDRESSU, D3DTADDRESS_CLAMP);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_ADDRESSV, D3DTADDRESS_CLAMP);
    c[0] = 1.0f / W; c[1] = 1.0f / H; c[2] = 1.0f / 32; c[3] = 0;
    IDirect3DDevice9_SetPixelShaderConstantF(dev, 0, c, 1);

    /* accumulate: 16 draws, each reads its own pixel from the bound target and adds 1/32 */
    IDirect3DDevice9_BeginScene(dev);
    target(a, 0);
    IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, 0, 1.0f, 0);
    IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)a);
    IDirect3DDevice9_SetPixelShader(dev, ps_add);
    for (i = 0; i < 16; i++) quad(W, H);
    IDirect3DDevice9_SetTexture(dev, 0, NULL);
    IDirect3DDevice9_EndScene(dev);
    img = readback(a, 0, W, H);
    memset(&r, 0, sizeof(r));
    for (y = 0; y < H; y++) for (x = 0; x < W; x++)
        if (!same(img[(y * W + x) * 4 + 2], 128)) wrong(&r, x, y);
    if (r.bad) printf("accumulate: pixel 0,0 has %u, pixel 500,400 has %u (expected 128)\n", img[2], img[(400 * W + 500) * 4 + 2]);
    ok &= report("accumulate", &r, W * H, 0);
    free(img);

    /* neighbor: the pattern into a, then in the same pass one draw reads the pixel to the right */
    IDirect3DDevice9_BeginScene(dev);
    target(a, 0);
    IDirect3DDevice9_SetPixelShader(dev, ps_pattern);
    quad(W, H);
    IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)a);
    IDirect3DDevice9_SetPixelShader(dev, ps_right);
    quad(W, H);
    IDirect3DDevice9_SetTexture(dev, 0, NULL);
    IDirect3DDevice9_EndScene(dev);
    img = readback(a, 0, W, H);
    check_pattern(&r, img, W, H, 1);
    ok &= report("neighbor", &r, W * H, W * H / 1000);
    free(img);

    /* pingpong: pattern into a, then 40 copies a -> b -> a ...; reads never hit the target */
    IDirect3DDevice9_BeginScene(dev);
    target(a, 0);
    IDirect3DDevice9_SetPixelShader(dev, ps_pattern);
    quad(W, H);
    IDirect3DDevice9_SetPixelShader(dev, ps_copy);
    for (i = 0; i < 40; i++)
    {
        IDirect3DDevice9_SetTexture(dev, 0, NULL);
        target(i % 2 ? a : b, 0);
        IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)(i % 2 ? b : a));
        quad(W, H);
    }
    IDirect3DDevice9_SetTexture(dev, 0, NULL);
    IDirect3DDevice9_EndScene(dev);
    img = readback(a, 0, W, H);
    check_pattern(&r, img, W, H, 0);
    ok &= report("pingpong", &r, W * H, 0);
    free(img);

    /* mip: pattern into mip 0 of m, then draw into mip 1 while sampling mip 0 of m */
    IDirect3DDevice9_BeginScene(dev);
    target(m, 0);
    IDirect3DDevice9_SetPixelShader(dev, ps_pattern);
    quad(W, H);
    target(m, 1);
    IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)m);
    IDirect3DDevice9_SetPixelShader(dev, ps_lod0);
    quad(W / 2, H / 2);
    IDirect3DDevice9_SetTexture(dev, 0, NULL);
    IDirect3DDevice9_EndScene(dev);
    img = readback(m, 1, W / 2, H / 2);
    memset(&r, 0, sizeof(r));
    for (y = 0; y < H / 2; y++) for (x = 0; x < W / 2; x++)
    {
        const unsigned char *p = img + (y * (W / 2) + x) * 4;
        /* a mip 1 pixel center lies between four mip 0 texels; point sampling picks one of them */
        int found = 0, dx, dy;
        for (dy = 0; dy < 2; dy++) for (dx = 0; dx < 2; dx++)
        {
            expected_pattern(2 * x + dx, 2 * y + dy, e);
            if (same(p[0], e[0]) && same(p[1], e[1]) && same(p[2], e[2])) found = 1;
        }
        if (!found) wrong(&r, x, y);
    }
    ok &= report("mip", &r, W * H / 4, 0);
    free(img);

    IDirect3DDevice9_SetRenderTarget(dev, 0, back);
    IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);

    /* release everything before leaving, as a game does; DXVK finishes its work on Release */
    IDirect3DSurface9_Release(back);
    IDirect3DTexture9_Release(m);
    IDirect3DTexture9_Release(b);
    IDirect3DTexture9_Release(a);
    IDirect3DPixelShader9_Release(ps_pattern);
    IDirect3DPixelShader9_Release(ps_lod0);
    IDirect3DPixelShader9_Release(ps_copy);
    IDirect3DPixelShader9_Release(ps_right);
    IDirect3DPixelShader9_Release(ps_add);
    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d3d);
    DestroyWindow(hwnd);
    printf("%s\n", ok ? "OK" : "ERROR: some checks drew wrong pixels");
    return ok ? 0 : 1;
}
