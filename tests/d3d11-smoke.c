/* d3d11-smoke: opens a window and draws a colored triangle with HLSL shaders through
 * Direct3D 11 (checks the backend's shader translation). Reads the image back, checks two
 * pixels, saves it as d3d11-smoke.bmp and presents for 3 seconds.
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d11-smoke.exe d3d11-smoke.c -ld3d11 -ldxgi -ld3dcompiler_47 -luuid */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <stdio.h>

#define W 640
#define H 360

static const char shader_src[] =
    "struct v2p { float4 pos : SV_Position; float4 col : COLOR; };\n"
    "v2p vs(float2 pos : POSITION, float4 col : COLOR)\n"
    "{ v2p o; o.pos = float4(pos, 0.0, 1.0); o.col = col; return o; }\n"
    "float4 ps(v2p i) : SV_Target { return i.col; }\n";

struct vertex { float x, y; float r, g, b, a; };

static void print_wide(const char *label, const WCHAR *text)
{
    char buf[256];
    WideCharToMultiByte(CP_UTF8, 0, text, -1, buf, sizeof(buf), NULL, NULL);
    printf("%s%s\n", label, buf);
}

static ID3DBlob *compile(const char *entry, const char *target)
{
    ID3DBlob *code = NULL, *errors = NULL;
    HRESULT hr = D3DCompile(shader_src, sizeof(shader_src) - 1, "smoke", NULL, NULL, entry, target, 0, 0,
                            &code, &errors);
    if (FAILED(hr))
    {
        printf("D3DCompile %s: hr=0x%08lx %s\n", entry, hr,
               errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "");
        return NULL;
    }
    return code;
}

static void save_bmp(const char *path, const unsigned char *rgba, UINT pitch)
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
        for (x = 0; x < W; x++)
        {
            const unsigned char *p = rgba + y * pitch + x * 4;
            unsigned char bgr[3] = {p[2], p[1], p[0]};
            fwrite(bgr, 3, 1, f);
        }
    fclose(f);
}

static void draw(ID3D11DeviceContext *ctx, ID3D11RenderTargetView *rtv)
{
    static const float clear[4] = {0.2f, 0.6f, 1.0f, 1.0f};
    D3D11_VIEWPORT vp = {0, 0, W, H, 0, 1};

    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
}

int main(void)
{
    static const struct vertex tri[3] =
    {
        { 0.0f,  0.8f, 1, 0, 0, 1},
        { 0.7f, -0.7f, 0, 1, 0, 1},
        {-0.7f, -0.7f, 0, 0, 1, 1},
    };
    static const D3D11_INPUT_ELEMENT_DESC layout_desc[] =
    {
        {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
    };
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    DXGI_SWAP_CHAIN_DESC sd = {0};
    D3D11_BUFFER_DESC bd = {0};
    D3D11_SUBRESOURCE_DATA init = {0};
    D3D11_TEXTURE2D_DESC td;
    D3D11_MAPPED_SUBRESOURCE map;
    DXGI_ADAPTER_DESC ad_desc;
    D3D_FEATURE_LEVEL level = 0;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *sc = NULL;
    IDXGIDevice *dxgi_dev = NULL;
    IDXGIAdapter *adapter = NULL;
    ID3D11Texture2D *back = NULL, *staging = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    ID3D11InputLayout *layout = NULL;
    ID3D11Buffer *vb = NULL;
    ID3DBlob *vs_code, *ps_code;
    UINT stride = sizeof(struct vertex), offset = 0;
    DWORD start;
    HRESULT hr;
    HWND hwnd;
    int frames = 0, ok = 1;

    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = inst;
    wc.lpszClassName = L"d3d11smoke";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"d3d11smoke", L"freequay d3d11 smoke", WS_OVERLAPPED | WS_CAPTION | WS_VISIBLE,
                         100, 100, W, H, NULL, NULL, inst, NULL);

    sd.BufferCount = 2;
    sd.BufferDesc.Width = W;
    sd.BufferDesc.Height = H;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                       D3D11_SDK_VERSION, &sd, &sc, &dev, &level, &ctx);
    printf("D3D11CreateDeviceAndSwapChain: hr=0x%08lx feature_level=0x%x\n", hr, level);
    if (FAILED(hr)) return 1;

    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi_dev))
        && SUCCEEDED(IDXGIDevice_GetAdapter(dxgi_dev, &adapter))
        && SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &ad_desc)))
    {
        print_wide("adapter: ", ad_desc.Description);
        printf("video memory: %llu MB\n", (unsigned long long)(ad_desc.DedicatedVideoMemory >> 20));
    }

    if (!(vs_code = compile("vs", "vs_4_0")) || !(ps_code = compile("ps", "ps_4_0"))) return 1;
    ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vs_code),
                                    ID3D10Blob_GetBufferSize(vs_code), NULL, &vs);
    ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(ps_code),
                                   ID3D10Blob_GetBufferSize(ps_code), NULL, &ps);
    ID3D11Device_CreateInputLayout(dev, layout_desc, 2, ID3D10Blob_GetBufferPointer(vs_code),
                                   ID3D10Blob_GetBufferSize(vs_code), &layout);
    bd.ByteWidth = sizeof(tri);
    bd.Usage = D3D11_USAGE_IMMUTABLE;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    init.pSysMem = tri;
    ID3D11Device_CreateBuffer(dev, &bd, &init, &vb);

    ID3D11DeviceContext_IASetInputLayout(ctx, layout);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &vb, &stride, &offset);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);

    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&back);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv);

    /* draw once and read back */
    ID3D11Texture2D_GetDesc(back, &td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    td.MiscFlags = 0;
    ID3D11Device_CreateTexture2D(dev, &td, NULL, &staging);
    draw(ctx, rtv);
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)back);
    hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
    if (SUCCEEDED(hr))
    {
        const unsigned char *corner = map.pData;
        const unsigned char *center = (const unsigned char *)map.pData + (H / 2) * map.RowPitch + (W / 2) * 4;
        printf("pixel top left: %u %u %u (background, expected about 51 153 255)\n", corner[0], corner[1], corner[2]);
        printf("pixel center: %u %u %u (triangle, blended color)\n", center[0], center[1], center[2]);
        if (abs(corner[0] - 51) > 3 || abs(corner[1] - 153) > 3 || corner[2] < 250) ok = 0;
        if (center[0] == corner[0] && center[1] == corner[1] && center[2] == corner[2]) ok = 0;
        save_bmp("d3d11-smoke.bmp", map.pData, map.RowPitch);
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    }
    else
    {
        printf("Map: hr=0x%08lx\n", hr);
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
        draw(ctx, rtv);
        hr = IDXGISwapChain_Present(sc, 1, 0);
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
