/* dshow-video: plays clip.mp4 from make-clip.swift through DirectShow, as older games play their
 * videos, and checks picture and sound without looking at the screen or using the speakers: the
 * filter graph connects the file to sample grabbers for RGB32 and PCM, each followed by a null
 * renderer, and runs in real time. Checks the colors of the four quadrants in every frame away from
 * the change after one second, the number of frames, the 440 Hz tone on the left and the 1000 Hz
 * tone on the right channel, and how long playing took. A hang counts as an error after 30 s.
 * Usage: dshow-video.exe [clip.mp4]   (default: clip.mp4 next to the program)
 * Build: x86_64-w64-mingw32-gcc -O2 -o dshow-video.exe dshow-video.c -lstrmiids -lole32 -loleaut32 -luuid
 *        i686-w64-mingw32-gcc -O2 -o dshow-video32.exe dshow-video.c -lstrmiids -lole32 -loleaut32 -luuid */
#define COBJMACROS
#define CONST_VTABLE
#include <windows.h>
#include <dshow.h>
#include <qedit.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define W 320
#define H 240
#define FPS 25
#define SECONDS 2
#define RATE 48000
#define MAX_PCM (RATE * (SECONDS + 1))

/* qedit.h of mingw-w64 lacks these two */
static const GUID CLSID_SampleGrabber_ = {0xc1f400a0, 0x3f08, 0x11d3, {0x9f, 0x0b, 0x00, 0x60, 0x08, 0x03, 0x9e, 0x37}};
static const GUID CLSID_NullRenderer_ = {0xc1f400a4, 0x3f08, 0x11d3, {0x9f, 0x0b, 0x00, 0x60, 0x08, 0x03, 0x9e, 0x37}};

/* as in make-clip.swift and mf-video.c */
static const BYTE colors[4][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}};
static const char *const quadrants[4] = {"top left", "top right", "bottom right", "bottom left"};
static const char *volatile stage = "start";

static struct
{
    int frames, checked, bad, printed[2], order_bad, pcm_frames, bits, channels, rate;
    LONGLONG last;
    BOOL bottom_up;
    float pcm[MAX_PCM * 2];
} c;

static void check_frame(const BYTE *scan0, LONG pitch, LONGLONG time)
{
    static const int qx[4] = {W / 4, 3 * W / 4, 3 * W / 4, W / 4}, qy[4] = {H / 4, H / 4, 3 * H / 4, 3 * H / 4};
    int second = (int)(time / 10000000), q, ok = 1;
    LONGLONG offset = time % 10000000;

    c.frames++;
    if (c.last >= 0 && time <= c.last) c.order_bad++;
    c.last = time;
    if (second > 1 || offset < 1000000 || offset > 9000000) return;
    c.checked++;
    for (q = 0; q < 4; q++)
    {
        const BYTE *p = scan0 + qy[q] * pitch + qx[q] * 4;
        const BYTE *want = colors[(q - second + 4) % 4];
        if (abs(p[2] - want[0]) > 48 || abs(p[1] - want[1]) > 48 || abs(p[0] - want[2]) > 48) ok = 0;
    }
    if (!ok) c.bad++;
    if (!c.printed[second] || (!ok && c.bad == 1))
    {
        c.printed[second] = 1;
        printf("directshow: frame at %.2f s:", time / 1e7);
        for (q = 0; q < 4; q++)
        {
            const BYTE *p = scan0 + qy[q] * pitch + qx[q] * 4;
            printf(" %s %u %u %u%s", quadrants[q], p[2], p[1], p[0], q < 3 ? "," : "");
        }
        printf(" %s\n", ok ? "(as expected)" : "(WRONG)");
    }
}

static double level_db(const float *x, int n, double freq)  /* Goertzel, channel stride 2 */
{
    double k = 2 * cos(2 * M_PI * freq / RATE), s0, s1 = 0, s2 = 0;
    int i;

    for (i = 0; i < n; i++)
    {
        s0 = x[i * 2] + k * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return 10 * log10(s1 * s1 + s2 * s2 - k * s1 * s2 + 1e-12);
}

/* the sample grabber callback, one object for picture and sound */
struct grabber
{
    ISampleGrabberCB iface;
    BOOL video;
};

static HRESULT STDMETHODCALLTYPE cb_QueryInterface(ISampleGrabberCB *iface, REFIID riid, void **out)
{
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ISampleGrabberCB))
    {
        *out = iface;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE cb_AddRef(ISampleGrabberCB *iface)
{
    return 2;  /* static objects */
}

static ULONG STDMETHODCALLTYPE cb_Release(ISampleGrabberCB *iface)
{
    return 1;
}

static HRESULT STDMETHODCALLTYPE cb_SampleCB(ISampleGrabberCB *iface, double time, IMediaSample *sample)
{
    struct grabber *g = CONTAINING_RECORD(iface, struct grabber, iface);
    REFERENCE_TIME start = 0, end = 0;
    BYTE *data;
    LONG len;
    int i, n;

    if (FAILED(IMediaSample_GetPointer(sample, &data))) return S_OK;
    len = IMediaSample_GetActualDataLength(sample);
    if (FAILED(IMediaSample_GetTime(sample, &start, &end))) start = (REFERENCE_TIME)(time * 1e7);
    if (g->video)
    {
        /* RGB32 in DirectShow is bottom-up unless the height is negative */
        if (len >= W * H * 4)
            check_frame(c.bottom_up ? data + (H - 1) * W * 4 : data, c.bottom_up ? -W * 4 : W * 4, start);
        return S_OK;
    }
    n = len / (c.bits / 8) / 2;
    if (n > MAX_PCM - c.pcm_frames) n = MAX_PCM - c.pcm_frames;
    for (i = 0; i < n * 2; i++)
        c.pcm[c.pcm_frames * 2 + i] = c.bits == 16 ? ((const short *)data)[i] / 32768.0f : ((const float *)data)[i];
    c.pcm_frames += n;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE cb_BufferCB(ISampleGrabberCB *iface, double time, BYTE *data, LONG len)
{
    return S_OK;
}

static const ISampleGrabberCBVtbl cb_vtbl =
{
    cb_QueryInterface, cb_AddRef, cb_Release, cb_SampleCB, cb_BufferCB,
};

static IPin *get_pin(IBaseFilter *filter, PIN_DIRECTION want, BOOL unconnected, int skip)
{
    IEnumPins *pins;
    IPin *pin, *peer;
    PIN_DIRECTION dir;

    IBaseFilter_EnumPins(filter, &pins);
    while (IEnumPins_Next(pins, 1, &pin, NULL) == S_OK)
    {
        IPin_QueryDirection(pin, &dir);
        if (dir == want && unconnected && SUCCEEDED(IPin_ConnectedTo(pin, &peer)))
        {
            IPin_Release(peer);
            IPin_Release(pin);
            continue;
        }
        if (dir == want && !skip--)
        {
            IEnumPins_Release(pins);
            return pin;
        }
        IPin_Release(pin);
    }
    IEnumPins_Release(pins);
    return NULL;
}

static IBaseFilter *add_filter(IGraphBuilder *graph, const GUID *clsid, const WCHAR *name)
{
    IBaseFilter *filter = NULL;

    if (SUCCEEDED(CoCreateInstance(clsid, NULL, CLSCTX_INPROC_SERVER, &IID_IBaseFilter, (void **)&filter)))
        IGraphBuilder_AddFilter(graph, filter, name);
    return filter;
}

static WCHAR clip[MAX_PATH];

static DWORD WINAPI run(void *arg)
{
    struct grabber video = {{&cb_vtbl}, TRUE}, sound = {{&cb_vtbl}, FALSE};
    IBaseFilter *source, *vgrab, *agrab, *vnull, *anull, *parser = NULL;
    ISampleGrabber *vg, *ag;
    IGraphBuilder *graph;
    IMediaControl *control;
    IMediaEvent *events;
    AM_MEDIA_TYPE mt = {0};
    IPin *out, *peer;
    PIN_INFO info;
    LONG code = 0;
    DWORD started, took;
    HRESULT hr;
    int ok = 1, i, ch;

    c.last = -1;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    stage = "directshow: build the graph";
    if (FAILED(hr = CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER, &IID_IGraphBuilder, (void **)&graph)))
    {
        printf("FilterGraph: hr=0x%08lx\n", hr);
        return 1;
    }
    if (FAILED(hr = IGraphBuilder_AddSourceFilter(graph, clip, L"source", &source)))
    {
        printf("AddSourceFilter: hr=0x%08lx\n", hr);
        return 1;
    }
    vgrab = add_filter(graph, &CLSID_SampleGrabber_, L"video grabber");
    agrab = add_filter(graph, &CLSID_SampleGrabber_, L"sound grabber");
    vnull = add_filter(graph, &CLSID_NullRenderer_, L"video null");
    anull = add_filter(graph, &CLSID_NullRenderer_, L"sound null");
    if (!vgrab || !agrab || !vnull || !anull)
    {
        printf("sample grabber or null renderer missing\n");
        return 1;
    }
    IBaseFilter_QueryInterface(vgrab, &IID_ISampleGrabber, (void **)&vg);
    IBaseFilter_QueryInterface(agrab, &IID_ISampleGrabber, (void **)&ag);
    mt.majortype = MEDIATYPE_Video;
    mt.subtype = MEDIASUBTYPE_RGB32;
    ISampleGrabber_SetMediaType(vg, &mt);
    mt.majortype = MEDIATYPE_Audio;
    mt.subtype = MEDIASUBTYPE_PCM;
    ISampleGrabber_SetMediaType(ag, &mt);
    ISampleGrabber_SetCallback(vg, &video.iface, 0);
    ISampleGrabber_SetCallback(ag, &sound.iface, 0);

    /* the file to the video grabber: the graph builder adds the splitter and what converts its
     * video; then the splitter's other output to the sound grabber */
    out = get_pin(source, PINDIR_OUTPUT, FALSE, 0);
    if (FAILED(hr = IGraphBuilder_Connect(graph, out, get_pin(vgrab, PINDIR_INPUT, FALSE, 0))))
    {
        printf("connecting the video: hr=0x%08lx\n", hr);
        return 1;
    }
    if (SUCCEEDED(IPin_ConnectedTo(out, &peer)) && SUCCEEDED(IPin_QueryPinInfo(peer, &info)))
    {
        FILTER_INFO finfo;
        parser = info.pFilter;
        if (SUCCEEDED(IBaseFilter_QueryFilterInfo(parser, &finfo)))
        {
            printf("directshow: splitter \"%ls\"\n", finfo.achName);
            if (finfo.pGraph) IFilterGraph_Release(finfo.pGraph);
        }
    }
    hr = E_FAIL;
    for (i = 0; parser && FAILED(hr) && i < 4; i++)
    {
        IPin *pin = get_pin(parser, PINDIR_OUTPUT, TRUE, i);
        if (!pin) break;
        hr = IGraphBuilder_Connect(graph, pin, get_pin(agrab, PINDIR_INPUT, FALSE, 0));
    }
    if (FAILED(hr))
    {
        printf("connecting the sound: hr=0x%08lx\n", hr);
        ok = 0;
    }
    IGraphBuilder_Connect(graph, get_pin(vgrab, PINDIR_OUTPUT, FALSE, 0), get_pin(vnull, PINDIR_INPUT, FALSE, 0));
    IGraphBuilder_Connect(graph, get_pin(agrab, PINDIR_OUTPUT, FALSE, 0), get_pin(anull, PINDIR_INPUT, FALSE, 0));

    if (SUCCEEDED(ISampleGrabber_GetConnectedMediaType(vg, &mt)))
    {
        if (IsEqualGUID(&mt.formattype, &FORMAT_VideoInfo) && mt.cbFormat >= sizeof(VIDEOINFOHEADER))
        {
            BITMAPINFOHEADER *bih = &((VIDEOINFOHEADER *)mt.pbFormat)->bmiHeader;
            c.bottom_up = bih->biHeight > 0;
            printf("directshow: picture %ldx%ld, %u bit, %s\n", bih->biWidth, labs(bih->biHeight), bih->biBitCount,
                   c.bottom_up ? "bottom-up" : "top-down");
            if (bih->biWidth != W || labs(bih->biHeight) != H || bih->biBitCount != 32) ok = 0;
        }
        CoTaskMemFree(mt.pbFormat);
    }
    if (SUCCEEDED(ISampleGrabber_GetConnectedMediaType(ag, &mt)))
    {
        if (IsEqualGUID(&mt.formattype, &FORMAT_WaveFormatEx) && mt.cbFormat >= sizeof(WAVEFORMATEX))
        {
            WAVEFORMATEX *wfx = (WAVEFORMATEX *)mt.pbFormat;
            c.bits = wfx->wBitsPerSample;
            c.channels = wfx->nChannels;
            c.rate = wfx->nSamplesPerSec;
            printf("directshow: sound %u channels, %lu Hz, %u bit\n", wfx->nChannels, wfx->nSamplesPerSec, wfx->wBitsPerSample);
        }
        CoTaskMemFree(mt.pbFormat);
    }
    if (c.channels != 2 || c.rate != RATE || (c.bits != 16 && c.bits != 32))
    {
        printf("directshow: unexpected sound format\n");
        return 1;
    }

    stage = "directshow: play";
    IGraphBuilder_QueryInterface(graph, &IID_IMediaControl, (void **)&control);
    IGraphBuilder_QueryInterface(graph, &IID_IMediaEvent, (void **)&events);
    started = GetTickCount();
    if (FAILED(hr = IMediaControl_Run(control)))
    {
        printf("Run: hr=0x%08lx\n", hr);
        return 1;
    }
    hr = IMediaEvent_WaitForCompletion(events, 20000, &code);
    took = GetTickCount() - started;
    printf("directshow: played in %.2f s (the clip is %d s), event %ld\n", took / 1000.0, SECONDS, code);
    if (FAILED(hr) || code != EC_COMPLETE || took < SECONDS * 900 || took > SECONDS * 2000) ok = 0;
    stage = "directshow: stop";
    IMediaControl_Stop(control);

    printf("directshow: %d frames (expected %d), %d checked, %d wrong, %d out of order\n", c.frames,
           FPS * SECONDS, c.checked, c.bad, c.order_bad);
    if (c.frames < FPS * SECONDS - 1 || c.frames > FPS * SECONDS || c.checked < 30 || c.bad || c.order_bad) ok = 0;
    printf("directshow: %.3f s of sound (expected about %d s)\n", (double)c.pcm_frames / RATE, SECONDS);
    if (c.pcm_frames < RATE * SECONDS * 95 / 100 || c.pcm_frames > RATE * SECONDS * 110 / 100) ok = 0;
    if (c.pcm_frames >= RATE)
    {
        for (ch = 0; ch < 2; ch++)
        {
            const float *x = c.pcm + RATE / 2 * 2 + ch;
            double sum = 0, rms, l440 = level_db(x, RATE / 2, 440), l1000 = level_db(x, RATE / 2, 1000);
            int good;

            for (i = 0; i < RATE / 2; i++) sum += x[i * 2] * x[i * 2];
            rms = sqrt(sum / (RATE / 2));
            good = rms > 0.2 && rms < 0.5 && (ch ? l1000 - l440 : l440 - l1000) > 30;
            printf("directshow: %s channel: level %.3f, 440 Hz %.0f dB, 1000 Hz %.0f dB %s\n", ch ? "right" : "left",
                   rms, l440, l1000, good ? "(as expected)" : "(WRONG)");
            if (!good) ok = 0;
        }
    }
    stage = "directshow: release";
    IMediaEvent_Release(events);
    IMediaControl_Release(control);
    IGraphBuilder_Release(graph);
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    DWORD code = 1, started = GetTickCount();
    const char *last = NULL;
    HANDLE thread;

    if (argc > 1) MultiByteToWideChar(CP_ACP, 0, argv[1], -1, clip, MAX_PATH);
    else
    {
        WCHAR *slash;
        GetModuleFileNameW(NULL, clip, MAX_PATH);
        if ((slash = wcsrchr(clip, '\\'))) wcscpy(slash + 1, L"clip.mp4");
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("clip: %ls\n", clip);

    thread = CreateThread(NULL, 0, run, NULL, 0, NULL);
    for (;;)  /* the watchdog: each part gets 30 s */
    {
        if (WaitForSingleObject(thread, 1000) == WAIT_OBJECT_0) break;
        if (stage != last)
        {
            last = stage;
            started = GetTickCount();
        }
        else if (GetTickCount() - started > 30000)
        {
            printf("ERROR: hangs at \"%s\"\n", stage);
            ExitProcess(2);
        }
    }
    GetExitCodeThread(thread, &code);
    printf("%s\n", code ? "ERROR: the video did not play correctly" : "OK");
    return code;
}
