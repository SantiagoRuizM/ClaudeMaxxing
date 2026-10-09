// Windows 11 context menu entry "Abrir con Claude Code" (IExplorerCommand).
#include <windows.h>
#include <shobjidl_core.h>
#include <shlobj_core.h>
#include <shlwapi.h>
#include <shellapi.h>
#include <wrl/module.h>
#include <wrl/implements.h>
#include <wrl/client.h>
#include <string>

#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "runtimeobject.lib")

using namespace Microsoft::WRL;

static HMODULE g_module = nullptr;

static std::wstring ModuleDir()
{
    wchar_t buf[MAX_PATH];
    GetModuleFileNameW(g_module, buf, MAX_PATH);
    PathRemoveFileSpecW(buf);
    return buf;
}

static std::wstring PathFromItem(IShellItem* item)
{
    std::wstring result;
    PWSTR p = nullptr;
    if (item && SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &p)))
    {
        result = p;
        CoTaskMemFree(p);
    }
    return result;
}

static std::wstring PathFromSite(IUnknown* site)
{
    if (!site) return {};
    ComPtr<IServiceProvider> sp;
    ComPtr<IShellBrowser> browser;
    ComPtr<IShellView> view;
    ComPtr<IFolderView> folderView;
    ComPtr<IShellItem> folder;
    if (FAILED(site->QueryInterface(IID_PPV_ARGS(&sp)))) return {};
    if (FAILED(sp->QueryService(SID_STopLevelBrowser, IID_PPV_ARGS(&browser)))) return {};
    if (FAILED(browser->QueryActiveShellView(&view))) return {};
    if (FAILED(view.As(&folderView))) return {};
    if (FAILED(folderView->GetFolder(IID_PPV_ARGS(&folder)))) return {};
    return PathFromItem(folder.Get());
}

// Quote an argument so CommandLineToArgvW and wt.exe read it back verbatim.
static std::wstring QuoteForWt(const std::wstring& path)
{
    std::wstring s;
    for (wchar_t c : path)
    {
        if (c == L';') s += L'\\';  // wt.exe treats a bare ';' as a command separator
        s += c;
    }
    if (!s.empty() && s.back() == L'\\') s += L'\\';  // keep "C:\" from escaping the closing quote
    return L"\"" + s + L"\"";
}

class __declspec(uuid("7DFFC792-7471-4449-8FD1-BF6278E7106A")) ClaudeCodeCommand final
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IExplorerCommand, IObjectWithSite>
{
public:
    // IExplorerCommand
    IFACEMETHODIMP GetTitle(IShellItemArray*, PWSTR* name) override
    {
        return SHStrDupW(L"Abrir con Claude Code", name);
    }

    IFACEMETHODIMP GetIcon(IShellItemArray*, PWSTR* icon) override
    {
        return SHStrDupW((ModuleDir() + L"\\Assets\\claude.ico").c_str(), icon);
    }

    IFACEMETHODIMP GetToolTip(IShellItemArray*, PWSTR* tip) override
    {
        *tip = nullptr;
        return E_NOTIMPL;
    }

    IFACEMETHODIMP GetCanonicalName(GUID* guid) override
    {
        *guid = __uuidof(ClaudeCodeCommand);
        return S_OK;
    }

    IFACEMETHODIMP GetState(IShellItemArray*, BOOL, EXPCMDSTATE* state) override
    {
        *state = ECS_ENABLED;
        return S_OK;
    }

    IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*) override
    {
        std::wstring dir;
        DWORD count = 0;
        if (items && SUCCEEDED(items->GetCount(&count)) && count > 0)
        {
            ComPtr<IShellItem> item;
            if (SUCCEEDED(items->GetItemAt(0, &item))) dir = PathFromItem(item.Get());
        }
        if (dir.empty()) dir = PathFromSite(m_site.Get());
        if (dir.empty()) return E_FAIL;

        std::wstring args = L"-d " + QuoteForWt(dir) + L" cmd /k claude";
        HINSTANCE r = ShellExecuteW(nullptr, L"open", L"wt.exe", args.c_str(), dir.c_str(), SW_SHOWNORMAL);
        if (reinterpret_cast<INT_PTR>(r) <= 32)
        {
            // Windows Terminal missing: fall back to a plain console.
            ShellExecuteW(nullptr, L"open", L"cmd.exe", L"/k claude", dir.c_str(), SW_SHOWNORMAL);
        }
        return S_OK;
    }

    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override
    {
        *flags = ECF_DEFAULT;
        return S_OK;
    }

    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** e) override
    {
        *e = nullptr;
        return E_NOTIMPL;
    }

    // IObjectWithSite
    IFACEMETHODIMP SetSite(IUnknown* site) override
    {
        m_site = site;
        return S_OK;
    }

    IFACEMETHODIMP GetSite(REFIID riid, void** ppv) override
    {
        if (!m_site) { *ppv = nullptr; return E_FAIL; }
        return m_site.CopyTo(riid, ppv);
    }

private:
    ComPtr<IUnknown> m_site;
};

CoCreatableClass(ClaudeCodeCommand)

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv)
{
    return Module<InProc>::GetModule().GetClassObject(rclsid, riid, ppv);
}

STDAPI DllCanUnloadNow()
{
    return Module<InProc>::GetModule().Terminate() ? S_OK : S_FALSE;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_module = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}
