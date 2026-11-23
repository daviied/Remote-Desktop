// rd-hostd: RD Windows host helper.
//
//   rd-hostd display list              List virtual displays (index, GDI name, active, mode).
//   rd-hostd display attach <n>        Turn on virtual display n and set it to the client's
//                                      resolution/refresh (SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS).
//   rd-hostd display detach <n>        Turn off virtual display n (display 1 always stays on).
//   rd-hostd display init              Turn off virtual displays 2+ (run at logon).
//   rd-hostd display attach-all        Turn on all virtual displays (to pick them in Sunshine).
//   rd-hostd tray                      Show client battery icons in the taskbar.
//
// Virtual displays are matched by monitor device path / friendly name. Default match list:
// "MTT1337;VDD;Virtual Display". Override with env RD_VDD_MATCH="a;b;c".
// Displays are arranged left to right in index order; display 1 is primary.

#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <cstdio>
#include <cwchar>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <vector>

namespace fs = std::filesystem;

// ---------------------------------------------------------------- utils

static std::wstring widen(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

static std::wstring lower(std::wstring s) {
    std::transform(s.begin(), s.end(), s.begin(), ::towlower);
    return s;
}

static int envInt(const wchar_t* name, int fallback) {
    wchar_t buf[32];
    DWORD n = GetEnvironmentVariableW(name, buf, 32);
    return (n > 0 && n < 32) ? _wtoi(buf) : fallback;
}

static fs::path programData() {
    wchar_t buf[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"ProgramData", buf, MAX_PATH);
    return fs::path(n > 0 && n < MAX_PATH ? buf : L"C:\\ProgramData") / L"RD";
}

static void logLine(const wchar_t* fmt, ...) {
    wchar_t msg[1024];
    va_list va;
    va_start(va, fmt);
    vswprintf(msg, 1024, fmt, va);
    va_end(va);
    fwprintf(stdout, L"%ls\n", msg);
    std::error_code ec;
    fs::create_directories(programData(), ec);
    FILE* f = _wfopen((programData() / L"rd-hostd.log").c_str(), L"a");
    if (f) {
        time_t t = time(nullptr);
        char ts[32];
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", localtime(&t));
        fwprintf(f, L"%hs %ls\n", ts, msg);
        fclose(f);
    }
}

// ---------------------------------------------------------------- displays

struct VTarget {
    LUID adapter;
    UINT32 targetId;
    std::wstring path;
    std::wstring friendly;
};

struct Config {
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
};

static bool sameLuid(const LUID& a, const LUID& b) {
    return a.LowPart == b.LowPart && a.HighPart == b.HighPart;
}

static bool queryConfig(UINT32 flags, Config& cfg) {
    for (int attempt = 0; attempt < 5; attempt++) {
        UINT32 np = 0, nm = 0;
        if (GetDisplayConfigBufferSizes(flags, &np, &nm) != ERROR_SUCCESS) return false;
        cfg.paths.resize(np);
        cfg.modes.resize(nm);
        LONG r = QueryDisplayConfig(flags, &np, cfg.paths.data(), &nm, cfg.modes.data(), nullptr);
        if (r == ERROR_INSUFFICIENT_BUFFER) continue;
        if (r != ERROR_SUCCESS) return false;
        cfg.paths.resize(np);
        cfg.modes.resize(nm);
        return true;
    }
    return false;
}

static std::vector<std::wstring> matchList() {
    wchar_t buf[512];
    DWORD n = GetEnvironmentVariableW(L"RD_VDD_MATCH", buf, 512);
    std::wstring s = (n > 0 && n < 512) ? buf : L"MTT1337;VDD;Virtual Display";
    std::vector<std::wstring> out;
    size_t start = 0;
    while (start <= s.size()) {
        size_t end = s.find(L';', start);
        if (end == std::wstring::npos) end = s.size();
        if (end > start) out.push_back(lower(s.substr(start, end - start)));
        start = end + 1;
    }
    return out;
}

// All virtual display targets, sorted (adapter, target id). Index 0 = virtual display 1.
static std::vector<VTarget> virtualTargets(const Config& all) {
    auto matches = matchList();
    std::vector<VTarget> out;
    for (const auto& p : all.paths) {
        bool dup = false;
        for (const auto& t : out) {
            if (sameLuid(t.adapter, p.targetInfo.adapterId) && t.targetId == p.targetInfo.id) dup = true;
        }
        if (dup || !p.targetInfo.targetAvailable) continue;

        DISPLAYCONFIG_TARGET_DEVICE_NAME tn = {};
        tn.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        tn.header.size = sizeof(tn);
        tn.header.adapterId = p.targetInfo.adapterId;
        tn.header.id = p.targetInfo.id;
        if (DisplayConfigGetDeviceInfo(&tn.header) != ERROR_SUCCESS) continue;

        std::wstring path = tn.monitorDevicePath, friendly = tn.monitorFriendlyDeviceName;
        std::wstring hay = lower(path + L"|" + friendly);
        bool ok = false;
        for (const auto& m : matches) {
            if (hay.find(m) != std::wstring::npos) ok = true;
        }
        if (ok) out.push_back({ p.targetInfo.adapterId, p.targetInfo.id, path, friendly });
    }
    std::sort(out.begin(), out.end(), [](const VTarget& a, const VTarget& b) {
        if (a.adapter.HighPart != b.adapter.HighPart) return a.adapter.HighPart < b.adapter.HighPart;
        if (a.adapter.LowPart != b.adapter.LowPart) return a.adapter.LowPart < b.adapter.LowPart;
        return a.targetId < b.targetId;
    });
    return out;
}

static const DISPLAYCONFIG_PATH_INFO* activePathFor(const Config& active, const VTarget& t) {
    for (const auto& p : active.paths) {
        if ((p.flags & DISPLAYCONFIG_PATH_ACTIVE) && sameLuid(p.targetInfo.adapterId, t.adapter) && p.targetInfo.id == t.targetId) {
            return &p;
        }
    }
    return nullptr;
}

static std::wstring gdiName(const DISPLAYCONFIG_PATH_INFO& p) {
    DISPLAYCONFIG_SOURCE_DEVICE_NAME sn = {};
    sn.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    sn.header.size = sizeof(sn);
    sn.header.adapterId = p.sourceInfo.adapterId;
    sn.header.id = p.sourceInfo.id;
    if (DisplayConfigGetDeviceInfo(&sn.header) != ERROR_SUCCESS) return L"";
    return sn.viewGdiDeviceName;
}

// Turn the given virtual displays on (wantOn) and every other virtual display as listed in wantOff off.
static bool applyTopology(const std::vector<int>& turnOn, const std::vector<int>& turnOff) {
    Config all, active;
    if (!queryConfig(QDC_ALL_PATHS, all) || !queryConfig(QDC_ONLY_ACTIVE_PATHS, active)) {
        logLine(L"QueryDisplayConfig failed");
        return false;
    }
    auto vts = virtualTargets(all);

    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    for (const auto& p : active.paths) {
        bool drop = false;
        for (int idx : turnOff) {
            if (idx >= 1 && idx <= (int)vts.size() && sameLuid(p.targetInfo.adapterId, vts[idx - 1].adapter) &&
                p.targetInfo.id == vts[idx - 1].targetId) {
                drop = true;
            }
        }
        if (!drop) paths.push_back(p);
    }

    bool changed = paths.size() != active.paths.size();
    for (int idx : turnOn) {
        if (idx < 1 || idx > (int)vts.size()) {
            logLine(L"Virtual display %d not found (%zu found). Check RD_VDD_MATCH / VDD monitor count.", idx, vts.size());
            return false;
        }
        const VTarget& t = vts[idx - 1];
        if (activePathFor(active, t)) continue;

        // Pick an inactive path for this target whose source is not used by any active path.
        const DISPLAYCONFIG_PATH_INFO* pick = nullptr;
        for (const auto& p : all.paths) {
            if (!sameLuid(p.targetInfo.adapterId, t.adapter) || p.targetInfo.id != t.targetId) continue;
            bool used = false;
            for (const auto& q : paths) {
                if (sameLuid(q.sourceInfo.adapterId, p.sourceInfo.adapterId) && q.sourceInfo.id == p.sourceInfo.id) used = true;
            }
            if (!used) { pick = &p; break; }
        }
        if (!pick) {
            logLine(L"No free source for virtual display %d", idx);
            return false;
        }
        DISPLAYCONFIG_PATH_INFO np = *pick;
        np.flags = DISPLAYCONFIG_PATH_ACTIVE;
        np.sourceInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
        np.targetInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
        paths.push_back(np);
        changed = true;
    }

    if (!changed) return true;
    if (paths.empty()) {
        logLine(L"Refusing to turn off every display");
        return false;
    }

    LONG r = SetDisplayConfig((UINT32)paths.size(), paths.data(), (UINT32)active.modes.size(), active.modes.data(),
                              SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
    if (r != ERROR_SUCCESS) {
        logLine(L"SetDisplayConfig failed: %ld", r);
        return false;
    }
    return true;
}

static bool setMode(const std::wstring& gdi, int width, int height, int fps, int x, int y, bool primary) {
    DEVMODEW dm = {};
    dm.dmSize = sizeof(dm);
    if (!EnumDisplaySettingsExW(gdi.c_str(), ENUM_CURRENT_SETTINGS, &dm, 0)) return false;

    dm.dmFields = DM_POSITION;
    dm.dmPosition.x = x;
    dm.dmPosition.y = y;
    if (width > 0 && height > 0) {
        dm.dmPelsWidth = width;
        dm.dmPelsHeight = height;
        dm.dmFields |= DM_PELSWIDTH | DM_PELSHEIGHT;
    }
    if (fps > 0) {
        dm.dmDisplayFrequency = fps;
        dm.dmFields |= DM_DISPLAYFREQUENCY;
    }
    DWORD flags = CDS_UPDATEREGISTRY | CDS_NORESET | (primary ? CDS_SET_PRIMARY : 0);
    LONG r = ChangeDisplaySettingsExW(gdi.c_str(), &dm, nullptr, flags, nullptr);
    if (r != DISP_CHANGE_SUCCESSFUL && fps > 0) {
        // Mode list may not have this refresh rate: keep resolution, let Windows pick refresh.
        dm.dmFields &= ~DM_DISPLAYFREQUENCY;
        r = ChangeDisplaySettingsExW(gdi.c_str(), &dm, nullptr, flags, nullptr);
    }
    if (r != DISP_CHANGE_SUCCESSFUL) {
        logLine(L"%ls: mode %dx%d@%d failed (%ld). Add this mode to the Virtual Display Driver settings.", gdi.c_str(), width, height, fps, r);
        return false;
    }
    return true;
}

// Arrange active virtual displays left to right; optionally set the mode of one of them.
static void arrange(int modeIdx, int width, int height, int fps) {
    Config all, active;
    if (!queryConfig(QDC_ALL_PATHS, all) || !queryConfig(QDC_ONLY_ACTIVE_PATHS, active)) return;
    auto vts = virtualTargets(all);

    int x = 0;
    for (size_t i = 0; i < vts.size(); i++) {
        const auto* p = activePathFor(active, vts[i]);
        if (!p) continue;
        std::wstring gdi = gdiName(*p);
        int w = 0, h = 0, f = 0;
        if ((int)i + 1 == modeIdx) { w = width; h = height; f = fps; }
        setMode(gdi, w, h, f, x, 0, x == 0);

        DEVMODEW cur = {};
        cur.dmSize = sizeof(cur);
        int curW = w;
        if (EnumDisplaySettingsExW(gdi.c_str(), ENUM_REGISTRY_SETTINGS, &cur, 0)) curW = cur.dmPelsWidth;
        x += curW > 0 ? curW : 1920;
    }
    ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
}

static int cmdDisplay(int argc, wchar_t** argv) {
    std::wstring sub = argc > 2 ? argv[2] : L"list";
    int idx = argc > 3 ? _wtoi(argv[3]) : 0;

    Config all, active;
    if (!queryConfig(QDC_ALL_PATHS, all) || !queryConfig(QDC_ONLY_ACTIVE_PATHS, active)) {
        logLine(L"QueryDisplayConfig failed");
        return 1;
    }
    auto vts = virtualTargets(all);

    if (sub == L"list") {
        wprintf(L"%zu virtual display(s):\n", vts.size());
        for (size_t i = 0; i < vts.size(); i++) {
            const auto* p = activePathFor(active, vts[i]);
            std::wstring gdi = p ? gdiName(*p) : L"-";
            DEVMODEW dm = {};
            dm.dmSize = sizeof(dm);
            if (p && EnumDisplaySettingsExW(gdi.c_str(), ENUM_CURRENT_SETTINGS, &dm, 0)) {
                wprintf(L"  %zu  %-14ls on   %lux%lu@%lu  pos %ld,%ld  %ls\n", i + 1, gdi.c_str(), dm.dmPelsWidth, dm.dmPelsHeight,
                        dm.dmDisplayFrequency, dm.dmPosition.x, dm.dmPosition.y, vts[i].friendly.c_str());
            } else {
                wprintf(L"  %zu  %-14ls off  %ls\n", i + 1, gdi.c_str(), vts[i].friendly.c_str());
            }
            wprintf(L"       %ls\n", vts[i].path.c_str());
        }
        return 0;
    }

    if (sub == L"attach") {
        int w = envInt(L"SUNSHINE_CLIENT_WIDTH", argc > 4 ? _wtoi(argv[4]) : 0);
        int h = envInt(L"SUNSHINE_CLIENT_HEIGHT", argc > 5 ? _wtoi(argv[5]) : 0);
        int f = envInt(L"SUNSHINE_CLIENT_FPS", argc > 6 ? _wtoi(argv[6]) : 0);
        logLine(L"attach %d %dx%d@%d", idx, w, h, f);
        if (idx < 1 || idx > (int)vts.size()) {
            // No Virtual Display Driver (or fewer monitors): never block the stream; Sunshine uses its current display.
            logLine(L"attach %d: virtual display not found (%zu found); streaming the current display. Install VDD.", idx, vts.size());
            return 0;
        }
        if (!applyTopology({ idx }, {})) return 1;
        Sleep(300);
        arrange(idx, w, h, f);
        return 0;
    }

    if (sub == L"detach") {
        logLine(L"detach %d", idx);
        if (idx <= 1) return 0;  // display 1 always stays on (host needs one display)
        if (idx > (int)vts.size()) return 0;
        if (!applyTopology({}, { idx })) return 1;
        Sleep(300);
        arrange(0, 0, 0, 0);
        return 0;
    }

    if (sub == L"init") {
        if (vts.empty()) { logLine(L"init: no virtual displays (install VDD)"); return 0; }
        std::vector<int> off;
        for (int i = 2; i <= (int)vts.size(); i++) off.push_back(i);
        applyTopology({ 1 }, off);
        Sleep(300);
        arrange(0, 0, 0, 0);
        return 0;
    }

    if (sub == L"attach-all") {
        std::vector<int> on;
        for (int i = 1; i <= (int)vts.size(); i++) on.push_back(i);
        applyTopology(on, {});
        Sleep(300);
        arrange(0, 0, 0, 0);
        return 0;
    }

    wprintf(L"unknown display command\n");
    return 2;
}

// ---------------------------------------------------------------- tray

struct ClientBattery {
    std::wstring instance, name;
    int percent = 255, flags = 0, minutes = 0xFFFF;
    long long time = 0;
};

#define WM_RD_TRAY (WM_APP + 1)
#define RD_TIMER 1
#define RD_MENU_EXIT 100

static std::map<std::wstring, UINT> g_Icons;       // file -> icon id
static std::map<UINT, HICON> g_IconHandles;
static UINT g_NextId = 1;
static HWND g_Wnd;

static bool readBattery(const fs::path& file, ClientBattery& b) {
    std::ifstream f(file);
    if (!f) return false;
    std::string line;
    while (std::getline(f, line)) {
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string k = line.substr(0, eq), v = line.substr(eq + 1);
        if (k == "instance") b.instance = widen(v);
        else if (k == "name") b.name = widen(v);
        else if (k == "percent") b.percent = atoi(v.c_str());
        else if (k == "flags") b.flags = atoi(v.c_str());
        else if (k == "minutes") b.minutes = atoi(v.c_str());
        else if (k == "time") b.time = atoll(v.c_str());
    }
    return true;
}

static HICON makeBatteryIcon(const ClientBattery& b) {
    const int S = GetSystemMetrics(SM_CXSMICON) >= 24 ? 32 : 16;
    BITMAPV5HEADER bi = {};
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = S;
    bi.bV5Height = -S;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;

    HDC screen = GetDC(nullptr);
    void* bits = nullptr;
    HBITMAP color = CreateDIBSection(screen, (BITMAPINFO*)&bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HDC dc = CreateCompatibleDC(screen);
    HGDIOBJ old = SelectObject(dc, color);

    // Background: green charging, red <15, amber <30, dark grey otherwise, grey no battery
    COLORREF bg = RGB(60, 60, 60);
    if (b.flags & 4) bg = RGB(110, 110, 110);
    else if (b.flags & 2) bg = RGB(30, 140, 60);
    else if (b.percent <= 15) bg = RGB(200, 40, 40);
    else if (b.percent <= 30) bg = RGB(210, 140, 0);

    HBRUSH br = CreateSolidBrush(bg);
    HGDIOBJ oldBr = SelectObject(dc, br);
    HGDIOBJ oldPen = SelectObject(dc, GetStockObject(NULL_PEN));
    RoundRect(dc, 0, 0, S + 1, S + 1, S / 3, S / 3);
    SelectObject(dc, oldPen);
    SelectObject(dc, oldBr);
    DeleteObject(br);

    // Level bar along the bottom
    if (!(b.flags & 4) && b.percent <= 100) {
        RECT bar = { 1, S - S / 6, 1 + (S - 2) * b.percent / 100, S - 1 };
        HBRUSH lb = CreateSolidBrush(RGB(255, 255, 255));
        FillRect(dc, &bar, lb);
        DeleteObject(lb);
    }

    wchar_t txt[8];
    if (b.flags & 4) wcscpy(txt, L"AC");
    else if (b.percent > 100) wcscpy(txt, L"?");
    else swprintf(txt, 8, L"%d", b.percent >= 100 ? 99 : b.percent);
    HFONT font = CreateFontW(-(S * 3 / 4), 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, ANTIALIASED_QUALITY, 0, L"Segoe UI");
    HGDIOBJ oldFont = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(255, 255, 255));
    RECT r = { 0, -S / 12, S, S - S / 6 };
    DrawTextW(dc, txt, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    SelectObject(dc, oldFont);
    DeleteObject(font);
    GdiFlush();

    // GDI leaves alpha at 0; make everything drawn opaque, keep rounded corners transparent.
    auto px = (DWORD*)bits;
    for (int i = 0; i < S * S; i++) {
        px[i] = (px[i] & 0x00FFFFFF) ? (px[i] | 0xFF000000) : 0;
    }

    SelectObject(dc, old);
    DeleteDC(dc);
    ReleaseDC(nullptr, screen);

    HBITMAP mask = CreateBitmap(S, S, 1, 1, nullptr);
    ICONINFO ii = { TRUE, 0, 0, mask, color };
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(mask);
    DeleteObject(color);
    return icon;
}

static void setTip(NOTIFYICONDATAW& nid, const ClientBattery& b) {
    std::wstring tip = (b.name.empty() ? L"Client" : b.name) + L" (" + b.instance + L")\n";
    if (b.flags & 4) tip += L"No battery (plugged in)";
    else {
        tip += b.percent <= 100 ? std::to_wstring(b.percent) + L"%" : L"Unknown";
        if (b.flags & 2) tip += L" - charging";
        else if (b.flags & 1) tip += L" - on battery";
        else tip += L" - plugged in";
        if (b.minutes != 0xFFFF && b.minutes > 0) {
            tip += L"\n" + std::to_wstring(b.minutes / 60) + L"h " + std::to_wstring(b.minutes % 60) + L"m " +
                   ((b.flags & 2) ? L"to full" : L"left");
        }
    }
    wcsncpy(nid.szTip, tip.c_str(), ARRAYSIZE(nid.szTip) - 1);
}

static void refreshTray() {
    fs::path dir = programData() / L"clients";
    std::map<std::wstring, ClientBattery> now;
    std::error_code ec;
    long long t = (long long)time(nullptr);
    for (auto& e : fs::directory_iterator(dir, ec)) {
        if (e.path().extension() != L".txt") continue;
        ClientBattery b;
        // Stale after 5 minutes without an update (client clock is not used)
        if (readBattery(e.path(), b) && t - b.time < 300) now[e.path().filename().wstring()] = b;
    }

    // Remove icons for clients that left
    for (auto it = g_Icons.begin(); it != g_Icons.end();) {
        if (!now.count(it->first)) {
            NOTIFYICONDATAW nid = {}; nid.cbSize = sizeof(nid);
            nid.hWnd = g_Wnd;
            nid.uID = it->second;
            Shell_NotifyIconW(NIM_DELETE, &nid);
            if (g_IconHandles[it->second]) DestroyIcon(g_IconHandles[it->second]);
            g_IconHandles.erase(it->second);
            it = g_Icons.erase(it);
        } else {
            ++it;
        }
    }

    for (auto& [file, b] : now) {
        bool isNew = !g_Icons.count(file);
        if (isNew) g_Icons[file] = g_NextId++;
        UINT id = g_Icons[file];

        NOTIFYICONDATAW nid = {}; nid.cbSize = sizeof(nid);
        nid.hWnd = g_Wnd;
        nid.uID = id;
        nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE | NIF_SHOWTIP;
        nid.uCallbackMessage = WM_RD_TRAY;
        HICON icon = makeBatteryIcon(b);
        nid.hIcon = icon;
        setTip(nid, b);
        if (isNew) {
            Shell_NotifyIconW(NIM_ADD, &nid);
            nid.uVersion = NOTIFYICON_VERSION_4;
            Shell_NotifyIconW(NIM_SETVERSION, &nid);
        } else {
            Shell_NotifyIconW(NIM_MODIFY, &nid);
        }
        if (g_IconHandles[id]) DestroyIcon(g_IconHandles[id]);
        g_IconHandles[id] = icon;
    }
}

static void removeAllIcons() {
    for (auto& [file, id] : g_Icons) {
        NOTIFYICONDATAW nid = {}; nid.cbSize = sizeof(nid);
        nid.hWnd = g_Wnd;
        nid.uID = id;
        Shell_NotifyIconW(NIM_DELETE, &nid);
    }
    g_Icons.clear();
}

static LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    static UINT taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    if (msg == taskbarCreated) {
        // Explorer restarted: re-add icons
        g_Icons.clear();
        refreshTray();
        return 0;
    }
    switch (msg) {
    case WM_TIMER:
        refreshTray();
        return 0;
    case WM_RD_TRAY:
        if (LOWORD(lp) == WM_CONTEXTMENU || LOWORD(lp) == WM_RBUTTONUP) {
            POINT pt;
            GetCursorPos(&pt);
            HMENU m = CreatePopupMenu();
            AppendMenuW(m, MF_STRING, RD_MENU_EXIT, L"Exit RD battery icons");
            SetForegroundWindow(hwnd);
            if (TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, nullptr) == RD_MENU_EXIT) {
                DestroyWindow(hwnd);
            }
            DestroyMenu(m);
        }
        return 0;
    case WM_DESTROY:
        removeAllIcons();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static int cmdTray() {
    FreeConsole();  // tray runs in the background
    HANDLE single = CreateMutexW(nullptr, TRUE, L"Local\\rd-hostd-tray");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    // Default to only virtual display 1 on at logon
    wchar_t* initArgs[] = { (wchar_t*)L"rd-hostd", (wchar_t*)L"display", (wchar_t*)L"init" };
    cmdDisplay(3, initArgs);

    WNDCLASSW wc = {};
    wc.lpfnWndProc = wndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"RdHostdTray";
    RegisterClassW(&wc);
    // Hidden top-level window (message-only windows don't get TaskbarCreated).
    g_Wnd = CreateWindowW(wc.lpszClassName, L"rd-hostd", WS_OVERLAPPED, 0, 0, 0, 0, nullptr, nullptr, wc.hInstance, nullptr);

    SetTimer(g_Wnd, RD_TIMER, 5000, nullptr);
    refreshTray();

    MSG m;
    while (GetMessageW(&m, nullptr, 0, 0) > 0) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    CloseHandle(single);
    return 0;
}

// ---------------------------------------------------------------- main

int wmain(int argc, wchar_t** argv) {
    // Per-monitor DPI awareness so display coordinates are real pixels
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    std::wstring cmd = argc > 1 ? argv[1] : L"";
    if (cmd == L"display") return cmdDisplay(argc, argv);
    if (cmd == L"tray") return cmdTray();

    wprintf(L"usage:\n"
            L"  rd-hostd display list|init|attach-all\n"
            L"  rd-hostd display attach <n> [width height fps]   (defaults from SUNSHINE_CLIENT_*)\n"
            L"  rd-hostd display detach <n>\n"
            L"  rd-hostd tray\n");
    return 2;
}
