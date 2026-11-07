// Peek: every path in Claude's replies, on Windows, Linux or macOS, with or without backticks, becomes
// a link to preview and show in the file manager, and each reply ends with its references: every path
// it named, code blocks and tables included, with its kind. Based on midudev's Quick Peek (MIT, see
// LICENSE); ClaudeMaxxing adds the Windows forms of a path, the references and the Windows window.
import type { Elements, EngineInterface, EventOf, FsStat, Register, RenderElement } from 'claude-code'

import { excerptOf, languageOf } from './code'
import type { Excerpt } from './code'
import { blocks, inline, items, markerOf, widthOf, wrap } from './markdown'
import type { Item, Row, Run } from './markdown'
import { lineOf, longest, pathOfSpan, pathsIn, resolve } from './paths'
import { MACOS } from './window'

type Engine = EngineInterface
type Ui = Elements['terminal']
type Message = Extract<EventOf['ui.render'], { component: 'AssistantMessage', surface: 'terminal' }>
type Platform = 'macos' | 'linux' | 'windows' | 'other'
/** Which paths the references under a reply list: all, those not already a link in it, or none. */
type References = 'all' | 'unlinked' | 'off'

/**
 * A path a reply names that leads somewhere: where it lands, what is there, and the line it names;
 * where a card shows it, the lines of code or text the card shows.
 */
type Target = { path: string; stat: FsStat; line?: number; code?: Excerpt }
/** An item of a list the mod draws: its marker, its runs, the items under it, blank lines before it. */
type DrawnItem = { marker: string; runs: Run[]; children: DrawnItem[]; gap: number; dim?: boolean }
/** A part of a reply: drawn by the engine's Markdown, or by the mod, its paths links. */
type Part =
  | { kind: 'markdown'; text: string; gap: number }
  | { kind: 'paragraph'; runs: Run[]; gap: number }
  | { kind: 'list'; items: DrawnItem[]; gap: number }
/** A line of the references: the path as the reply wrote it, the target it links to. */
type Reference = { label: string; link: number }
/** How the mod draws a reply: its parts, its references, and the paths their runs link to (`Run.link` indexes them). */
type Plan = { parts: Part[]; references: Reference[]; targets: Target[] }

// The bullet the engine draws before a reply, by system, and the columns it takes.
const BULLET = { macos: '⏺', other: '●' }
const BULLET_COLUMNS = 2
// How long a path is taken to be there, or not there, before it is looked at again; and a plan.
const FOUND_MS = 30_000
const MISSING_MS = 3_000
const PLAN_MS = 10_000
const PLANS = 300
// The longest side of the preview's picture, in points, and the most seconds the window stays.
const WINDOW_SIZE = 360
const WINDOW_LIFE = 60
// The largest file of code or text read for its lines; the lines the window shows, the lines and
// columns a card shows.
const CODE_BYTES = 1024 * 1024
const WINDOW_LINES = 20
const CARD_LINES = 8
const CARD_COLUMNS = 100
// The words the mod shows: ClaudeMaxxing speaks Spanish.
const WORDS = {
  references: 'Referencias',
  folder: 'carpeta',
  ago: 'hace',
  card: 'clic: mostrar en la carpeta · alt o clic derecho: abrir',
  finder: 'clic: mostrar en Finder · ⌥ clic: abrir',
  window: 'clic: mostrar en la carpeta  ·  alt o clic derecho: abrir',
  page: 'página',
  pages: 'páginas',
  item: 'elemento',
  items: 'elementos'
}
// The kind a references line shows before the path, by extension; a folder, code and text otherwise.
const KINDS: [string, RegExp][] = [
  ['imagen', /\.(png|jpe?g|gif|webp|bmp|svg|ico|tiff?|heic|avif|psd|raw)$/i],
  ['video', /\.(mp4|mov|mkv|webm|avi|wmv|m4v|flv|mpe?g|3gp)$/i],
  ['audio', /\.(mp3|wav|ogg|oga|flac|m4a|aac|opus|wma|mid|midi|aiff?)$/i],
  ['pdf', /\.pdf$/i],
  ['documento', /\.(docx?|xlsx?|pptx?|odt|ods|odp|rtf|epub)$/i],
  ['archivo', /\.(zip|rar|7z|tar|gz|tgz|bz2|xz)$/i]
]
const KIND_COLUMNS = 10

const stats = new Map<string, { stat: FsStat | null; at: number }>()
const plans = new Map<string, { plan: Plan | null; at: number }>()
const excerpts = new Map<string, Excerpt | null>()
// On Windows the paths of code or text a card shows (its coloured lines), with no window.
const carded = new Set<string>()
let platform: Promise<Platform> | undefined
let wsl: Promise<boolean> | undefined
// Whether a hover opens a window by the pointer (macOS, Windows); else each path carries a card the
// terminal reveals over it. The path the pointer is on, and the part it is on; the window open.
let windowing = false
let references: References = 'all'
let hovered: { path: string; line: number | undefined; target: string } | undefined
let window: { path: string; line: number | undefined; isOpen: boolean } | undefined

/** The system the session runs on, asked once. */
function platformOf ($: Engine) {
  platform ??= (async (): Promise<Platform> => {
    if ((await $.env.get('OS')) === 'Windows_NT') return 'windows'
    const name = (await $.process.run(['uname', '-s']).catch(() => undefined))?.stdout.trim()
    return name === 'Darwin' ? 'macos' : name === 'Linux' ? 'linux' : 'other'
  })()
  return platform
}

/** Whether the session runs under WSL: Linux, on a Windows desktop, whose file manager shows the path. */
function wslOf ($: Engine) {
  wsl ??= (async () => (await platformOf($)) === 'linux' && (await $.env.get('WSL_DISTRO_NAME')) !== undefined)()
  return wsl
}

/** A PowerShell script of this plugin's `windows` folder, run with no profile and no script policy in the way. */
const powershell = ($: Engine, script: string) => ['powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-File', `${$.plugin.root}/windows/${script}`]

/** What is at `path`, looked at again once its answer is old; null where nothing is. */
async function statOf ($: Engine, path: string) {
  const now = Date.now()
  const known = stats.get(path)
  if (known && now - known.at < (known.stat ? FOUND_MS : MISSING_MS)) return known.stat
  const stat = await $.fs.stat(path).catch(() => null)
  stats.set(path, { stat: stat && stat.kind !== 'other' ? stat : null, at: now })
  return stats.get(path)!.stat
}

/**
 * The `rows` lines a preview shows of the file at `path`, around `line` when it names one: null
 * for a file that is no code nor text, too large, or holds none. Read again once the file changes.
 */
async function excerptAt ($: Engine, path: string, stat: FsStat, line: number | undefined, rows: number) {
  const language = languageOf(path)
  if (!language || stat.kind !== 'file' || stat.size > CODE_BYTES) return null
  const key = `${path}\n${stat.size}\n${stat.mtimeMs}\n${line ?? 0}\n${rows}`
  const known = excerpts.get(key)
  if (known !== undefined) return known
  const text = await $.fs.read(path).catch(() => undefined)
  const excerpt = typeof text === 'string' ? excerptOf(text, language, line, rows) ?? null : null
  if (excerpts.size >= PLANS) excerpts.delete(excerpts.keys().next().value!)
  excerpts.set(key, excerpt)
  return excerpt
}

/** A run cut where it names a path, each path a run of its own carrying the target it links to. */
function link (run: Run, found: { start: number; end: number; link: number }[]): Run[] {
  const out: Run[] = []
  let at = 0
  for (const { start, end, link } of found) {
    if (start > at) out.push({ text: run.text.slice(at, start), style: run.style })
    out.push({ text: run.text.slice(start, end), style: run.style, link })
    at = end
  }
  if (at < run.text.length) out.push({ text: run.text.slice(at), style: run.style })
  return out
}

/** The kind a references line names: by extension, else a folder, code, text or a file. */
function kindOf (target: Target) {
  if (target.stat.kind === 'dir') return WORDS.folder
  const kind = KINDS.find(([, pattern]) => pattern.test(target.path))
  if (kind) return kind[0]
  const language = languageOf(target.path)
  if (!language) return 'archivo'
  return /^(Plain text|Log|CSV|TSV|Markdown)$/.test(language.name) ? 'texto' : 'código'
}

/**
 * How the mod draws `text`: its paragraphs and lists that name a path that leads somewhere drawn
 * by the mod, each such path a link; every other block, and the runs between, by the engine's
 * own Markdown; under it, the references: every path the text names that leads somewhere, in a
 * code block, a table or a heading too. Null when no path in it leads anywhere: the engine draws
 * the reply.
 */
async function planOf ($: Engine, text: string): Promise<Plan | null> {
  // A relative path leads from the folder the shell is in, or else from the project's: Claude
  // names paths from the project even after a `cd` took the shell into one of its folders.
  const cwd = await $.session.cwd()
  const root = await $.session.root().catch(() => cwd)
  const key = `${cwd}\n${root}\n${references}\n${text}`
  const known = plans.get(key)
  if (known && Date.now() - known.at < PLAN_MS) return known.plan

  const home = (await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE'))
  const system = await platformOf($)
  type Named = { start: number; end: number; paths: string[]; line?: number }
  type Pending = { run: Run; found: Named[] }
  const candidates = (target: string) => [...new Set([cwd, root].flatMap(base => resolve(target, base, home) ?? []))]
  const named = (source: string, start: number, end: number, target: string): Named[] => {
    const paths = candidates(target)
    const line = lineOf(source.slice(start, end))
    return paths.length > 0 ? [{ start, end, paths, ...(line !== undefined && { line }) }] : []
  }
  const pending: Pending[] = []
  const runsOf = (source: string) =>
    inline(source).map(run => {
      const found: Named[] = []
      if (run.style.href === undefined) {
        // An inline code span may be one path with spaces; candidates may overlap, the longest that leads somewhere wins.
        const span = run.style.code ? pathOfSpan(run.text) : undefined
        const spans = span ? [{ start: 0, end: run.text.length, target: span }] : []
        for (const { start, end, target } of [...spans, ...pathsIn(run.text)]) found.push(...named(run.text, start, end, target))
      }
      const entry = { run, found }
      pending.push(entry)
      return entry
    })

  type Drafted = { kind: 'markdown'; text: string; gap: number } | { kind: 'paragraph'; runs: Pending[]; gap: number } | { kind: 'list'; items: DraftItem[]; gap: number }
  type DraftItem = { marker: string; runs: Pending[]; children: DraftItem[]; gap: number }
  const draftItems = (list: Item[], depth: number): DraftItem[] =>
    list.map(item => ({ marker: markerOf(item, depth), runs: runsOf(item.text), children: draftItems(item.children, depth + 1), gap: item.gap }))
  const cut = blocks(text)
  const drafted: Drafted[] = cut.map(block =>
    block.kind === 'paragraph' ? { kind: 'paragraph', runs: runsOf(block.text), gap: block.gap }
      : block.kind === 'list' ? { kind: 'list', items: draftItems(items(block.text), 0), gap: block.gap }
        : { kind: 'markdown', text: block.text, gap: block.gap })
  // The references read the reply as written, so a path in a code block, a table or a heading, or
  // one whose `\_` Markdown would read as an escape, is there too.
  const listed = references === 'off' ? [] : pathsIn(text).flatMap(({ start, end, target }) => named(text, start, end, target))

  const paths = [...new Set([...pending.flatMap(entry => entry.found), ...listed].flatMap(found => found.paths))]
  const found = new Map((await Promise.all(paths.map(async path => [path, await statOf($, path)] as const))).filter(([, stat]) => stat !== null) as [string, FsStat][])
  const leading = (list: Named[]) =>
    longest(list.flatMap(({ paths: options, ...entry }) => {
      const path = options.find(option => found.has(option))
      return path === undefined ? [] : [{ ...entry, path }]
    }))
  const targets: Target[] = []
  const finish = (runs: Pending[]) =>
    runs.flatMap(({ run, found: inRun }) =>
      link(run, leading(inRun).map(({ path, ...entry }) => ({ ...entry, link: targets.push({ path, stat: found.get(path)!, ...(entry.line !== undefined && { line: entry.line }) }) - 1 }))))
  const linked = (runs: Run[]) => runs.some(run => run.link !== undefined)
  const finishItems = (list: DraftItem[]): DrawnItem[] => list.map(item => ({ marker: item.marker, runs: finish(item.runs), children: finishItems(item.children), gap: item.gap }))
  const anyLinked = (list: DrawnItem[]): boolean => list.some(item => linked(item.runs) || anyLinked(item.children))

  const parts: Part[] = []
  drafted.forEach((draft, i) => {
    let part: Part = { kind: 'markdown', text: cut[i]!.text, gap: draft.gap }
    if (draft.kind === 'paragraph') {
      const runs = finish(draft.runs)
      if (linked(runs)) part = { kind: 'paragraph', runs, gap: draft.gap }
    } else if (draft.kind === 'list') {
      const list = finishItems(draft.items)
      if (anyLinked(list)) part = { kind: 'list', items: list, gap: draft.gap }
    }
    // The blocks the engine draws next to each other are one Markdown, as written between them.
    const last = parts.at(-1)
    if (part.kind === 'markdown' && last?.kind === 'markdown') last.text += '\n'.repeat(part.gap + 1) + part.text
    else parts.push(part)
  })

  // Each path once, in the order the reply names it.
  const linkedPaths = new Set(targets.map(target => target.path))
  const seen = new Set<string>()
  const listedLines: Reference[] = []
  for (const { path, start, end, line } of leading(listed)) {
    if (seen.has(path) || (references === 'unlinked' && linkedPaths.has(path))) continue
    seen.add(path)
    listedLines.push({ label: text.slice(start, end), link: targets.push({ path, stat: found.get(path)!, ...(line !== undefined && { line }) }) - 1 })
  }

  // A card shows a file of code or text, its lines read now: everywhere with no window, and on
  // Windows, whose window shows pictures, always.
  if (!windowing || system === 'windows') {
    await Promise.all(targets.map(async target => {
      const code = await excerptAt($, target.path, target.stat, target.line, CARD_LINES)
      if (code) {
        target.code = code
        carded.add(target.path)
      }
    }))
  }
  const plan = targets.length > 0 ? { parts, references: listedLines, targets } : null
  if (plans.size >= PLANS) plans.delete(plans.keys().next().value!)
  plans.set(key, { plan, at: Date.now() })
  return plan
}

const sizeOf = (bytes: number) =>
  bytes < 1024 ? `${bytes} B` : bytes < 1024 * 1024 ? `${Math.round(bytes / 1024)} KB` : bytes < 1024 ** 3 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${(bytes / 1024 ** 3).toFixed(1)} GB`

const ago = (ms: number) => {
  const seconds = Math.max(0, Math.round((Date.now() - ms) / 1000))
  const [value, unit] = seconds < 60 ? [seconds, 's'] : seconds < 3600 ? [Math.round(seconds / 60), 'min'] : seconds < 86400 ? [Math.round(seconds / 3600), 'h'] : [Math.round(seconds / 86400), 'd']
  return `${WORDS.ago} ${value} ${unit}`
}

/** The line the terminal shows over a path where no window can: what it is, and what a click does. */
function cardOf (target: Target) {
  const name = target.path.slice(Math.max(target.path.lastIndexOf('/'), target.path.lastIndexOf('\\')) + 1) || target.path
  const what = target.stat.kind === 'dir' ? WORDS.folder : sizeOf(target.stat.size)
  return ` ${name} · ${what} · ${ago(target.stat.mtimeMs)} · ${WORDS.card} `
}

/**
 * The rows of a wrapped paragraph, `width` columns: text in its style, each part of a path a
 * `Client` that takes the pointer.
 */
function drawRows (ui: Ui, rows: Row[], width: number, targets: Target[], parts: Map<number, number>) {
  const { Box, Client, Code, Link, Text } = ui
  return rows.map(row => {
    let column = 0
    return (
      <Box flexDirection="row">
        {row.length === 0 && <Text> </Text>}
        {row.map(run => {
          const at = column
          column += widthOf(run.text)
          const { bold, italic, strike, code, href } = run.style
          if (run.link === undefined) {
            const style = { bold, italic, strikethrough: strike, ...(code && { color: 'permission' }) }
            return href === undefined ? <Text {...style}>{run.text}</Text> : <Text {...style}><Link href={href}>{run.text}</Link></Text>
          }
          const part = parts.get(run.link) ?? 0
          parts.set(run.link, part + 1)
          const target = targets[run.link]!
          const props = { label: run.text, path: target.path, ...(target.line !== undefined && { line: target.line }), ...(bold && { bold }), ...(italic && { italic }), ...(strike && { strike }) }
          const client = <Client key={`path:${run.link}:${part}`} module="./link.tsx" props={props} />
          if (windowing && !target.code) return client
          // A card over the path, which the terminal reveals while the pointer is on it, moved left
          // as far as it needs to end inside the reply. A file of code or text shows its lines under
          // the card's line, coloured by the engine, on the background of the theme.
          const card = cardOf(target)
          const excerpt = target.code
          const cardWidth = Math.min(excerpt ? Math.max(widthOf(card), CARD_COLUMNS) : widthOf(card), width)
          const left = Math.max(-at, Math.min(0, width - at - cardWidth))
          return (
            <Box key={`card:${run.link}:${part}`}>
              {client}
              <Box position="absolute" top={-1 - (excerpt?.lines.length ?? 0)} left={left} width={cardWidth} flexDirection="column" display="none" hover={{ display: 'flex' }} {...(excerpt && { backgroundColor: 'inverseText' })}>
                <Text inverse wrap="truncate-end">{card}</Text>
                {excerpt && <Code source={excerpt.source} path={target.path} startLine={excerpt.first} wrap="truncate-end" />}
              </Box>
            </Box>
          )
        })}
      </Box>
    )
  })
}

function drawList (ui: Ui, list: DrawnItem[], width: number, targets: Target[], parts: Map<number, number>): RenderElement[] {
  const { Box, Text } = ui
  return list.map((item, i) => {
    const indent = widthOf(item.marker) + 1
    return (
      <Box flexDirection="row" marginTop={i > 0 && item.gap > 0 ? 1 : 0}>
        <Box minWidth={indent} flexShrink={0}><Text dimColor={item.dim}>{item.marker}</Text></Box>
        <Box flexDirection="column" width={width - indent}>
          {drawRows(ui, wrap(item.runs, width - indent), width - indent, targets, parts)}
          {drawList(ui, item.children, width - indent, targets, parts)}
        </Box>
      </Box>
    )
  })
}

/** The references under a reply: a dim title, then each path behind its kind. */
function drawReferences (ui: Ui, plan: Plan, width: number, parts: Map<number, number>) {
  const { Box, Text } = ui
  const list = plan.references.map(reference => ({
    marker: kindOf(plan.targets[reference.link]!).padEnd(KIND_COLUMNS),
    runs: [{ text: reference.label, style: {}, link: reference.link }],
    children: [],
    gap: 0,
    dim: true
  }))
  return (
    <Box flexDirection="column" marginTop={1}>
      <Text dimColor>{`${WORDS.references} · ${list.length}`}</Text>
      {drawList(ui, list, width, plan.targets, parts)}
    </Box>
  )
}

/** The reply as the engine lays it out, its bullet and its blocks, with the paths in it links, and its references. */
function draw (ui: Ui, e: Message, plan: Plan, bullet: string) {
  const { Box, Markdown, Text } = ui
  const width = Math.max(10, (e.viewport?.columns ?? 80) - BULLET_COLUMNS)
  const parts = new Map<number, number>()
  return (
    <Box flexDirection="row">
      <Box minWidth={BULLET_COLUMNS} flexShrink={0}>{e.props.isFirstOfReply && <Text color="text">{bullet}</Text>}</Box>
      <Box flexDirection="column" width={width}>
        {plan.parts.map((part, i) => {
          const marginTop = i > 0 && part.gap > 0 ? 1 : 0
          if (part.kind === 'markdown') return <Box marginTop={marginTop}><Markdown text={part.text} /></Box>
          const drawn = part.kind === 'paragraph' ? drawRows(ui, wrap(part.runs, width), width, plan.targets, parts) : drawList(ui, part.items, width, plan.targets, parts)
          return <Box flexDirection="column" marginTop={marginTop}>{drawn}</Box>
        })}
        {plan.references.length > 0 && drawReferences(ui, plan, width, parts)}
      </Box>
    </Box>
  )
}

/** The tree `next` drew with the engine's node in it swapped for `mine`: what other plugins drew around it stays. */
function swap (drawn: RenderElement, mine: RenderElement): RenderElement {
  let isSwapped = false
  const walk = (node: unknown): unknown => {
    if (isSwapped || node === null || typeof node !== 'object') return node
    if (Array.isArray(node)) return node.map(walk)
    const element = node as { type?: unknown; children?: unknown[] }
    if (element.type === 'engine') {
      isSwapped = true
      return mine
    }
    return Array.isArray(element.children) ? { ...element, children: element.children.map(walk) } : node
  }
  const out = walk(drawn) as RenderElement
  return isSwapped ? out : mine
}

/** Shows `path` in the system's file manager, selected; with `isOpening`, opens it instead. */
async function reveal ($: Engine, path: string, isOpening: boolean) {
  const run = (argv: string[]) => $.process.run(argv).catch(() => undefined)
  if (await wslOf($)) {
    const windows = (await run(['wslpath', '-w', path]))?.stdout.trim()
    if (windows) await run(isOpening ? ['explorer.exe', windows] : ['explorer.exe', `/select,${windows}`])
    return
  }
  const system = await platformOf($)
  if (system === 'macos') {
    await run(isOpening ? ['open', path] : ['open', '-R', path])
    return
  }
  if (system === 'windows') {
    // Explorer reads /select,"<path>" with the quotes inside the argument, which no argv can say: a script does.
    await $.process.run(powershell($, 'reveal.ps1'), { env: { PEEK_FILE: path, PEEK_OPEN: isOpening ? '1' : '0' } }).catch(() => undefined)
    return
  }
  if (isOpening) {
    await run(['xdg-open', path])
    return
  }
  // The desktop's file manager selects it where it answers FileManager1; else its folder opens.
  const uri = `file://${path.split('/').map(encodeURIComponent).join('/')}`
  const shown = await run(['dbus-send', '--session', '--print-reply', '--dest=org.freedesktop.FileManager1', '/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1.ShowItems', `array:string:${uri}`, 'string:'])
  if (shown?.exitCode !== 0) await run(['xdg-open', path.slice(0, path.lastIndexOf('/')) || '/'])
}

/**
 * Shows `path` in a window by the pointer till `closeWindow`: on macOS a file of code or text its
 * lines around `line`, anything else its Quick Look thumbnail; on Windows a picture (a PDF's first
 * page, the Explorer's thumbnail, else its icon) with its kind, size, length or pages. The program
 * says `.` ten times a second, so the loop wakes to see it was closed, and leaving the loop ends the
 * program. One that ends without having shown a window, on a path that is there, says the system
 * shows none: from then on the terminal shows the cards.
 */
async function openWindow ($: Engine, path: string, line: number | undefined) {
  closeWindow()
  const opening = { path, line, isOpen: true }
  window = opening
  const system = await platformOf($)
  let argv: string[]
  let env: Record<string, string>
  if (system === 'windows') {
    argv = powershell($, 'preview.ps1')
    env = { PEEK_FILE: path, PEEK_SIZE: '320', PEEK_LIFE: String(WINDOW_LIFE), PEEK_HINT: WORDS.window, PEEK_AGO: WORDS.ago, PEEK_PAGE: WORDS.page, PEEK_PAGES: WORDS.pages, PEEK_ITEM: WORDS.item, PEEK_ITEMS: WORDS.items }
  } else {
    argv = ['osascript', '-l', 'JavaScript', '-e', MACOS]
    env = { QUICK_PEEK_FILE: path, QUICK_PEEK_SIZE: String(WINDOW_SIZE), QUICK_PEEK_LIFE: String(WINDOW_LIFE), QUICK_PEEK_HINT: WORDS.finder }
    const stat = await statOf($, path)
    const code = stat && (await excerptAt($, path, stat, line, WINDOW_LINES))
    if (code) {
      const { source, ...shown } = code
      env.QUICK_PEEK_CODE = JSON.stringify(shown)
    }
  }
  if (!opening.isOpen) return
  let isShown = false
  let said = ''
  try {
    for await (const { text } of $.process.spawn({ argv, env })) {
      if (said.length < 2000) said += text
      if (/^shown\r?$/m.test(text)) isShown = true
      if (!opening.isOpen) break
    }
  } catch (error) {
    said += error instanceof Error ? error.message : String(error)
  }
  if (window === opening) window = undefined
  if (isShown || !opening.isOpen || /^error: not there/m.test(said)) return
  $.ui.log(`peek: no window (${said.replace(/\.\r?\n/g, '').trim().slice(0, 300) || 'the program could not start'}); the terminal shows the cards`, { to: 'debug' })
  windowing = false
  plans.clear()
}

function closeWindow () {
  if (window) window.isOpen = false
  window = undefined
}

/**
 * The pointer came onto a part of `path` naming `line` (`target`, the part's address): its preview
 * opens, unless it is open or a card shows it.
 */
function over ($: Engine, path: string, line: number | undefined, target: string) {
  const isOpen = hovered?.path === path && hovered.line === line && window?.path === path && window.line === line && window.isOpen
  hovered = { path, line, target }
  if (isOpen || !windowing || carded.has(path)) return
  void openWindow($, path, line)
}

/** The pointer left a part: the preview closes, unless the pointer is already on another part of it. */
function off (target: string) {
  if (hovered?.target !== target) return
  hovered = undefined
  closeWindow()
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    const [system, sshConnection, sshTty] = await Promise.all([platformOf($), $.env.get('SSH_CONNECTION'), $.env.get('SSH_TTY')])
    // A window opens on the desktop the session runs on: not over SSH, where that is another machine's.
    windowing = options.window !== false && e.isInteractive && (system === 'macos' || system === 'windows') && sshConnection === undefined && sshTty === undefined
    references = options.references === 'unlinked' || options.references === 'off' ? options.references : 'all'
    plans.clear()
    stats.clear()
    excerpts.clear()
    carded.clear()
    return result
  })

  on('session.end', ($, e, next) => {
    hovered = undefined
    closeWindow()
    return next(e)
  })

  // Typing or sending a prompt closes a preview: what is under the pointer may move.
  on('prompt.edit', ($, e, next) => {
    if (hovered) {
      hovered = undefined
      closeWindow()
    }
    return next(e)
  })

  on('prompt.submit', ($, e, next) => {
    hovered = undefined
    closeWindow()
    return next(e)
  }).catch(($, e, next) => next(e))

  // A part of a path says when the pointer comes onto it and leaves it: its preview opens and
  // closes. Clicked, the path shows in the file manager; alt-clicked or right-clicked, it opens.
  on('ui.message', async ($, e, next) => {
    const result = await next(e)
    if (!e.element.startsWith('path:')) return result
    const data = e.data as { path?: unknown; line?: unknown; isOver?: unknown; isClicked?: unknown; isAlt?: unknown } | null
    if (typeof data?.path !== 'string') return result
    const target = `${e.requestId}/${e.element}`
    if (data.isClicked === true) {
      hovered = undefined
      closeWindow()
      void reveal($, data.path, data.isAlt === true)
      return result
    }
    if (data.isOver === true) over($, data.path, typeof data.line === 'number' ? data.line : undefined, target)
    else off(target)
    return result
  })

  // A reply that names a path that leads somewhere: the mod draws it, its bullet, its blocks the
  // engine's Markdown draws, the paragraphs and lists that name paths, the paths links, and its
  // references. Off fullscreen the terminal reports no pointer: the engine draws it as it is.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.viewport?.isFullscreen !== true || e.props.isSummary) return next(e)
    const plan = await planOf($, e.props.text).catch(() => null)
    if (!plan) return next(e)
    const drawn = await next(e)
    const bullet = (await platformOf($)) === 'macos' ? BULLET.macos : BULLET.other
    return swap(drawn, draw($.ui.resolve(e), e, plan, bullet))
  })
}
