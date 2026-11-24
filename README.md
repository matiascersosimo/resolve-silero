# Silero para DaVinci Resolve

Script local para Windows que exporta el audio entre las marcas In y Out, detecta pausas con Silero VAD y las elimina con Ripple Delete en la timeline activa. Conserva 100 ms antes de la voz y 50 ms después. Usa los menús de Resolve en inglés y necesita que la ventana principal esté en primer plano durante la edición.

## Instalación

1. Instalá Python con el lanzador `py` y ejecutá `py -m pip install torch silero-vad`.
2. Agregá FFmpeg al Path o configurá la variable de entorno `SILERO_FFMPEG` con la ruta completa a `ffmpeg.exe`.
3. Creá una carpeta `Silero` dentro de `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility`. Copiá allí los dos archivos Lua, `detectar_silencios.py` y `ResolveMenuSession.exe` de `outputs`. El código fuente del auxiliar está en `outputs/ResolveMenu.cs`.
4. Abrí Resolve, marcá In y Out en la timeline y ejecutá **Silero - Cortar silencios** desde **Workspace → Scripts**. El resumen de la edición aparece en **Workspace → Console**.
