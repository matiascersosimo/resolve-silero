-- Abrir desde Workspace > Scripts > Silero - Cortar silencios.
local script = debug.getinfo(1, "S").source:sub(2)
local folder = assert(script:match("^(.*[/\\])"), "No se encontro la carpeta del script.")
local bridge = assert(loadfile(folder .. "resolve_silencios.lua"))()
local temp = assert(os.getenv("TEMP"), "No se encontro la carpeta temporal.")
bridge.ejecutar(temp, os.getenv("SILERO_FFMPEG"))
