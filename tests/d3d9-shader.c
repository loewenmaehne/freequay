/* d3d9-shader: draws a textured quad with Direct3D 9 shaders (vs_2_0 and ps_2_0 compiled from
 * HLSL at run time) and point sampling, reads the image back and checks the four quadrants for
 * the four texel colors. Unlike d3d9-smoke this goes through a pixel shader with a sampler, as
 * almost every Direct3D 9 game does; DXVK builds a depth-compare variant of every sampler there.
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d9-shader.exe d3d9-shader.c -ld3d9 -ld3dcompiler_47 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

#define W 640
#define H 360

struct vertex { float x, y, z, u, v; };

static const char shader[] =
    "struct vs_in { float4 pos : POSITION; float2 uv : TEXCOORD0; };\n"
    "struct vs_out { float4 pos : POSITION; float2 uv : TEXCOORD0; };\n"
    "vs_out vs(vs_in i) { vs_out o; o.pos = i.pos; o.uv = i.uv; return o; }\n"
    "sampler2D s0 : register(s0);\n"
    "float4 ps(float2 uv : TEXCOORD0) : COLOR { return tex2D(s0, uv); }\n";

static ID3DBlob *compile(const char *entry, const char *target)
{
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT hr = D3DCompile(shader, sizeof(shader) - 1, "d3d9-shader", NULL, NULL, entry, target, 0, 0, &blob, &errors);
    if (FAILED(hr))
    {
        printf("D3DCompile %s: hr=0x%08lx %s\n", entry, hr, errors ? (char *)ID3D10Blob_GetBufferPointer(errors) : "");
        return NULL;
    }
    return blob;
}

static int close_to(const unsigned char *bgra, int r, int g, int b)
{
    return abs(bgra[2] - r) < 8 && abs(bgra[1] - g) < 8 && abs(bgra[0] - b) < 8;
}

int main(void)
{
    static const struct vertex quad[4] =
    {
        {-1.0f,  1.0f, 0.5f, 0.0f, 0.0f},
        { 1.0f,  1.0f, 0.5f, 1.0f, 0.0f},
        {-1.0f, -1.0f, 0.5f, 0.0f, 1.0f},
        { 1.0f, -1.0f, 0.5f, 1.0f, 1.0f},
    };
    static const DWORD texels[4] = {0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff};
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    D3DPRESENT_PARAMETERS pp = {0};
    D3DADAPTER_IDENTIFIER9 id;
    D3DLOCKED_RECT lr;
    IDirect3D9 *d3d;
    IDirect3DDevice9 *dev = NULL;
    IDirect3DTexture9 *tex = NULL;
    IDirect3DVertexShader9 *vs = NULL;
    IDirect3DPixelShader9 *ps = NULL;
    IDirect3DSurface9 *back = NULL, *sysmem = NULL;
    ID3DBlob *vsb, *psb;
    HRESULT hr;
    HWND hwnd;
    int ok = 1, i;

    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = inst;
    wc.lpszClassName = L"d3d9shader";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"d3d9shader", L"freequay d3d9 shader", WS_OVERLAPPED | WS_CAPTION | WS_VISIBLE,
                         100, 100, W, H, NULL, NULL, inst, NULL);

    if (!(d3d = Direct3DCreate9(D3D_SDK_VERSION))) { printf("Direct3DCreate9 failed\n"); return 1; }
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id)))
        printf("adapter: %s\n", id.Description);
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = W;
    pp.BackBufferHeight = H;
    pp.hDeviceWindow = hwnd;
    hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                 D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    printf("CreateDevice: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    if (!(vsb = compile("vs", "vs_2_0")) || !(psb = compile("ps", "ps_2_0"))) return 1;
    if (FAILED(IDirect3DDevice9_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vsb), &vs)) ||
        FAILED(IDirect3DDevice9_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(psb), &ps)))
    {
        printf("creating the shaders failed\n");
        return 1;
    }

    hr = IDirect3DDevice9_CreateTexture(dev, 2, 2, 1, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &tex, NULL);
    if (FAILED(hr) || FAILED(IDirect3DTexture9_LockRect(tex, 0, &lr, NULL, 0))) { printf("texture: hr=0x%08lx\n", hr); return 1; }
    for (i = 0; i < 4; i++) ((DWORD *)((BYTE *)lr.pBits + (i / 2) * lr.Pitch))[i % 2] = texels[i];
    IDirect3DTexture9_UnlockRect(tex, 0);

    IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(51, 153, 255), 1.0f, 0);
    IDirect3DDevice9_BeginScene(dev);
    IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZ | D3DFVF_TEX1);
    IDirect3DDevice9_SetVertexShader(dev, vs);
    IDirect3DDevice9_SetPixelShader(dev, ps);
    IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)tex);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
    IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLESTRIP, 2, quad, sizeof(*quad));
    IDirect3DDevice9_EndScene(dev);

    IDirect3DDevice9_GetBackBuffer(dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back);
    IDirect3DDevice9_CreateOffscreenPlainSurface(dev, W, H, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &sysmem, NULL);
    hr = IDirect3DDevice9_GetRenderTargetData(dev, back, sysmem);
    if (SUCCEEDED(hr) && SUCCEEDED(IDirect3DSurface9_LockRect(sysmem, &lr, NULL, D3DLOCK_READONLY)))
    {
        const unsigned char *p = lr.pBits;
        const unsigned char *q[4] =
        {
            p + (H / 4) * lr.Pitch + (W / 4) * 4, p + (H / 4) * lr.Pitch + (3 * W / 4) * 4,
            p + (3 * H / 4) * lr.Pitch + (W / 4) * 4, p + (3 * H / 4) * lr.Pitch + (3 * W / 4) * 4,
        };
        for (i = 0; i < 4; i++) printf("quadrant %d: %u %u %u\n", i, q[i][2], q[i][1], q[i][0]);
        ok = close_to(q[0], 255, 0, 0) && close_to(q[1], 0, 255, 0) && close_to(q[2], 0, 0, 255) && close_to(q[3], 255, 255, 255);
        IDirect3DSurface9_UnlockRect(sysmem);
    }
    else
    {
        printf("readback: hr=0x%08lx\n", hr);
        ok = 0;
    }
    IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);

    /* release everything before leaving, as a game does; DXVK finishes its work on Release */
    IDirect3DSurface9_Release(sysmem);
    IDirect3DSurface9_Release(back);
    IDirect3DTexture9_Release(tex);
    IDirect3DPixelShader9_Release(ps);
    IDirect3DVertexShader9_Release(vs);
    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d3d);
    DestroyWindow(hwnd);
    printf("%s\n", ok ? "OK" : "ERROR: the image is wrong");
    return ok ? 0 : 1;
}
