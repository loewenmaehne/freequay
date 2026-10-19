/* mf-video: plays clip.mp4 from make-clip.swift (2 s of H.264 and AAC) through Media Foundation and
 * checks picture and sound without looking at the screen. First the source reader decodes it to
 * RGB32 and float PCM, then a media session plays it in real time into sample grabber sinks, the
 * way Unreal Engine 4 plays videos. Both times it checks the colors of the four quadrants in every
 * frame away from the change after one second, the number of frames, the 440 Hz tone on the left
 * and the 1000 Hz tone on the right channel; for the session also how long playing took. A part
 * that hangs for 30 s counts as an error.
 * Usage: mf-video.exe [clip.mp4]   (default: clip.mp4 next to the program)
 * Build: x86_64-w64-mingw32-gcc -O2 -o mf-video.exe mf-video.c -lmfplat -lmfreadwrite -lmf -lmfuuid -lole32 -luuid
 *        i686-w64-mingw32-gcc -O2 -o mf-video32.exe mf-video.c -lmfplat -lmfreadwrite -lmf -lmfuuid -lole32 -luuid */
#define COBJMACROS
#define CONST_VTABLE
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
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

/* quadrant 0 top left, 1 top right, 2 bottom right, 3 bottom left, as in make-clip.swift; after
 * each second the colors move on by one quadrant clockwise */
static const BYTE colors[4][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}};
static const char *const quadrants[4] = {"top left", "top right", "bottom right", "bottom left"};
static const char *volatile stage = "start";

/* mfapi.h has these helpers only for C++ */
static UINT32 get_uint32(IMFMediaType *type, REFGUID key, UINT32 value)
{
    IMFMediaType_GetUINT32(type, key, &value);
    return value;
}

static void get_size(IMFMediaType *type, REFGUID key, UINT32 *width, UINT32 *height)
{
    UINT64 size = 0;

    IMFMediaType_GetUINT64(type, key, &size);
    *width = size >> 32;
    *height = (UINT32)size;
}

struct check
{
    const char *what;
    int frames, checked, bad, printed[2];
    LONGLONG last;
    int order_bad;
    float *pcm;
    int pcm_frames;
};

/* a top-down BGRA frame at the given time: the colors of its quadrant centers */
static void check_frame(struct check *c, const BYTE *scan0, LONG pitch, LONGLONG time)
{
    static const int qx[4] = {W / 4, 3 * W / 4, 3 * W / 4, W / 4}, qy[4] = {H / 4, H / 4, 3 * H / 4, 3 * H / 4};
    int second = (int)(time / 10000000), q, ok = 1;
    LONGLONG offset = time % 10000000;

    c->frames++;
    if (c->last >= 0 && time <= c->last) c->order_bad++;
    c->last = time;
    /* frames within 0.1 s of a change may come from either second */
    if (second > 1 || offset < 1000000 || offset > 9000000) return;
    c->checked++;
    for (q = 0; q < 4; q++)
    {
        const BYTE *p = scan0 + qy[q] * pitch + qx[q] * 4;
        const BYTE *want = colors[(q - second + 4) % 4];
        if (abs(p[2] - want[0]) > 48 || abs(p[1] - want[1]) > 48 || abs(p[0] - want[2]) > 48) ok = 0;
    }
    if (!ok) c->bad++;
    if (!c->printed[second] || (!ok && c->bad == 1))
    {
        c->printed[second] = 1;
        printf("%s: frame at %.2f s:", c->what, time / 1e7);
        for (q = 0; q < 4; q++)
        {
            const BYTE *p = scan0 + qy[q] * pitch + qx[q] * 4;
            printf(" %s %u %u %u%s", quadrants[q], p[2], p[1], p[0], q < 3 ? "," : "");
        }
        printf(" %s\n", ok ? "(as expected)" : "(WRONG)");
    }
}

static void add_pcm(struct check *c, const float *data, int frames)
{
    if (frames > MAX_PCM - c->pcm_frames) frames = MAX_PCM - c->pcm_frames;
    memcpy(c->pcm + c->pcm_frames * 2, data, frames * 2 * sizeof(float));
    c->pcm_frames += frames;
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

static int report(struct check *c)
{
    int ok = 1, ch;

    printf("%s: %d frames (expected %d), %d checked, %d wrong, %d out of order\n", c->what, c->frames,
           FPS * SECONDS, c->checked, c->bad, c->order_bad);
    if (c->frames < FPS * SECONDS - 1 || c->frames > FPS * SECONDS || c->checked < 30 || c->bad || c->order_bad) ok = 0;
    printf("%s: %.3f s of sound (expected about %d s)\n", c->what, (double)c->pcm_frames / RATE, SECONDS);
    if (c->pcm_frames < RATE * SECONDS * 95 / 100 || c->pcm_frames > RATE * SECONDS * 110 / 100) ok = 0;
    if (c->pcm_frames >= RATE)
    {
        for (ch = 0; ch < 2; ch++)  /* half a second from the middle */
        {
            const float *x = c->pcm + RATE / 2 * 2 + ch;
            double sum = 0, rms, l440 = level_db(x, RATE / 2, 440), l1000 = level_db(x, RATE / 2, 1000);
            int i, good;

            for (i = 0; i < RATE / 2; i++) sum += x[i * 2] * x[i * 2];
            rms = sqrt(sum / (RATE / 2));
            good = rms > 0.2 && rms < 0.5 && (ch ? l1000 - l440 : l440 - l1000) > 30;
            printf("%s: %s channel: level %.3f, 440 Hz %.0f dB, 1000 Hz %.0f dB %s\n", c->what, ch ? "right" : "left",
                   rms, l440, l1000, good ? "(as expected)" : "(WRONG)");
            if (!good) ok = 0;
        }
    }
    printf("%s: %s\n", c->what, ok ? "passed" : "FAILED");
    return ok;
}

static void print_subtype(const char *what, IMFMediaType *type)
{
    GUID sub;
    char fourcc[5] = {0};

    if (FAILED(IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &sub))) return;
    memcpy(fourcc, &sub.Data1, 4);
    if (sub.Data1 > 0xffff) printf("%s: %s\n", what, fourcc);
    else printf("%s: format tag 0x%04lx\n", what, sub.Data1);
}

static IMFMediaType *audio_type(void)
{
    IMFMediaType *type;

    MFCreateMediaType(&type);
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, &MFAudioFormat_Float);
    IMFMediaType_SetUINT32(type, &MF_MT_AUDIO_NUM_CHANNELS, 2);
    IMFMediaType_SetUINT32(type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, RATE);
    IMFMediaType_SetUINT32(type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 32);
    IMFMediaType_SetUINT32(type, &MF_MT_AUDIO_BLOCK_ALIGNMENT, 8);
    IMFMediaType_SetUINT32(type, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, RATE * 8);
    return type;
}

/* the source reader: decodes the clip as fast as it can */
static int test_reader(const WCHAR *path)
{
    struct check c = {"source reader", .last = -1};
    IMFAttributes *attr;
    IMFSourceReader *reader;
    IMFMediaType *type;
    UINT32 width = 0, height = 0, channels = 0, rate = 0, bits = 0;
    INT32 stride = 0;
    int eos[2] = {0, 0}, reads = 0, ok = 1;
    HRESULT hr;

    c.pcm = calloc(MAX_PCM * 2, sizeof(float));
    stage = "source reader: open";
    MFCreateAttributes(&attr, 1);
    IMFAttributes_SetUINT32(attr, &MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    if (FAILED(hr = MFCreateSourceReaderFromURL(path, attr, &reader)))
    {
        printf("MFCreateSourceReaderFromURL: hr=0x%08lx\n", hr);
        return 0;
    }
    if (SUCCEEDED(IMFSourceReader_GetNativeMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &type)))
    {
        print_subtype("video in the file", type);
        IMFMediaType_Release(type);
    }
    if (SUCCEEDED(IMFSourceReader_GetNativeMediaType(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &type)))
    {
        print_subtype("sound in the file", type);
        IMFMediaType_Release(type);
    }

    stage = "source reader: set the output formats";
    MFCreateMediaType(&type);
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32);
    hr = IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, type);
    IMFMediaType_Release(type);
    if (FAILED(hr))
    {
        printf("video to RGB32: hr=0x%08lx\n", hr);
        return 0;
    }
    MFCreateMediaType(&type);
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, &MFAudioFormat_Float);
    hr = IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, type);
    IMFMediaType_Release(type);
    if (FAILED(hr))
    {
        printf("sound to float: hr=0x%08lx\n", hr);
        return 0;
    }
    if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &type)))
    {
        get_size(type, &MF_MT_FRAME_SIZE, &width, &height);
        stride = (INT32)get_uint32(type, &MF_MT_DEFAULT_STRIDE, 0);
        IMFMediaType_Release(type);
    }
    if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &type)))
    {
        channels = get_uint32(type, &MF_MT_AUDIO_NUM_CHANNELS, 0);
        rate = get_uint32(type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
        bits = get_uint32(type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 0);
        IMFMediaType_Release(type);
    }
    printf("source reader: picture %ux%u RGB32, stride %d; sound %u channels, %u Hz, %u bit float\n",
           width, height, stride, channels, rate, bits);
    if (width != W || height != H || channels != 2 || rate != RATE || bits != 32)
    {
        printf("source reader: unexpected output format\n");
        return 0;
    }

    stage = "source reader: decode";
    while ((!eos[0] || !eos[1]) && reads++ < 1000)
    {
        DWORD index, flags;
        LONGLONG time;
        IMFSample *sample = NULL;
        IMFMediaBuffer *buf;
        IMFMediaType *current;
        GUID major;

        hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_ANY_STREAM, 0, &index, &flags, &time, &sample);
        if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR))
        {
            printf("ReadSample: hr=0x%08lx flags 0x%lx\n", hr, flags);
            ok = 0;
            break;
        }
        if (FAILED(IMFSourceReader_GetCurrentMediaType(reader, index, &current))) break;
        IMFMediaType_GetGUID(current, &MF_MT_MAJOR_TYPE, &major);
        if (IsEqualGUID(&major, &MFMediaType_Video))
            stride = (INT32)get_uint32(current, &MF_MT_DEFAULT_STRIDE, stride);
        IMFMediaType_Release(current);
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) eos[IsEqualGUID(&major, &MFMediaType_Audio)] = 1;
        if (!sample) continue;

        if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(sample, &buf)))
        {
            IMF2DBuffer *buf2d;
            BYTE *data, *scan0;
            DWORD len;
            LONG pitch;

            if (IsEqualGUID(&major, &MFMediaType_Video))
            {
                if (!c.frames && SUCCEEDED(IMFMediaBuffer_GetCurrentLength(buf, &len)))
                    printf("source reader: first frame in a %s buffer of %lu bytes\n",
                           SUCCEEDED(IMFMediaBuffer_QueryInterface(buf, &IID_IMF2DBuffer, (void **)&buf2d))
                           && (IMF2DBuffer_Release(buf2d), TRUE) ? "2D" : "plain", len);
                if (SUCCEEDED(IMFMediaBuffer_QueryInterface(buf, &IID_IMF2DBuffer, (void **)&buf2d)))
                {
                    if (SUCCEEDED(IMF2DBuffer_Lock2D(buf2d, &scan0, &pitch)))
                    {
                        check_frame(&c, scan0, pitch, time);
                        IMF2DBuffer_Unlock2D(buf2d);
                    }
                    IMF2DBuffer_Release(buf2d);
                }
                else if (SUCCEEDED(IMFMediaBuffer_Lock(buf, &data, NULL, &len)))
                {
                    /* a negative stride is a bottom-up picture */
                    pitch = stride ? stride : W * 4;
                    check_frame(&c, pitch < 0 ? data - (H - 1) * pitch : data, pitch, time);
                    IMFMediaBuffer_Unlock(buf);
                }
            }
            else if (SUCCEEDED(IMFMediaBuffer_Lock(buf, &data, NULL, &len)))
            {
                add_pcm(&c, (const float *)data, len / 8);
                IMFMediaBuffer_Unlock(buf);
            }
            IMFMediaBuffer_Release(buf);
        }
        IMFSample_Release(sample);
    }
    IMFSourceReader_Release(reader);
    IMFAttributes_Release(attr);
    return report(&c) && ok;
}

/* the sample grabber callback of the session test */
struct grabber
{
    IMFSampleGrabberSinkCallback iface;
    LONG refcount;
    BOOL video;
    struct check *c;
};

static struct grabber *impl(IMFSampleGrabberSinkCallback *iface)
{
    return CONTAINING_RECORD(iface, struct grabber, iface);
}

static HRESULT STDMETHODCALLTYPE grabber_QueryInterface(IMFSampleGrabberSinkCallback *iface, REFIID riid, void **out)
{
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IMFClockStateSink)
            || IsEqualIID(riid, &IID_IMFSampleGrabberSinkCallback))
    {
        *out = iface;
        IMFSampleGrabberSinkCallback_AddRef(iface);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE grabber_AddRef(IMFSampleGrabberSinkCallback *iface)
{
    return InterlockedIncrement(&impl(iface)->refcount);
}

static ULONG STDMETHODCALLTYPE grabber_Release(IMFSampleGrabberSinkCallback *iface)
{
    return InterlockedDecrement(&impl(iface)->refcount);  /* static objects */
}

static HRESULT STDMETHODCALLTYPE grabber_OnClockStart(IMFSampleGrabberSinkCallback *iface, MFTIME time, LONGLONG offset)
{
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE grabber_OnClockStop(IMFSampleGrabberSinkCallback *iface, MFTIME time)
{
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE grabber_OnClockPause(IMFSampleGrabberSinkCallback *iface, MFTIME time)
{
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE grabber_OnClockRestart(IMFSampleGrabberSinkCallback *iface, MFTIME time)
{
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE grabber_OnClockSetRate(IMFSampleGrabberSinkCallback *iface, MFTIME time, float rate)
{
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE grabber_OnSetPresentationClock(IMFSampleGrabberSinkCallback *iface, IMFPresentationClock *clock)
{
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE grabber_OnProcessSample(IMFSampleGrabberSinkCallback *iface, REFGUID major,
        DWORD flags, LONGLONG time, LONGLONG duration, const BYTE *data, DWORD size)
{
    struct grabber *g = impl(iface);

    if (!g->video) add_pcm(g->c, (const float *)data, size / 8);
    else if (size >= W * H * 4) check_frame(g->c, data, W * 4, time);  /* the sink's type says top-down */
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE grabber_OnShutdown(IMFSampleGrabberSinkCallback *iface)
{
    return S_OK;
}

static const IMFSampleGrabberSinkCallbackVtbl grabber_vtbl =
{
    grabber_QueryInterface, grabber_AddRef, grabber_Release, grabber_OnClockStart, grabber_OnClockStop,
    grabber_OnClockPause, grabber_OnClockRestart, grabber_OnClockSetRate, grabber_OnSetPresentationClock,
    grabber_OnProcessSample, grabber_OnShutdown,
};

/* waits for an event of the session; the watchdog in main ends a hang */
static HRESULT wait_event(IMFMediaSession *session, MediaEventType want, HRESULT *status)
{
    for (;;)
    {
        IMFMediaEvent *event;
        MediaEventType type;
        HRESULT hr;

        if (FAILED(hr = IMFMediaSession_GetEvent(session, 0, &event))) return hr;
        IMFMediaEvent_GetType(event, &type);
        IMFMediaEvent_GetStatus(event, status);
        IMFMediaEvent_Release(event);
        if (FAILED(*status))
        {
            printf("media session: event %lu, status 0x%08lx\n", type, *status);
            return *status;
        }
        if (type == want) return S_OK;
        if (type == MEError) return E_FAIL;
    }
}

/* the media session: plays the clip in real time into a video and a sound sample grabber */
static int test_session(const WCHAR *path)
{
    struct check c = {"media session", .last = -1};
    struct grabber video = {{&grabber_vtbl}, 1, TRUE, &c}, sound = {{&grabber_vtbl}, 1, FALSE, &c};
    IMFSourceResolver *resolver;
    IMFMediaSource *source;
    IMFPresentationDescriptor *pd;
    IMFTopology *topology;
    IMFMediaSession *session;
    MF_OBJECT_TYPE object_type;
    IUnknown *object;
    PROPVARIANT start = {0};
    DWORD count, i, started, took;
    HRESULT hr, status;
    int ok = 1;

    c.pcm = calloc(MAX_PCM * 2, sizeof(float));
    stage = "media session: open";
    MFCreateSourceResolver(&resolver);
    if (FAILED(hr = IMFSourceResolver_CreateObjectFromURL(resolver, path, MF_RESOLUTION_MEDIASOURCE, NULL,
            &object_type, &object)))
    {
        printf("CreateObjectFromURL: hr=0x%08lx\n", hr);
        return 0;
    }
    IUnknown_QueryInterface(object, &IID_IMFMediaSource, (void **)&source);
    IUnknown_Release(object);
    IMFMediaSource_CreatePresentationDescriptor(source, &pd);
    MFCreateTopology(&topology);
    IMFPresentationDescriptor_GetStreamDescriptorCount(pd, &count);
    for (i = 0; i < count; i++)
    {
        IMFStreamDescriptor *sd;
        IMFMediaTypeHandler *handler;
        IMFTopologyNode *src_node, *sink_node;
        IMFMediaType *type;
        IMFActivate *activate;
        BOOL selected;
        GUID major;

        IMFPresentationDescriptor_GetStreamDescriptorByIndex(pd, i, &selected, &sd);
        IMFStreamDescriptor_GetMediaTypeHandler(sd, &handler);
        IMFMediaTypeHandler_GetMajorType(handler, &major);
        IMFMediaTypeHandler_Release(handler);
        if (IsEqualGUID(&major, &MFMediaType_Video))
        {
            MFCreateMediaType(&type);
            IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
            IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32);
            IMFMediaType_SetUINT64(type, &MF_MT_FRAME_SIZE, (UINT64)W << 32 | H);
            IMFMediaType_SetUINT32(type, &MF_MT_DEFAULT_STRIDE, W * 4);
            MFCreateSampleGrabberSinkActivate(type, &video.iface, &activate);
        }
        else if (IsEqualGUID(&major, &MFMediaType_Audio))
        {
            type = audio_type();
            MFCreateSampleGrabberSinkActivate(type, &sound.iface, &activate);
        }
        else
        {
            IMFPresentationDescriptor_DeselectStream(pd, i);
            IMFStreamDescriptor_Release(sd);
            continue;
        }
        IMFMediaType_Release(type);
        IMFPresentationDescriptor_SelectStream(pd, i);
        MFCreateTopologyNode(MF_TOPOLOGY_SOURCESTREAM_NODE, &src_node);
        IMFTopologyNode_SetUnknown(src_node, &MF_TOPONODE_SOURCE, (IUnknown *)source);
        IMFTopologyNode_SetUnknown(src_node, &MF_TOPONODE_PRESENTATION_DESCRIPTOR, (IUnknown *)pd);
        IMFTopologyNode_SetUnknown(src_node, &MF_TOPONODE_STREAM_DESCRIPTOR, (IUnknown *)sd);
        MFCreateTopologyNode(MF_TOPOLOGY_OUTPUT_NODE, &sink_node);
        IMFTopologyNode_SetObject(sink_node, (IUnknown *)activate);
        IMFTopology_AddNode(topology, src_node);
        IMFTopology_AddNode(topology, sink_node);
        IMFTopologyNode_ConnectOutput(src_node, 0, sink_node, 0);
        IMFTopologyNode_Release(src_node);
        IMFTopologyNode_Release(sink_node);
        IMFActivate_Release(activate);
        IMFStreamDescriptor_Release(sd);
    }

    stage = "media session: resolve the topology";
    MFCreateMediaSession(NULL, &session);
    if (FAILED(hr = IMFMediaSession_SetTopology(session, 0, topology))
            || FAILED(hr = wait_event(session, MESessionTopologySet, &status)))
    {
        printf("SetTopology: hr=0x%08lx\n", hr);
        return 0;
    }
    stage = "media session: play";
    started = GetTickCount();
    if (FAILED(hr = IMFMediaSession_Start(session, &GUID_NULL, &start))
            || FAILED(hr = wait_event(session, MESessionEnded, &status)))
    {
        printf("playing: hr=0x%08lx\n", hr);
        ok = 0;
    }
    took = GetTickCount() - started;
    printf("media session: played in %.2f s (the clip is %d s)\n", took / 1000.0, SECONDS);
    if (took < SECONDS * 900 || took > SECONDS * 2000) ok = 0;

    stage = "media session: close";
    IMFMediaSession_Close(session);
    wait_event(session, MESessionClosed, &status);
    IMFMediaSource_Shutdown(source);
    IMFMediaSession_Shutdown(session);
    IMFMediaSession_Release(session);
    IMFTopology_Release(topology);
    IMFPresentationDescriptor_Release(pd);
    IMFMediaSource_Release(source);
    IMFSourceResolver_Release(resolver);
    return report(&c) && ok;
}

static WCHAR clip[MAX_PATH];

static DWORD WINAPI run(void *arg)
{
    int ok;

    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_FULL);
    ok = test_reader(clip);
    ok = test_session(clip) && ok;
    stage = "shutdown";
    MFShutdown();
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
    printf("clip: %ls\n", clip);
    setvbuf(stdout, NULL, _IONBF, 0);

    thread = CreateThread(NULL, 0, run, NULL, 0, NULL);
    /* the watchdog: each part gets 30 s */
    for (;;)
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
            fflush(stdout);
            ExitProcess(2);
        }
    }
    GetExitCodeThread(thread, &code);
    printf("%s\n", code ? "ERROR: the video did not play correctly" : "OK");
    return code;
}
