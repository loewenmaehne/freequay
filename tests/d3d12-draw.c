/* d3d12-draw: draws a colored triangle with Direct3D 12 into an offscreen render target, copies
 * it to a readback buffer and checks two pixels: the corner must have the clear color, the center
 * a blend of the vertex colors. Shaders are HLSL compiled at run time to DXBC (shader model 5.0).
 * Checks whether a DirectX 12 backend (D3DMetal or vkd3d) really renders, not only starts.
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d12-draw.exe d3d12-draw.c -ld3d12 -ldxgi -ld3dcompiler_47 */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <initguid.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>

#define W 256
#define H 256

static const char shader[] =
    "struct vs_out { float4 pos : SV_Position; float4 col : COLOR; };\n"
    "vs_out vs(uint id : SV_VertexID)\n"
    "{\n"
    "    float2 p[3] = { float2(0.0, 0.7), float2(0.7, -0.7), float2(-0.7, -0.7) };\n"
    "    float3 c[3] = { float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1) };\n"
    "    vs_out o;\n"
    "    o.pos = float4(p[id], 0.0, 1.0);\n"
    "    o.col = float4(c[id], 1.0);\n"
    "    return o;\n"
    "}\n"
    "float4 ps(vs_out i) : SV_Target { return i.col; }\n";

static ID3DBlob *compile(const char *entry, const char *target)
{
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT hr = D3DCompile(shader, sizeof(shader) - 1, "d3d12-draw", NULL, NULL, entry, target, 0, 0, &blob, &errors);
    if (FAILED(hr))
    {
        printf("D3DCompile %s: hr=0x%08lx %s\n", entry, hr, errors ? (char *)ID3D10Blob_GetBufferPointer(errors) : "");
        return NULL;
    }
    return blob;
}

static void barrier(ID3D12GraphicsCommandList *list, ID3D12Resource *res, D3D12_RESOURCE_STATES from, D3D12_RESOURCE_STATES to)
{
    D3D12_RESOURCE_BARRIER b = {0};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = res;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = from;
    b.Transition.StateAfter = to;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}

int main(void)
{
    IDXGIFactory4 *factory = NULL;
    IDXGIAdapter1 *adapter = NULL;
    DXGI_ADAPTER_DESC1 ad;
    ID3D12Device *device = NULL;
    ID3D12CommandQueue *queue = NULL;
    ID3D12CommandAllocator *alloc = NULL;
    ID3D12GraphicsCommandList *list = NULL;
    ID3D12DescriptorHeap *rtv_heap = NULL;
    ID3D12Resource *target = NULL, *readback = NULL;
    ID3D12RootSignature *root = NULL;
    ID3D12PipelineState *pso = NULL;
    ID3D12Fence *fence = NULL;
    ID3DBlob *vs, *ps, *sig = NULL, *err = NULL;
    D3D12_COMMAND_QUEUE_DESC qd = {0};
    D3D12_DESCRIPTOR_HEAP_DESC hd = {0};
    D3D12_HEAP_PROPERTIES heap = {0};
    D3D12_RESOURCE_DESC rd = {0};
    D3D12_CLEAR_VALUE clear = {0};
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    D3D12_ROOT_SIGNATURE_DESC rsd = {0};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {0};
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    D3D12_TEXTURE_COPY_LOCATION dst = {0}, src = {0};
    D3D12_VIEWPORT vp = {0, 0, W, H, 0, 1};
    D3D12_RECT sc = {0, 0, W, H};
    const float color[4] = {0.2f, 0.6f, 1.0f, 1.0f};
    UINT64 total;
    HANDLE event;
    unsigned char *pixels;
    char name[128];
    HRESULT hr;
    int ok;

    hr = CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory);
    printf("CreateDXGIFactory1: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;
    if (SUCCEEDED(IDXGIFactory4_EnumAdapters1(factory, 0, &adapter)) && SUCCEEDED(IDXGIAdapter1_GetDesc1(adapter, &ad)))
    {
        WideCharToMultiByte(CP_UTF8, 0, ad.Description, -1, name, sizeof(name), NULL, NULL);
        printf("adapter: %s\n", name);
    }
    hr = D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device);
    printf("D3D12CreateDevice: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    if (FAILED(ID3D12Device_CreateCommandQueue(device, &qd, &IID_ID3D12CommandQueue, (void **)&queue))) return 1;
    if (FAILED(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc))) return 1;

    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    hd.NumDescriptors = 1;
    if (FAILED(ID3D12Device_CreateDescriptorHeap(device, &hd, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap))) return 1;
    rtv = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(rtv_heap);

    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Width = W;
    rd.Height = H;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    rd.SampleDesc.Count = 1;
    rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    clear.Format = rd.Format;
    memcpy(clear.Color, color, sizeof(color));
    hr = ID3D12Device_CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE, &rd,
            D3D12_RESOURCE_STATE_RENDER_TARGET, &clear, &IID_ID3D12Resource, (void **)&target);
    printf("render target: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;
    ID3D12Device_CreateRenderTargetView(device, target, NULL, rtv);

    ID3D12Device_GetCopyableFootprints(device, &rd, 0, 1, 0, &footprint, NULL, NULL, &total);
    heap.Type = D3D12_HEAP_TYPE_READBACK;
    memset(&rd, 0, sizeof(rd));
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = total;
    rd.Height = 1;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if (FAILED(ID3D12Device_CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE, &rd,
            D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback))) return 1;

    rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &err);
    if (FAILED(hr)) { printf("D3D12SerializeRootSignature: hr=0x%08lx\n", hr); return 1; }
    hr = ID3D12Device_CreateRootSignature(device, 0, ID3D10Blob_GetBufferPointer(sig), ID3D10Blob_GetBufferSize(sig),
            &IID_ID3D12RootSignature, (void **)&root);
    if (FAILED(hr)) { printf("CreateRootSignature: hr=0x%08lx\n", hr); return 1; }

    if (!(vs = compile("vs", "vs_5_0")) || !(ps = compile("ps", "ps_5_0"))) return 1;
    pd.pRootSignature = root;
    pd.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vs);
    pd.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vs);
    pd.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(ps);
    pd.PS.BytecodeLength = ID3D10Blob_GetBufferSize(ps);
    pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pd.SampleMask = 0xffffffff;
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.RasterizerState.DepthClipEnable = TRUE;
    pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets = 1;
    pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pd.SampleDesc.Count = 1;
    hr = ID3D12Device_CreateGraphicsPipelineState(device, &pd, &IID_ID3D12PipelineState, (void **)&pso);
    printf("CreateGraphicsPipelineState: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    if (FAILED(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, pso,
            &IID_ID3D12GraphicsCommandList, (void **)&list))) return 1;
    ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, color, 0, NULL);
    ID3D12GraphicsCommandList_OMSetRenderTargets(list, 1, &rtv, FALSE, NULL);
    ID3D12GraphicsCommandList_RSSetViewports(list, 1, &vp);
    ID3D12GraphicsCommandList_RSSetScissorRects(list, 1, &sc);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(list, root);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_DrawInstanced(list, 3, 1, 0, 0);
    barrier(list, target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
    dst.pResource = readback;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint = footprint;
    src.pResource = target;
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    src.SubresourceIndex = 0;
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    ID3D12GraphicsCommandList_Close(list);
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);

    if (FAILED(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence))) return 1;
    event = CreateEventW(NULL, FALSE, FALSE, NULL);
    ID3D12CommandQueue_Signal(queue, fence, 1);
    ID3D12Fence_SetEventOnCompletion(fence, 1, event);
    if (WaitForSingleObject(event, 5000) != WAIT_OBJECT_0) { printf("fence: timeout\n"); return 1; }

    if (FAILED(ID3D12Resource_Map(readback, 0, NULL, (void **)&pixels))) { printf("Map failed\n"); return 1; }
    {
        unsigned char *corner = pixels + footprint.Offset;
        unsigned char *center = pixels + footprint.Offset + (H / 2) * footprint.Footprint.RowPitch + (W / 2) * 4;
        printf("pixel top left: %u %u %u (background, expected about 51 153 255)\n", corner[0], corner[1], corner[2]);
        printf("pixel center: %u %u %u (triangle, blended color)\n", center[0], center[1], center[2]);
        ok = abs(corner[0] - 51) < 3 && abs(corner[1] - 153) < 3 && abs(corner[2] - 255) < 3 &&
             !(abs(center[0] - 51) < 3 && abs(center[1] - 153) < 3 && abs(center[2] - 255) < 3) &&
             center[0] + center[1] + center[2] > 100;
    }
    ID3D12Resource_Unmap(readback, 0, NULL);
    printf("%s\n", ok ? "OK" : "ERROR: the image is wrong");
    return !ok;
}
