# Silero para DaVinci Resolve

Creado por **Matias Gabriel Cersosimo** ([@matiascersosimo](https://github.com/matiascersosimo)).

Cuando editaba un video con muchas pausas, repetía la misma tarea una y otra vez. Buscaba dónde terminaba una frase, cortaba hasta el comienzo de la siguiente y juntaba los clips. Necesitaba una herramienta que hiciera eso directamente en la timeline de DaVinci Resolve, así que la creé.

## Qué hace

Marcás un tramo con **In** y **Out**. El script exporta ese audio a WAV, detecta las pausas con Silero VAD y las elimina con **Ripple Delete**. Los clips quedan juntos en la misma timeline. Todo el análisis se hace en tu computadora.

Para cuidar el comienzo y el final de las palabras, conserva **100 ms antes de la voz y 50 ms después**.

## Instalación en Windows

1. Instalá Python con el lanzador de Windows y ejecutá `py -m pip install torch silero-vad` en PowerShell.
2. Agregá FFmpeg al `Path`. También podés indicar la ruta completa a `ffmpeg.exe` con la variable de entorno `SILERO_FFMPEG`.
3. Desde la carpeta [outputs](outputs/), copiá los tres archivos `.lua`, `detectar_silencios.py` y `ResolveMenuSession.exe` a la siguiente carpeta. Creala si hace falta.

   ```text
   %APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\Silero
   ```

## Uso

1. En la timeline, marcá con **In** y **Out** el tramo que querés limpiar.
2. Abrí **Workspace → Scripts** y elegí **Silero - Cortar silencios**.
3. Seguí el progreso en la ventana de estado. Al terminar, vas a ver cuántos silencios eliminó y cuánto tiempo recortó.

El script usa los menús de Resolve en inglés. Dejá la ventana principal de Resolve en primer plano mientras aplica los cortes. Si algo falla, podés ver el detalle en **Workspace → Console**.
