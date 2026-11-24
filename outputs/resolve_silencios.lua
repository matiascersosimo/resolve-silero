-- Ejecutar desde la consola Lua de Resolve.
local bridge = {}

function bridge.exportar(carpeta)
    assert(not bridge.job, "Primero termina o limpia el render anterior.")
    local project = assert(resolve:GetProjectManager():GetCurrentProject())
    local timeline = assert(project:GetCurrentTimeline(), "Abri una timeline.")
    local marks = timeline:GetMarkInOut()
    local audio, video = marks.audio or {}, marks.video or {}
    local range = audio["in"] and audio["out"] and audio or video
    local first, last = range["in"], range["out"]
    assert(first and last and last >= first, "Marca In y Out en la timeline.")
    assert(not project:IsRenderingInProgress(), "Resolve ya esta renderizando.")

    local start = timeline:GetStartFrame()
    local name = "silero-" .. os.date("%Y%m%d-%H%M%S")
    local old_page = resolve:GetCurrentPage()
    assert(resolve:OpenPage("deliver"), "No se pudo abrir Deliver.")
    local backup = name .. "-ajustes"
    if not project:SaveAsNewRenderPreset(backup) then
        if old_page then resolve:OpenPage(old_page) end
        error("No se pudieron guardar temporalmente los ajustes de Deliver.")
    end
    bridge.job = {
        project = project, timeline = timeline, marks = marks, backup = backup,
        old_page = old_page, first = first, last = last,
        wav = carpeta .. "/" .. name .. ".wav"
    }

    local ok, err = pcall(function()
        assert(project:LoadRenderPreset("Audio Only")
            or project:SetCurrentRenderFormatAndCodec("wav", "LinearPCM"),
            "Resolve no pudo configurar el formato WAV.")
        assert(project:SetCurrentRenderMode(1), "No se pudo configurar Single Clip.")
        assert(project:SetRenderSettings({
            TargetDir = carpeta, CustomName = name, SelectAllFrames = false,
            MarkIn = start + first, MarkOut = start + last,
            ExportVideo = false, ExportAudio = true,
            IsExportVideo = false, IsExportAudio = true,
            AudioBitDepth = 24, AudioSampleRate = 48000,
        }), "Resolve rechazo los ajustes del rango.")
        bridge.job.id = assert(project:AddRenderJob(), "No se pudo crear el render.")
        assert(project:StartRendering(bridge.job.id), "No se pudo iniciar el render.")
    end)
    if not ok then
        bridge.limpiar()
        error(err)
    end
    print("Render iniciado: " .. bridge.job.wav)
end

function bridge.limpiar()
    local job = assert(bridge.job, "No hay un render de Silero.")
    assert(not job.project:IsRenderingInProgress(), "Espera a que termine el render.")
    if job.id then job.project:DeleteRenderJob(job.id) end
    if job.project:LoadRenderPreset(job.backup) then
        job.project:DeleteRenderPreset(job.backup)
    else
        print("No se pudieron restaurar los ajustes. Preset guardado: " .. job.backup)
    end
    for _, kind in ipairs({"audio", "video"}) do
        local m = job.marks[kind] or {}
        if m["in"] and m["out"] then
            job.timeline:SetMarkInOut(m["in"], m["out"], kind)
        end
    end
    if job.old_page then resolve:OpenPage(job.old_page) end
    bridge.job = nil
    return job
end

function bridge.wav()
    local job = assert(bridge.job, "No hay un render iniciado.")
    assert(not job.project:IsRenderingInProgress(), "El render sigue en curso.")
    local status = job.project:GetRenderJobStatus(job.id)
    bridge.limpiar()
    assert(status and status.JobStatus == "Complete",
        "El render no termino correctamente: " .. tostring(status and status.JobStatus))
    local file = assert(io.open(job.wav, "rb"), "No se encontro el WAV exportado.")
    file:close()
    print(job.wav)
    return job.wav, job
end


local function wait_for(check, seconds, message, poll_seconds)
    local deadline = os.time() + seconds
    repeat
        if check() then return end
        bmd.wait(poll_seconds or 0.1)
    until os.time() >= deadline
    error(message)
end

local function quote(path)
    assert(not path:find('["%%!\r\n]'), "Ruta no compatible con cmd.exe.")
    return '"' .. path .. '"'
end

local function command_succeeded(command)
    local result = os.execute(command)
    return result == true or result == 0
end

local function intervals_from_tsv(tsv, first, last, fps)
    local intervals = {}
    for line in io.lines(tsv) do
        local a, b = line:match("^([%d.]+)%s+([%d.]+)$")
        assert(a and b, "Intervalo no valido: " .. line)
        local start = first + math.ceil(tonumber(a) * fps - 0.0001)
        local stop = math.min(last + 1, first + math.floor(tonumber(b) * fps + 0.0001))
        if start < stop then
            local previous = intervals[#intervals]
            assert(not previous or start >= previous[2], "Los intervalos se superponen.")
            if previous and start == previous[2] then
                previous[2] = stop
            else
                intervals[#intervals + 1] = {start, stop}
            end
        end
    end
    return intervals
end

local function covered(items, first, last)
    local spans = {}
    for _, item in ipairs(items) do
        local a, b = item:GetStart(), item:GetEnd()
        if a < last and b > first then spans[#spans + 1] = {a, b} end
    end
    table.sort(spans, function(a, b) return a[1] < b[1] end)
    local cursor = first
    for _, span in ipairs(spans) do
        if span[1] > cursor then return false end
        cursor = math.max(cursor, span[2])
        if cursor >= last then return true end
    end
    return false
end

local function preflight_ripple(timeline, intervals, start, finish)
    local available = {}
    for _, kind in ipairs({"video", "audio", "subtitle"}) do
        for index = 1, timeline:GetTrackCount(kind) do
            local items = timeline:GetItemListInTrack(kind, index) or {}
            local editable = kind ~= "subtitle" and not timeline:GetIsTrackLocked(kind, index)
            for _, item in ipairs(items) do
                if item:GetEnd() > start + intervals[1][1] then
                    assert(editable,
                        "Hay clips bloqueados o subtitulos que podrian perder sincronizacion.")
                end
                available[#available + 1] = item
            end
        end
    end
    local total = 0
    for _, span in ipairs(intervals) do
        local a, b = start + span[1], start + span[2]
        assert(a >= start and b <= finish and covered(available, a, b),
            "Un intervalo ya contiene un hueco. Resolve no puede cerrarlo con este comando.")
        total = total + b - a
    end
    assert(total < finish - start, "Silero marco toda la timeline como silencio.")
end

-- Project each clip onto the timeline after removing [first, last).
local function track_geometry(timeline, kind, index, first, last)
    local spans = {}
    local function add(a, b)
        if a < b then spans[#spans + 1] = string.format("%d:%d", a, b) end
    end
    for _, item in ipairs(timeline:GetItemListInTrack(kind, index) or {}) do
        local a, b = item:GetStart(), item:GetEnd()
        if first then
            add(a, math.min(b, first))
            local shift = last - first
            add(math.max(a, last) - shift, b - shift)
        else
            add(a, b)
        end
    end
    table.sort(spans)
    return table.concat(spans, ",")
end

local function marked_range(timeline, first, last)
    local marks = timeline:GetMarkInOut()
    for _, kind in ipairs({"audio", "video"}) do
        local m = marks[kind] or {}
        if m["in"] ~= first or m["out"] ~= last then return false end
    end
    return true
end

local function restore_marks(timeline, original, intervals, lowest_applied)
    -- Map both boundaries through only the deletions that were verified.
    local function remap(frame)
        for i = #intervals, lowest_applied, -1 do
            local a, b = unpack(intervals[i])
            frame = frame - math.max(0, math.min(frame, b) - a)
        end
        return frame
    end
    assert(timeline:ClearMarkInOut("all"), "Resolve no pudo limpiar las marcas temporales.")
    for _, kind in ipairs({"audio", "video"}) do
        local m = original[kind] or {}
        if m["in"] and m["out"] then
            local a, b = remap(m["in"]), remap(m["out"] + 1)
            if a < b then
                assert(timeline:SetMarkInOut(a, b - 1, kind), "No se pudo restaurar In/Out.")
            end
        end
    end
end

function bridge.cortar(project, timeline, tsv, first, last)
    local base = assert(debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])"))
    local menu = quote(base .. "ResolveMenuSession.exe")
    local session = tsv .. ".session"
    local menu_count, started = 0, false
    local function run_menu(action)
        if not started then
            local command = 'start "" /b ' .. menu .. " " .. quote(session)
            assert(command_succeeded(command), "No se pudo iniciar el control de menu de Resolve.")
            started = true
        end

        menu_count = menu_count + 1
        local prefix = session .. "-" .. menu_count
        local request, result_path = prefix .. ".request", prefix .. ".reply"
        local pending = request .. ".pending"
        local file = assert(io.open(pending, "w"))
        assert(file:write(action))
        assert(file:close())
        assert(os.rename(pending, request))

        local result
        wait_for(function()
            local file = io.open(result_path, "r")
            if not file then return false end
            result = file:read("*a")
            file:close()
            os.remove(result_path)
            return true
        end, 30, "Resolve no respondio al comando " .. action, 0.025)
        assert(result == "OK", result)
    end

    local raw = tostring(timeline:GetSetting("timelineFrameRate"))
    local fps = assert(tonumber(raw:match("[%d.]+")), "Tasa de fotogramas desconocida.")
    local fractional = {[23.976] = 24000/1001, [29.97] = 30000/1001, [59.94] = 60000/1001}
    fps = fractional[fps] or fps
    local intervals = intervals_from_tsv(tsv, first, last, fps)
    if #intervals == 0 then print("No hay intervalos cortables.") return 0 end
    local start, finish = timeline:GetStartFrame(), timeline:GetEndFrame()
    local function assert_active()
        local current_project = resolve:GetProjectManager():GetCurrentProject()
        assert(current_project and current_project:GetUniqueId() == project:GetUniqueId(),
            "El proyecto activo cambio durante el analisis.")
        local current = project:GetCurrentTimeline()
        assert(current and current:GetUniqueId() == timeline:GetUniqueId(),
            "La timeline activa cambio durante el analisis.")
    end
    assert_active()
    preflight_ripple(timeline, intervals, start, finish)
    assert(resolve:OpenPage("edit"), "No se pudo abrir Edit.")
    local original_marks = timeline:GetMarkInOut()
    for _, kind in ipairs({"audio", "video"}) do
        local m = original_marks[kind] or {}
        assert((m["in"] == nil) == (m["out"] == nil), "Completa las marcas In/Out de " .. kind .. ".")
    end
    local removed, lowest_applied = 0, #intervals + 1
    local marks_touched = false
    local now = bmd.gettime or bmd.clock or os.time
    local cut_start = now()
    local ok, error_message = pcall(function()
        run_menu("Deselect")
        for i = #intervals, 1, -1 do
            assert_active()
            local a, b = unpack(intervals[i])
            local expected = {}
            for _, kind in ipairs({"video", "audio", "subtitle"}) do
                for j = 1, timeline:GetTrackCount(kind) do
                    expected[#expected + 1] = {kind, j, track_geometry(timeline, kind, j, start+a, start+b)}
                end
            end
            marks_touched = true
            assert(timeline:SetMarkInOut(a, b - 1, "all"), "Resolve rechazo el rango de silencio.")
            assert(marked_range(timeline, a, b - 1), "In/Out no coincide con el silencio.")
            assert_active()
            run_menu("Range")
            local next_end = finish - removed - (b - a)
            wait_for(function()
                assert_active()
                if timeline:GetEndFrame() ~= next_end then return false end
                for _, track in ipairs(expected) do
                    if track_geometry(timeline, track[1], track[2]) ~= track[3] then return false end
                end
                return true
            end, 5, "Resolve no cerro el rango en todas las pistas. Revisa Edit > Undo y la seleccion automatica de pistas.")
            removed = removed + b - a
            lowest_applied = i
        end
    end)
    if started then
        local stop = io.open(session .. ".stop", "w")
        if stop then stop:close() end
        local latest = session .. "-" .. menu_count
        os.remove(latest .. ".request")
        os.remove(latest .. ".request.pending")
        os.remove(latest .. ".reply")
    end
    if marks_touched then
        local restored, err = pcall(function()
            assert_active()
            restore_marks(timeline, original_marks, intervals, lowest_applied)
        end)
        if not restored then error((ok and "" or tostring(error_message) .. " ") .. tostring(err)) end
    end
    assert(ok, error_message)
    print(string.format("%d silencios eliminados (%.2f s) en %s. Edicion: %.2f s.",
        #intervals, removed / fps, timeline:GetName(), now() - cut_start))
    return #intervals
end

function bridge.ejecutar(carpeta, ffmpeg)
    local script = debug.getinfo(1, "S").source:sub(2)
    local base = assert(script:match("^(.*[/\\])"), "Carga el script con la ruta completa.")
    local detector = "py " .. quote(base .. "detectar_silencios.py")
    local ffmpeg_option = ffmpeg and (" --ffmpeg " .. quote(ffmpeg)) or ""
    quote(carpeta)
    bridge.exportar(carpeta)
    wait_for(function() return not bridge.job.project:IsRenderingInProgress() end,
        900, "El render sigue en curso. Cuando termine, ejecuta bridge.wav().")
    local wav, job = bridge.wav()
    local tsv = wav .. ".tsv"
    assert(command_succeeded(detector .. " " .. quote(wav) .. ffmpeg_option
        .. " > " .. quote(tsv)), "Fallo la deteccion de Silero.")
    return bridge.cortar(job.project, job.timeline, tsv, job.first, job.last)
end

return bridge
