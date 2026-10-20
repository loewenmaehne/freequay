/* d3d9-depth-read: samples an INTZ depth texture while the same texture is the depth buffer of the
 * draw, with depth writes off, as GTA IV's post-processing does. Direct3D 9 and Vulkan allow this
 * because nothing writes the depth. On Apple GPUs each tile of the render pass stores its depth
 * back to memory when it is done, also when nothing changed, and the draw reads depth from
 * neighboring tiles at the same time. The first pass writes a depth pattern, the second pass reads
 * the depth at the pixel and 16 pixels away in four directions and writes the largest difference
 * to the expected values. Wrong pixels are counted with their place within 16- and 32-pixel tiles.
 *   d3d9-depth-read [rounds] [hdr,stencil]   default 20 rounds; hdr renders into A16B16G16R16F as
 *                                            GTA IV does, stencil has the reading pass write stencil
 * Build: i686-w64-mingw32-gcc -O2 -o d3d9-depth-read32.exe d3d9-depth-read.c -ld3d9 -ld3dcompiler_47
 *        x86_64-w64-mingw32-gcc -O2 -o d3d9-depth-read.exe d3d9-depth-read.c -ld3d9 -ld3dcompiler_47 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <d3dcompiler.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 1024
#define H 768
#define OFS 16

struct vertex { float x, y, z, rhw, u, v; };

static const char shader[] =
    "sampler2D depth : register(s0);\n"
    "float4 px : register(c0);\n"   /* x, y: one texel */
    /* the pattern for texel q: depth that changes in x and y and in steps, different in every tile */
    "float expected(float2 q) {\n"
    "    return sin(q.x * 0.37 + q.y * 0.23 + floor(q.x / 7) * 1.3 + floor(q.y / 5) * 0.7) * 0.45 + 0.5; }\n"
    "struct ps_out { float4 c : COLOR0; float d : DEPTH; };\n"
    "ps_out write(float2 uv : TEXCOORD0) { ps_out o; o.c = 0; o.d = expected(floor(uv * float2(1024, 768))); return o; }\n"
    "float4 read(float2 uv : TEXCOORD0) : COLOR {\n"
    "    float2 base = floor(uv * float2(1024, 768));\n"
    "    float e = 0;\n"
    "    float2 o[5] = { float2(0, 0), float2(16, 0), float2(-16, 0), float2(0, 16), float2(0, -16) };\n"
    "    for (int i = 0; i < 5; i++) {\n"
    "        float2 q = clamp(base + o[i], float2(0, 0), float2(1023, 767));\n"
    "        float d = tex2Dlod(depth, float4((q + 0.5) * px.xy, 0, 0)).r;\n"
    "        e = max(e, abs(d - expected(q)));\n"
    "    }\n"
    "    return float4(e * 64, 0, 0, 1); }\n";

static IDirect3DDevice9 *dev;

static IDirect3DPixelShader9 *compile(const char *entry)
{
    ID3DBlob *blob = NULL, *errors = NULL;
    IDirect3DPixelShader9 *ps = NULL;
    HRESULT hr = D3DCompile(shader, sizeof(shader) - 1, "d3d9-depth-read", NULL, NULL, entry, "ps_3_0", 0, 0, &blob, &errors);
    if (FAILED(hr))
    {
        printf("D3DCompile %s: hr=0x%08lx %s\n", entry, hr, errors ? (char *)ID3D10Blob_GetBufferPointer(errors) : "");
        exit(1);
    }
    if (FAILED(IDirect3DDevice9_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(blob), &ps))) { printf("CreatePixelShader %s failed\n", entry); exit(1); }
    ID3D10Blob_Release(blob);
    return ps;
}

static void quad(void)
{
    static const struct vertex v[4] =
    {
        {-0.5f,     -0.5f,     0.5f, 1.0f, 0.0f, 0.0f},
        {W - 0.5f,  -0.5f,     0.5f, 1.0f, 1.0f, 0.0f},
        {-0.5f,     H - 0.5f,  0.5f, 1.0f, 0.0f, 1.0f},
        {W - 0.5f,  H - 0.5f,  0.5f, 1.0f, 1.0f, 1.0f},
    };
    IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLESTRIP, 2, v, sizeof(v[0]));
}

int main(int argc, char **argv)
{
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    D3DPRESENT_PARAMETERS pp = {0};
    D3DADAPTER_IDENTIFIER9 id;
    D3DLOCKED_RECT lr;
    IDirect3D9 *d3d;
    IDirect3DTexture9 *ztex, *color;
    IDirect3DSurface9 *zsurf, *csurf, *sysmem, *back;
    IDirect3DPixelShader9 *ps_write, *ps_read;
    int rounds = argc > 1 ? atoi(argv[1]) : 20, r, x, y, bad, total_bad = 0, worst = 0;
    int hdr = argc > 2 && strstr(argv[2], "hdr") != NULL, stencil = argc > 2 && strstr(argv[2], "stencil") != NULL;
    IDirect3DTexture9 *hdrtex = NULL;
    IDirect3DSurface9 *hdrsurf = NULL;
    int col16[16] = {0}, row16[16] = {0}, col32[32] = {0}, row32[32] = {0};
    float c[4] = {1.0f / W, 1.0f / H, 0, 0};
    HWND hwnd;
    HRESULT hr;

    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = inst;
    wc.lpszClassName = L"d3d9depthread";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"d3d9depthread", L"freequay d3d9 depth read", WS_OVERLAPPED | WS_CAPTION | WS_VISIBLE,
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
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    printf("CreateDevice: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;
    if (FAILED(IDirect3DDevice9_CreateTexture(dev, W, H, 1, D3DUSAGE_DEPTHSTENCIL, (D3DFORMAT)MAKEFOURCC('I','N','T','Z'), D3DPOOL_DEFAULT, &ztex, NULL)))
    {
        printf("INTZ is not supported\n");
        return 1;
    }
    IDirect3DDevice9_CreateTexture(dev, W, H, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A8R8G8B8, D3DPOOL_DEFAULT, &color, NULL);
    IDirect3DTexture9_GetSurfaceLevel(ztex, 0, &zsurf);
    IDirect3DTexture9_GetSurfaceLevel(color, 0, &csurf);
    if (hdr)
    {
        IDirect3DDevice9_CreateTexture(dev, W, H, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A16B16G16R16F, D3DPOOL_DEFAULT, &hdrtex, NULL);
        IDirect3DTexture9_GetSurfaceLevel(hdrtex, 0, &hdrsurf);
    }
    printf("render target %s%s\n", hdr ? "A16B16G16R16F" : "A8R8G8B8", stencil ? ", the reading pass writes stencil" : "");
    IDirect3DDevice9_CreateOffscreenPlainSurface(dev, W, H, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM, &sysmem, NULL);
    IDirect3DDevice9_GetBackBuffer(dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back);
    ps_write = compile("write");
    ps_read = compile("read");
    IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW | D3DFVF_TEX1);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
    IDirect3DDevice9_SetPixelShaderConstantF(dev, 0, c, 1);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MIPFILTER, D3DTEXF_NONE);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_ADDRESSU, D3DTADDRESS_CLAMP);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_ADDRESSV, D3DTADDRESS_CLAMP);

    for (r = 0; r < rounds; r++)
    {
        IDirect3DDevice9_BeginScene(dev);
        /* pass 1: write the depth pattern */
        IDirect3DDevice9_SetRenderTarget(dev, 0, hdr ? hdrsurf : csurf);
        IDirect3DDevice9_SetDepthStencilSurface(dev, zsurf);
        IDirect3DDevice9_SetTexture(dev, 0, NULL);
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, 0, 1.0f, 0);
        IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, D3DZB_TRUE);
        IDirect3DDevice9_SetRenderState(dev, D3DRS_ZWRITEENABLE, TRUE);
        IDirect3DDevice9_SetRenderState(dev, D3DRS_ZFUNC, D3DCMP_ALWAYS);
        IDirect3DDevice9_SetPixelShader(dev, ps_write);
        quad();
        /* pass 2: read the depth with the same texture still bound as depth buffer, read-only */
        IDirect3DDevice9_SetRenderState(dev, D3DRS_ZWRITEENABLE, FALSE);
        IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)ztex);
        if (stencil)
        {
            IDirect3DDevice9_SetRenderState(dev, D3DRS_STENCILENABLE, TRUE);
            IDirect3DDevice9_SetRenderState(dev, D3DRS_STENCILFUNC, D3DCMP_ALWAYS);
            IDirect3DDevice9_SetRenderState(dev, D3DRS_STENCILPASS, D3DSTENCILOP_INCRSAT);
        }
        IDirect3DDevice9_SetPixelShader(dev, ps_read);
        quad();
        IDirect3DDevice9_SetRenderState(dev, D3DRS_STENCILENABLE, FALSE);
        IDirect3DDevice9_SetTexture(dev, 0, NULL);
        IDirect3DDevice9_EndScene(dev);
        if (hdr) IDirect3DDevice9_StretchRect(dev, hdrsurf, NULL, csurf, NULL, D3DTEXF_POINT);

        if (FAILED(IDirect3DDevice9_GetRenderTargetData(dev, csurf, sysmem)) ||
            FAILED(IDirect3DSurface9_LockRect(sysmem, &lr, NULL, D3DLOCK_READONLY)))
        {
            printf("readback failed\n");
            return 1;
        }
        for (bad = 0, y = 0; y < H; y++)
            for (x = 0; x < W; x++)
            {
                const BYTE *p = (const BYTE *)lr.pBits + y * lr.Pitch + x * 4;
                /* red is 64 times the largest depth error; a few units are rounding of D24 vs D32 */
                if (p[2] > 16)
                {
                    bad++;
                    col16[x % 16]++; row16[y % 16]++; col32[x % 32]++; row32[y % 32]++;
                    if (p[2] > worst) worst = p[2];
                }
            }
        IDirect3DSurface9_UnlockRect(sysmem);
        total_bad += bad;
        IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
    }

    printf("%d rounds, %d wrong pixels (worst red %d)\n", rounds, total_bad, worst);
    if (total_bad)
    {
        int i;
        printf("x mod 32:");
        for (i = 0; i < 32; i++) if (col32[i]) printf(" %d:%d", i, col32[i]);
        printf("\ny mod 32:");
        for (i = 0; i < 32; i++) if (row32[i]) printf(" %d:%d", i, row32[i]);
        printf("\n");
    }

    IDirect3DSurface9_Release(back);
    IDirect3DSurface9_Release(sysmem);
    IDirect3DSurface9_Release(csurf);
    IDirect3DSurface9_Release(zsurf);
    IDirect3DTexture9_Release(color);
    if (hdrsurf) IDirect3DSurface9_Release(hdrsurf);
    if (hdrtex) IDirect3DTexture9_Release(hdrtex);
    IDirect3DTexture9_Release(ztex);
    IDirect3DPixelShader9_Release(ps_read);
    IDirect3DPixelShader9_Release(ps_write);
    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d3d);
    DestroyWindow(hwnd);
    printf("%s\n", total_bad ? "ERROR: the depth read back wrong" : "OK");
    return total_bad ? 1 : 0;
}
