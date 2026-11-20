# Peek (ClaudeMaxxing)

Un mod de Claude Code: cada ruta que Claude escribe en una respuesta se vuelve un enlace, y cada respuesta termina con sus **Referencias**, todas las rutas que nombró (también las de bloques de código y tablas) con su tipo.

```text
● Aquí tienes las imágenes:
  C:\Users\user\Mi unidad (x@gmail.com)\Atlas\05. Modulo\png\056.png   ← ratón encima: vista previa · clic: Explorador

  Referencias · 3
  imagen    C:\Users\user\Mi unidad (x@gmail.com)\Atlas\05. Modulo\png\056.png
  pdf       C:\Users\user\Mi unidad (x@gmail.com)\Atlas\0. Catalogo\build\Catalogo_v1.pdf
  carpeta   C:\Users\user\Mi unidad (x@gmail.com)\Atlas\05. Modulo
```

- **Qué rutas**: de Windows (`C:\…`, `C:/…`, `\\servidor\carpeta\…`), de Git Bash (`/c/…`), de WSL (`/mnt/c/…`), `file:///…`, de Linux y macOS (`/home/…`, `~/…`), relativas (`src/app.ts`, `src\app.ts`, `README.md`, desde la carpeta de la sesión), con `:línea`, con un tramo `[desde:hasta]` (`src/app.ts[12:20]`: líneas 12 a 20, contando desde 1) o sin nada. Con comillas invertidas o sin ellas: una ruta con espacios y paréntesis (`Mi unidad (x@gmail.com)`) se prueba terminando en cada espacio y queda la más larga que existe. Solo se enlazan las que llevan a un archivo o carpeta reales.
- **Ratón encima**: en Windows y macOS, una ventanita junto al puntero, sin quitar el foco: la miniatura (una imagen, el fotograma de un video, la primera página de un PDF, si no el icono), el nombre, el tipo, el tamaño, la duración (audio, video), las páginas (PDF), los píxeles o los elementos (carpeta). Un archivo de código o texto muestra sus primeras líneas con colores, en una tarjeta sobre la ruta; con un tramo, solo esas líneas (hasta 20).
- **Clic**: el Explorador (Finder, el gestor de archivos) con el archivo seleccionado. **Clic derecho, alt o ctrl + clic**: lo abre con su programa (el video se reproduce, el PDF se abre).
- Necesita la interfaz de pantalla completa de Claude Code (`"tui": "fullscreen"`) y los mods activados (`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`). El `install.ps1` de ClaudeMaxxing pone las dos variables en `~/.claude/settings.json` (`env`): esa y `CLAUDE_CODE_PLUGIN_DIRS`, que carga esta carpeta de la instalación en todas las sesiones.

Opciones en `/config` (`maxx-peek`): **Vista previa en ventana** (apagada, una tarjeta de una línea) y **Referencias** (`all`, `unlinked`, `off`).

## Cómo funciona

- `hooks/paths.ts`: encuentra las rutas de un texto (los candidatos pueden solaparse) y las resuelve como lo hace el sistema de la sesión. Pruebas: `node --test peek/test/paths.test.mjs`.
- `hooks/register.tsx`: un hook `ui.render` sobre `AssistantMessage` dibuja la respuesta con las rutas que existen como enlaces y añade las referencias, leídas del texto tal como se escribió. Los bloques de código, tablas y títulos los sigue dibujando Claude Code.
- `windows/preview.ps1`: la ventana de Windows. La miniatura sale de `IShellItemImageFactory` pidiendo solo la miniatura, así que funciona aunque el Explorador esté en "mostrar siempre iconos". Los PDF se dibujan con el lector de PDF de Windows (`Windows.Data.Pdf`). `PEEK_RENDER=<png>` la dibuja en un archivo para revisarla. `windows/reveal.ps1`: el clic.

Basado en [Quick Peek](https://github.com/midudev/better-claude/tree/main/plugins/quick-peek) de midudev (MIT, ver `LICENSE`). `code.ts`, `markdown.ts`, `link.tsx` y `window.ts` (la ventana de macOS) son suyos, con cambios mínimos.
