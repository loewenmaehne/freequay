/* d3d9-shadow: Direct3D 9 hardware shadow map. Renders depth 0.25 into the left half of a D24S8
 * depth texture (the right half keeps 1.0), then samples it in a ps_2_0 shader with tex2Dproj and
 * a reference depth of 0.5. Sampling a depth texture compares: the left half must come out black,
 * the right half white. This is the depth-compare branch DXVK builds for every sampler.
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d9-shadow.exe d3d9-shadow.c -ld3d9 -ld3dcompiler_47 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

#define W 512
#define H 256
#define S 256

struct tvertex { float x, y, z, rhw; };
struct vertex { float x, y, z, u, v; };

static const char shader[] =
    "struct vs_in { float4 pos : POSITION; float2 uv : TEXCOORD0; };\n"
    "struct vs_out { float4 pos : POSITION; float2 uv : TEXCOORD0; };\n"
    "vs_out vs(vs_in i) { vs_out o; o.pos = i.pos; o.uv = i.uv; return o; }\n"
    "sampler2D s0 : register(s0);\n"
    "float4 ps(float2 uv : TEXCOORD0) : COLOR { return tex2Dproj(s0, float4(uv, 0.5, 1.0)).rrrr; }\n";

static ID3DBlob *compile(const char *entry, const char *target)
{
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT hr = D3DCompile(shader, sizeof(shader) - 1, "d3d9-shadow", NULL, NULL, entry, target, 0, 0, &blob, &errors);
    if (FAILED(hr))
    {
        printf("D3DCompile %s: hr=0x%08lx %s\n", entry, hr, errors ? (char *)ID3D10Blob_GetBufferPointer(errors) : "");
        return NULL;
    }
    return blob;
}

int main(void)
{
    /* left half of the shadow map, pre-transformed, at depth 0.25 */
    static const struct tvertex occluder[4] =
    {
        {0.0f, 0.0f, 0.25f, 1.0f}, {S / 2.0f, 0.0f, 0.25f, 1.0f},
        {0.0f, (float)S, 0.25f, 1.0f}, {S / 2.0f, (float)S, 0.25f, 1.0f},
    };
    static const struct vertex quad[4] =
    {
        {-1.0f,  1.0f, 0.5f, 0.0f, 0.0f}, { 1.0f,  1.0f, 0.5f, 1.0f, 0.0f},
        {-1.0f, -1.0f, 0.5f, 0.0f, 1.0f}, { 1.0f, -1.0f, 0.5f, 1.0f, 1.0f},
    };
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    D3DPRESENT_PARAMETERS pp = {0};
    D3DADAPTER_IDENTIFIER9 id;
    D3DLOCKED_RECT lr;
    IDirect3D9 *d3d;
    IDirect3DDevice9 *dev = NULL;
    IDirect3DTexture9 *shadow = NULL;
    IDirect3DSurface9 *shadow_surface = NULL, *color = NULL, *back = NULL, *sysmem = NULL;
    IDirect3DVertexShader9 *vs = NULL;
    IDirect3DPixelShader9 *ps = NULL;
    ID3DBlob *vsb, *psb;
    HRESULT hr;
    HWND hwnd;
    int ok = 0;

    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = inst;
    wc.lpszClassName = L"d3d9shadow";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"d3d9shadow", L"freequay d3d9 shadow", WS_OVERLAPPED | WS_CAPTION | WS_VISIBLE,
                         100, 100, W, H, NULL, NULL, inst, NULL);
    if (!(d3d = Direct3DCreate9(D3D_SDK_VERSION))) { printf("Direct3DCreate9 failed\n"); return 1; }
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id)))
        printf("adapter: %s\n", id.Description);
    hr = IDirect3D9_CheckDeviceFormat(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8,
                                      D3DUSAGE_DEPTHSTENCIL, D3DRTYPE_TEXTURE, D3DFMT_D24S8);
    printf("D24S8 depth texture: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

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

    /* pass 1: depth only into the shadow map */
    hr = IDirect3DDevice9_CreateTexture(dev, S, S, 1, D3DUSAGE_DEPTHSTENCIL, D3DFMT_D24S8, D3DPOOL_DEFAULT, &shadow, NULL);
    if (FAILED(hr)) { printf("shadow texture: hr=0x%08lx\n", hr); return 1; }
    IDirect3DTexture9_GetSurfaceLevel(shadow, 0, &shadow_surface);
    IDirect3DDevice9_CreateRenderTarget(dev, S, S, D3DFMT_X8R8G8B8, D3DMULTISAMPLE_NONE, 0, FALSE, &color, NULL);
    IDirect3DDevice9_GetBackBuffer(dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back);
    IDirect3DDevice9_SetRenderTarget(dev, 0, color);
    IDirect3DDevice9_SetDepthStencilSurface(dev, shadow_surface);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, D3DZB_TRUE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZWRITEENABLE, TRUE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZFUNC, D3DCMP_LESSEQUAL);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
    IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, 0, 1.0f, 0);
    IDirect3DDevice9_BeginScene(dev);
    IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW);
    IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLESTRIP, 2, occluder, sizeof(*occluder));
    IDirect3DDevice9_EndScene(dev);

    /* pass 2: sample the shadow map with reference depth 0.5 */
    IDirect3DDevice9_SetRenderTarget(dev, 0, back);
    IDirect3DDevice9_SetDepthStencilSurface(dev, NULL);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, D3DZB_FALSE);
    IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(51, 153, 255), 1.0f, 0);
    IDirect3DDevice9_BeginScene(dev);
    IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZ | D3DFVF_TEX1);
    IDirect3DDevice9_SetVertexShader(dev, vs);
    IDirect3DDevice9_SetPixelShader(dev, ps);
    IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)shadow);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLESTRIP, 2, quad, sizeof(*quad));
    IDirect3DDevice9_EndScene(dev);

    IDirect3DDevice9_CreateOffscreenPlainSurface(dev, W, H, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &sysmem, NULL);
    hr = IDirect3DDevice9_GetRenderTargetData(dev, back, sysmem);
    if (SUCCEEDED(hr) && SUCCEEDED(IDirect3DSurface9_LockRect(sysmem, &lr, NULL, D3DLOCK_READONLY)))
    {
        const unsigned char *left = (const unsigned char *)lr.pBits + (H / 2) * lr.Pitch + (W / 4) * 4;
        const unsigned char *right = (const unsigned char *)lr.pBits + (H / 2) * lr.Pitch + (3 * W / 4) * 4;
        printf("left (occluded, expected 0 0 0): %u %u %u\n", left[2], left[1], left[0]);
        printf("right (lit, expected 255 255 255): %u %u %u\n", right[2], right[1], right[0]);
        ok = left[0] < 8 && left[1] < 8 && left[2] < 8 && right[0] > 247 && right[1] > 247 && right[2] > 247;
        IDirect3DSurface9_UnlockRect(sysmem);
    }
    else
        printf("readback: hr=0x%08lx\n", hr);
    IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);

    IDirect3DSurface9_Release(sysmem);
    IDirect3DSurface9_Release(back);
    IDirect3DSurface9_Release(color);
    IDirect3DSurface9_Release(shadow_surface);
    IDirect3DTexture9_Release(shadow);
    IDirect3DPixelShader9_Release(ps);
    IDirect3DVertexShader9_Release(vs);
    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d3d);
    DestroyWindow(hwnd);
    printf("%s\n", ok ? "OK" : "ERROR: the image is wrong");
    return ok ? 0 : 1;
}
