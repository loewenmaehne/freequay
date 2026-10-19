/* Microphone check for patch 0009: counts waveIn devices and the default capture endpoint, as a
 * game looks for a microphone. With "start" it also tries to start every capture endpoint Windows
 * knows, including those it remembers from earlier starts (DEVICE_STATEMASK_ALL), and stops a
 * started one at once, so nothing is recorded.
 * Without a rule: no waveIn device, no default capture endpoint, every endpoint refused.
 * With env=FREEQUAY_MICROPHONE=1 for this program: the Mac's microphones are listed.
 * Build: x86_64-w64-mingw32-gcc -O2 -o microphone.exe microphone.c -lole32 -lwinmm -luuid */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <mmsystem.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    IMMDeviceEnumerator *en = NULL;
    IMMDeviceCollection *all = NULL;
    IMMDevice *dev = NULL;
    UINT count = 0, i;
    int started = 0;
    HRESULT hr;

    printf("waveIn devices: %u, waveOut devices: %u\n", waveInGetNumDevs(), waveOutGetNumDevs());
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&en);
    if (FAILED(hr)) { printf("MMDeviceEnumerator: 0x%08lx\n", hr); return 2; }
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eCapture, eConsole, &dev);
    printf("default capture endpoint: %s (0x%08lx)\n", SUCCEEDED(hr) ? "yes" : "none", hr);
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &dev);
    printf("default output endpoint: %s (0x%08lx)\n", SUCCEEDED(hr) ? "yes" : "none", hr);
    if (argc < 2 || strcmp(argv[1], "start")) return 0;

    IMMDeviceEnumerator_EnumAudioEndpoints(en, eCapture, DEVICE_STATEMASK_ALL, &all);
    if (all) IMMDeviceCollection_GetCount(all, &count);
    printf("capture endpoints known, any state: %u\n", count);
    for (i = 0; i < count; i++)
    {
        IAudioClient *client = NULL;
        WAVEFORMATEX *fmt = NULL;
        DWORD state = 0;

        hr = IMMDeviceCollection_Item(all, i, &dev);
        if (SUCCEEDED(hr)) IMMDevice_GetState(dev, &state);
        if (SUCCEEDED(hr)) hr = IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
        if (SUCCEEDED(hr)) hr = IAudioClient_GetMixFormat(client, &fmt);
        if (SUCCEEDED(hr)) hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, 0, 10000000, 0, fmt, NULL);
        if (SUCCEEDED(hr)) hr = IAudioClient_Start(client);
        if (SUCCEEDED(hr)) { started++; IAudioClient_Stop(client); }
        printf("  endpoint %u, state %lu: %s (0x%08lx)\n", i, state, SUCCEEDED(hr) ? "started" : "refused", hr);
    }
    printf("started: %d\n", started);
    return started;
}
