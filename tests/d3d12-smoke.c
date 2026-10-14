/* d3d12-smoke: creates a Direct3D 12 device with a command queue and waits for a fence.
 * Checks whether DirectX 12 (D3DMetal or vkd3d) starts at all.
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d12-smoke.exe d3d12-smoke.c -ld3d12 -ldxgi */
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>

int main(void)
{
    D3D12_COMMAND_QUEUE_DESC qd = {0};
    DXGI_ADAPTER_DESC1 ad_desc;
    IDXGIFactory4 *factory = NULL;
    IDXGIAdapter1 *adapter = NULL;
    ID3D12Device *dev = NULL;
    ID3D12CommandQueue *queue = NULL;
    ID3D12Fence *fence = NULL;
    HANDLE event;
    HRESULT hr;
    char name[256];

    hr = CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory);
    printf("CreateDXGIFactory1: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;
    if (SUCCEEDED(IDXGIFactory4_EnumAdapters1(factory, 0, &adapter))
        && SUCCEEDED(IDXGIAdapter1_GetDesc1(adapter, &ad_desc)))
    {
        WideCharToMultiByte(CP_UTF8, 0, ad_desc.Description, -1, name, sizeof(name), NULL, NULL);
        printf("adapter: %s\n", name);
    }

    hr = D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    printf("D3D12CreateDevice: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    hr = ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue);
    printf("CreateCommandQueue: hr=0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence);
    event = CreateEventW(NULL, FALSE, FALSE, NULL);
    ID3D12CommandQueue_Signal(queue, fence, 1);
    ID3D12Fence_SetEventOnCompletion(fence, 1, event);
    if (WaitForSingleObject(event, 5000) != WAIT_OBJECT_0)
    {
        printf("fence: timeout\n");
        return 1;
    }
    printf("fence value: %llu\n", (unsigned long long)ID3D12Fence_GetCompletedValue(fence));
    printf("OK\n");
    return 0;
}
