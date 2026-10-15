// mjpegprobe: reproduce Chrome's Windows camera path (Media Foundation
// decoding MJPEG to NV12 on a D3D11 device) and log what the decoder does.
//
//   mjpegprobe list                      MJPEG decoders and capture devices
//   mjpegprobe cam  [name] [sec] [--sw]  read from a camera (default "BRIO")
//   mjpegprobe file <path> [--sw]        read an MJPEG AVI
//
// --sw leaves out the D3D11 device, so Media Foundation decodes on the CPU
// (what Chrome does with MediaFoundationD3D11VideoCapture disabled).
// --dbwin prints OutputDebugString messages from this and other processes
// in the session (the AMD MJPEG MFT logs its trace config path there).
// A decoder that returns no frame for 5 s is reported as a stall and the
// probe exits.
//
// Build (mingw-w64): see build.sh.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#define CHECK(expr)                                                        \
  do {                                                                     \
    HRESULT hr_ = (expr);                                                  \
    if (FAILED(hr_)) {                                                     \
      printf("FAILED %s: 0x%08lx %s\n", #expr, (unsigned long)hr_,         \
             hrtext(hr_).c_str());                                         \
      return hr_;                                                          \
    }                                                                      \
  } while (0)

template <class T> struct Com {
  T *p = nullptr;
  ~Com() { if (p) p->Release(); }
  T **operator&() { return &p; }
  T *operator->() { return p; }
  operator T *() { return p; }
};

static std::string utf8(const wchar_t *w) {
  if (!w) return "";
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  std::string s(n > 0 ? n - 1 : 0, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
  return s;
}

static std::string hrtext(HRESULT hr) {
  wchar_t *msg = nullptr;
  FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                     FORMAT_MESSAGE_IGNORE_INSERTS,
                 nullptr, hr, 0, (LPWSTR)&msg, 0, nullptr);
  if (!msg) {
    HMODULE mf = GetModuleHandleW(L"mfplat.dll");
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_HMODULE |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                   mf, hr, 0, (LPWSTR)&msg, 0, nullptr);
  }
  std::string s = utf8(msg);
  if (msg) LocalFree(msg);
  while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
  return s;
}

static double now_s() {
  static LARGE_INTEGER f, t0;
  LARGE_INTEGER t;
  if (!f.QuadPart) { QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t0); }
  QueryPerformanceCounter(&t);
  return double(t.QuadPart - t0.QuadPart) / f.QuadPart;
}

// ---------------------------------------------------------------- debug output
// The DBWIN protocol DebugView uses: OutputDebugString (with no debugger
// attached) waits for DBWIN_BUFFER_READY, writes {pid, text} into the
// DBWIN_BUFFER section and signals DBWIN_DATA_READY.
static DWORD WINAPI dbwin_thread(void *) {
  HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, L"DBWIN_BUFFER_READY");
  HANDLE data = CreateEventW(nullptr, FALSE, FALSE, L"DBWIN_DATA_READY");
  HANDLE map = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, 4096,
                                  L"DBWIN_BUFFER");
  if (!ready || !data || !map || GetLastError() == ERROR_ALREADY_EXISTS) {
    printf("dbwin: cannot listen (is DebugView or a debugger running?)\n");
    return 0;
  }
  const char *buf = (const char *)MapViewOfFile(map, FILE_MAP_READ, 0, 0, 4096);
  for (;;) {
    SetEvent(ready);
    if (WaitForSingleObject(data, INFINITE) != WAIT_OBJECT_0) break;
    DWORD pid = *(const DWORD *)buf;
    std::string text(buf + 4, strnlen(buf + 4, 4092));
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) text.pop_back();
    printf("%7.3f [dbg %lu] %s\n", now_s(), (unsigned long)pid, text.c_str());
  }
  return 0;
}

// ---------------------------------------------------------------- watchdog
static volatile double g_last_progress = 0;
static volatile LONG g_watch = 0;
static volatile LONG g_frames = 0;

static DWORD WINAPI watchdog_thread(void *) {
  for (;;) {
    Sleep(500);
    if (g_watch && now_s() - g_last_progress > 5.0) {
      printf("%7.3f STALL: no frame from the decoder for 5 s after frame %ld; exiting\n",
             now_s(), (long)g_frames);
      Sleep(300);   // let --dbwin print anything the decoder logged
      ExitProcess(3);
    }
  }
}

static std::string attr_string(IMFAttributes *a, REFGUID key) {
  wchar_t *w = nullptr;
  UINT32 n = 0;
  if (!a || FAILED(a->GetAllocatedString(key, &w, &n))) return "";
  std::string s = utf8(w);
  CoTaskMemFree(w);
  return s;
}

static std::string subtype_name(const GUID &g) {
  if (g == MFVideoFormat_NV12) return "NV12";
  if (g == MFVideoFormat_MJPG) return "MJPG";
  if (g == MFVideoFormat_YUY2) return "YUY2";
  if (g == MFVideoFormat_RGB32) return "RGB32";
  if (g == MFVideoFormat_ARGB32) return "ARGB32";
  if (g == MFVideoFormat_I420) return "I420";
  if (g == MFVideoFormat_IYUV) return "IYUV";
  char buf[64];
  snprintf(buf, sizeof buf, "%08lx", (unsigned long)g.Data1);
  return buf;
}

static void print_type(const char *label, IMFMediaType *t) {
  GUID sub = GUID_NULL;
  UINT32 w = 0, h = 0, num = 0, den = 0;
  t->GetGUID(MF_MT_SUBTYPE, &sub);
  MFGetAttributeSize(t, MF_MT_FRAME_SIZE, &w, &h);
  MFGetAttributeRatio(t, MF_MT_FRAME_RATE, &num, &den);
  printf("%s %s %ux%u @ %u/%u\n", label, subtype_name(sub).c_str(), w, h, num, den);
}

// ---------------------------------------------------------------- list
static HRESULT list_decoders() {
  MFT_REGISTER_TYPE_INFO in = {MFMediaType_Video, MFVideoFormat_MJPG};
  UINT32 flags[] = {MFT_ENUM_FLAG_HARDWARE, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT |
                                                MFT_ENUM_FLAG_LOCALMFT};
  const char *kind[] = {"hardware", "software"};
  for (int k = 0; k < 2; k++) {
    IMFActivate **acts = nullptr;
    UINT32 n = 0;
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, flags[k] | MFT_ENUM_FLAG_SORTANDFILTER,
                           &in, nullptr, &acts, &n);
    printf("MJPEG decoders (%s): %u  hr=0x%08lx\n", kind[k], n, (unsigned long)hr);
    for (UINT32 i = 0; i < n; i++) {
      printf("  [%u] %s", i, attr_string(acts[i], MFT_FRIENDLY_NAME_Attribute).c_str());
      std::string url = attr_string(acts[i], MFT_ENUM_HARDWARE_URL_Attribute);
      std::string vendor = attr_string(acts[i], MFT_ENUM_HARDWARE_VENDOR_ID_Attribute);
      if (!url.empty()) printf("  url=%s", url.c_str());
      if (!vendor.empty()) printf("  vendor=%s", vendor.c_str());
      printf("\n");
      acts[i]->Release();
    }
    CoTaskMemFree(acts);
  }
  return S_OK;
}

static HRESULT list_cameras(IMFActivate ***devs, UINT32 *n) {
  Com<IMFAttributes> a;
  CHECK(MFCreateAttributes(&a, 1));
  CHECK(a->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                   MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID));
  CHECK(MFEnumDeviceSources(a, devs, n));
  return S_OK;
}

// ---------------------------------------------------------------- D3D
struct Gpu {
  Com<ID3D11Device> dev;
  Com<IMFDXGIDeviceManager> mgr;
  UINT token = 0;
};

static HRESULT make_gpu(Gpu &g) {
  D3D_FEATURE_LEVEL fl;
  CHECK(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                          D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                          nullptr, 0, D3D11_SDK_VERSION, &g.dev, &fl, nullptr));
  Com<ID3D10Multithread> mt;
  if (SUCCEEDED(g.dev->QueryInterface(__uuidof(ID3D10Multithread), (void **)&mt)))
    mt->SetMultithreadProtected(TRUE);
  Com<IDXGIDevice> dxgi;
  Com<IDXGIAdapter> ad;
  DXGI_ADAPTER_DESC desc = {};
  if (SUCCEEDED(g.dev->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgi)) &&
      SUCCEEDED(dxgi->GetAdapter(&ad)) && SUCCEEDED(ad->GetDesc(&desc)))
    printf("GPU: %s (vendor %04x device %04x)\n", utf8(desc.Description).c_str(),
           desc.VendorId, desc.DeviceId);
  CHECK(MFCreateDXGIDeviceManager(&g.token, &g.mgr));
  CHECK(g.mgr->ResetDevice(g.dev, g.token));
  return S_OK;
}

static void report_device(Gpu *g) {
  if (!g || !g->dev) return;
  HRESULT r = g->dev->GetDeviceRemovedReason();
  if (r != S_OK)
    printf("  D3D11 device REMOVED: 0x%08lx %s\n", (unsigned long)r, hrtext(r).c_str());
}

// ---------------------------------------------------------------- read
static void print_chain(IMFSourceReader *reader) {
  Com<IMFSourceReaderEx> ex;
  if (FAILED(reader->QueryInterface(__uuidof(IMFSourceReaderEx), (void **)&ex))) return;
  for (DWORD i = 0;; i++) {
    GUID cat;
    Com<IMFTransform> t;
    if (FAILED(ex->GetTransformForStream(MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &cat, &t)))
      break;
    Com<IMFAttributes> a;
    std::string name;
    UINT32 d3d11 = 0;
    if (SUCCEEDED(t->GetAttributes(&a))) {
      name = attr_string(a, MFT_FRIENDLY_NAME_Attribute);
      a->GetUINT32(MF_SA_D3D11_AWARE, &d3d11);
    }
    Com<IMFMediaType> it, ot;
    std::string io;
    if (SUCCEEDED(t->GetInputCurrentType(0, &it)) && SUCCEEDED(t->GetOutputCurrentType(0, &ot))) {
      GUID s1 = GUID_NULL, s2 = GUID_NULL;
      it->GetGUID(MF_MT_SUBTYPE, &s1);
      ot->GetGUID(MF_MT_SUBTYPE, &s2);
      io = subtype_name(s1) + " -> " + subtype_name(s2);
    }
    const char *c = cat == MFT_CATEGORY_VIDEO_DECODER    ? "decoder"
                    : cat == MFT_CATEGORY_VIDEO_PROCESSOR ? "processor"
                                                          : "transform";
    printf("  transform %lu: %s \"%s\" %s%s\n", (unsigned long)i, c,
           name.empty() ? "(no name)" : name.c_str(), io.c_str(), d3d11 ? " [D3D11-aware]" : "");
  }
}

static HRESULT read_loop(IMFSourceReader *reader, Gpu *g, double seconds, bool want_nv12) {
  Com<IMFMediaType> native;
  if (SUCCEEDED(reader->GetNativeMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &native)))
    print_type("source native type:", native);

  Com<IMFMediaType> out;
  CHECK(MFCreateMediaType(&out));
  CHECK(out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
  CHECK(out->SetGUID(MF_MT_SUBTYPE, want_nv12 ? MFVideoFormat_NV12 : MFVideoFormat_MJPG));
  HRESULT hr = reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, out);
  printf("SetCurrentMediaType(%s): 0x%08lx %s\n", want_nv12 ? "NV12" : "MJPG",
         (unsigned long)hr, hrtext(hr).c_str());
  if (FAILED(hr)) return hr;
  Com<IMFMediaType> cur;
  if (SUCCEEDED(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur)))
    print_type("reader output type:", cur);
  print_chain(reader);

  double start = now_s(), last_print = -1;
  int ok = 0, gpu_bufs = 0, errors = 0;
  LONGLONG last_ts = -1;
  g_last_progress = now_s();
  g_watch = 1;
  while (now_s() - start < seconds) {
    DWORD stream = 0, flags = 0;
    LONGLONG ts = 0;
    Com<IMFSample> s;
    double t0 = now_s();
    hr = reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags, &ts, &s);
    double dt = now_s() - t0;
    g_last_progress = now_s();
    if (FAILED(hr)) {
      errors++;
      printf("%7.3f ReadSample FAILED 0x%08lx %s (after %.0f ms)\n", now_s() - start,
             (unsigned long)hr, hrtext(hr).c_str(), dt * 1000);
      report_device(g);
      if (errors >= 5) break;
      continue;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) { printf("end of stream\n"); break; }
    if (flags & ~MF_SOURCE_READERF_STREAMTICK)
      printf("%7.3f flags 0x%lx\n", now_s() - start, (unsigned long)flags);
    if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) print_chain(reader);
    if (!s) continue;
    ok++;
    g_frames = ok;
    Com<IMFMediaBuffer> b;
    DWORD len = 0;
    bool on_gpu = false;
    if (SUCCEEDED(s->GetBufferByIndex(0, &b))) {
      b->GetCurrentLength(&len);
      Com<IMFDXGIBuffer> dx;
      on_gpu = SUCCEEDED(b->QueryInterface(__uuidof(IMFDXGIBuffer), (void **)&dx));
    }
    if (on_gpu) gpu_bufs++;
    if (ok <= 5 || now_s() - last_print >= 1.0) {
      printf("%7.3f frame %d ts=%.3f dts=%.1fms len=%lu %s wait=%.0fms\n", now_s() - start, ok,
             ts / 1e7, last_ts < 0 ? 0.0 : (ts - last_ts) / 1e4, (unsigned long)len,
             on_gpu ? "gpu" : "cpu", dt * 1000);
      last_print = now_s();
    }
    last_ts = ts;
  }
  g_watch = 0;
  printf("done: %d frames (%d in GPU memory), %d errors in %.1f s\n", ok, gpu_bufs, errors,
         now_s() - start);
  report_device(g);
  return S_OK;
}

static HRESULT reader_attrs(IMFAttributes **out, Gpu *g) {
  CHECK(MFCreateAttributes(out, 4));
  CHECK((*out)->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, g ? TRUE : FALSE));
  CHECK((*out)->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE));
  if (g) CHECK((*out)->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, g->mgr));
  return S_OK;
}

static HRESULT run_cam(const std::string &want, double seconds, bool sw) {
  IMFActivate **devs = nullptr;
  UINT32 n = 0;
  CHECK(list_cameras(&devs, &n));
  int pick = -1;
  for (UINT32 i = 0; i < n; i++) {
    std::string name = attr_string(devs[i], MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME);
    printf("camera [%u] %s\n", i, name.c_str());
    if (pick < 0 && name.find(want) != std::string::npos) pick = i;
  }
  if (pick < 0) { printf("no camera matching \"%s\"\n", want.c_str()); return E_FAIL; }
  printf("using camera [%d] (%s path)\n", pick, sw ? "CPU" : "GPU");

  Gpu g;
  if (!sw) CHECK(make_gpu(g));
  Com<IMFMediaSource> src;
  CHECK(devs[pick]->ActivateObject(__uuidof(IMFMediaSource), (void **)&src));
  for (UINT32 i = 0; i < n; i++) devs[i]->Release();
  CoTaskMemFree(devs);

  Com<IMFAttributes> a;
  CHECK(reader_attrs(&a, sw ? nullptr : &g));
  Com<IMFSourceReader> reader;
  CHECK(MFCreateSourceReaderFromMediaSource(src, a, &reader));
  HRESULT hr = read_loop(reader, sw ? nullptr : &g, seconds, true);
  src->Shutdown();
  return hr;
}

static HRESULT run_file(const std::string &path, bool sw) {
  Gpu g;
  if (!sw) CHECK(make_gpu(g));
  Com<IMFAttributes> a;
  CHECK(reader_attrs(&a, sw ? nullptr : &g));
  std::wstring w(path.begin(), path.end());
  Com<IMFSourceReader> reader;
  CHECK(MFCreateSourceReaderFromURL(w.c_str(), a, &reader));
  return read_loop(reader, sw ? nullptr : &g, 1e9, true);
}

int main(int argc, char **argv) {
  setvbuf(stdout, nullptr, _IONBF, 0);
  std::vector<std::string> args;
  bool sw = false, dbwin = false;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--sw")) sw = true;
    else if (!strcmp(argv[i], "--dbwin")) dbwin = true;
    else args.push_back(argv[i]);
  }
  if (dbwin) {
    CloseHandle(CreateThread(nullptr, 0, dbwin_thread, nullptr, 0, nullptr));
    Sleep(100);
  }
  CloseHandle(CreateThread(nullptr, 0, watchdog_thread, nullptr, 0, nullptr));
  if (args.empty()) args.push_back("list");
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  MFStartup(MF_VERSION);
  HRESULT hr = S_OK;
  if (args[0] == "list") {
    hr = list_decoders();
    IMFActivate **devs = nullptr;
    UINT32 n = 0;
    if (SUCCEEDED(list_cameras(&devs, &n)))
      for (UINT32 i = 0; i < n; i++) {
        printf("camera [%u] %s\n", i,
               attr_string(devs[i], MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME).c_str());
        devs[i]->Release();
      }
    CoTaskMemFree(devs);
  } else if (args[0] == "cam") {
    hr = run_cam(args.size() > 1 ? args[1] : "BRIO", args.size() > 2 ? atof(args[2].c_str()) : 10,
                 sw);
  } else if (args[0] == "file" && args.size() > 1) {
    hr = run_file(args[1], sw);
  } else {
    printf("usage: mjpegprobe list | cam [name] [sec] [--sw] | file <path> [--sw]  [--dbwin]\n");
  }
  if (dbwin) Sleep(300);   // flush late debug output
  MFShutdown();
  return FAILED(hr) ? 1 : 0;
}
