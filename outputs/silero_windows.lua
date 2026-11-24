-- Start Windows processes directly so Resolve never needs a command shell.
local ffi = require("ffi")
if not pcall(ffi.typeof, "SileroStartupInfo") then
    ffi.cdef[[
        typedef struct {
            uint32_t cb; wchar_t *reserved, *desktop, *title;
            uint32_t x, y, width, height, columns, rows, fill, flags;
            uint16_t show, reserved_size; void *reserved_data, *input, *output, *error;
        } SileroStartupInfo;
        typedef struct { void *process, *thread; uint32_t pid, tid; } SileroProcessInfo;
        int __stdcall CreateProcessW(const wchar_t*, wchar_t*, void*, void*, int,
            uint32_t, void*, const wchar_t*, SileroStartupInfo*, SileroProcessInfo*);
        int __stdcall MultiByteToWideChar(unsigned int, uint32_t, const char*, int, wchar_t*, int);
        uint32_t __stdcall WaitForSingleObject(void*, uint32_t);
        int __stdcall GetExitCodeProcess(void*, uint32_t*);
        int __stdcall CloseHandle(void*);
        uint32_t __stdcall GetLastError(void);
        uint32_t __stdcall GetCurrentProcessId(void);
        uint32_t __stdcall GetTickCount(void);
    ]]
end
local win = ffi.load("kernel32")
local windows = {}

function windows.run_id()
    return string.format("%d-%d-%s", win.GetCurrentProcessId(), win.GetTickCount(),
        tostring({}):match("%x+$"))
end

function windows.start(executable, args, wait)
    -- These arguments are file paths or fixed switches, never shell expressions.
    local function quoted(path)
        assert(not path:find('["%z]'), "Ruta de proceso no valida.")
        return '"' .. path:gsub('(\\+)$', '%1%1') .. '"'
    end
    local parts = {quoted(executable)}
    for _, arg in ipairs(args) do parts[#parts+1] = quoted(arg) end
    local cmd = table.concat(parts, " ")
    local wide = ffi.new("wchar_t[?]", #cmd + 1)
    assert(win.MultiByteToWideChar(65001, 8, cmd, -1, wide, #cmd + 1) > 0,
        "Windows no pudo leer la ruta del proceso.")
    local startup = ffi.new("SileroStartupInfo")
    startup.cb = ffi.sizeof(startup)
    local info = ffi.new("SileroProcessInfo")
    if win.CreateProcessW(nil, wide, nil, nil, 0, 0x08000000, nil, nil, startup, info) == 0 then
        error(string.format("No se pudo iniciar %s (Windows %d).", executable, win.GetLastError()))
    end
    win.CloseHandle(info.thread)
    if not wait then win.CloseHandle(info.process); return end
    local handle = ffi.gc(info.process, win.CloseHandle)
    local state = win.WaitForSingleObject(handle, 0)
    while state == 258 do -- WAIT_TIMEOUT
        bmd.wait(0.05)
        state = win.WaitForSingleObject(handle, 0)
    end
    local code = ffi.new("uint32_t[1]")
    local completed = state == 0 and win.GetExitCodeProcess(handle, code) ~= 0
    win.CloseHandle(ffi.gc(handle, nil))
    assert(completed, "Windows no pudo leer el resultado del proceso.")
    return tonumber(code[0])
end

function windows.pid() return tonumber(win.GetCurrentProcessId()) end
return windows
