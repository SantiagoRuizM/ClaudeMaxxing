// Finding the paths a text names, in every form a reply writes them on Windows, Linux or macOS:
// absolute (`/home/…`, `C:\…`, `C:/…`, `\\server\share\…`, Git Bash's `/c/…`, `file:///…`), from
// home (`~/…`, `~\…`), relative (`./x`, `src/x.ts`, `src\x.ts`, `README.md`), each with an optional
// `:line` or `:line:column` after it, with or without backticks. An absolute path may hold spaces
// (`C:\Mi unidad (x)\a.png`): it is offered ending at each space it could end at, and candidates may
// overlap. Every candidate is only a candidate: the hooks module keeps, of those that overlap, the
// longest that leads to a file or folder.

/** A path a text names: where it starts and ends in the text, and the path itself, `:line` cut. */
export type Found = { start: number; end: number; target: string }

const TRAILING = /[.,;:!?\]}>'"»”’]$/
const LINE = /:\d+(?::\d+)?$/
// An address other than a file's: never a path, nor the paths inside it.
const URL = /\b(?!file:)[a-z][a-z0-9+.-]*:\/\/[^\s<>()]+/gi
const FILE_URL = /\bfile:\/\/(?:localhost)?(\/[^\s<>"'`]+)/gi
const BEFORE = String.raw`(?<![\w/.~:\\@-])`
const SUFFIX = String.raw`(?::\d+(?::\d+)?)?`
// Paths with no space, in every form.
const PLAIN = new RegExp(
  [
    String.raw`(?:~|\.{1,2})?[\\/][^\s\`'"<>()[\]{}|*?]+`,
    String.raw`[A-Za-z]:[\\/][^\s\`'"<>()[\]{}|*?]*`,
    String.raw`\\\\[^\s\\\`'"<>|*?]+\\[^\s\`'"<>()[\]{}|*?]+`,
    String.raw`[\w@+-][\w@.+-]*(?:[\\/][\w@.+-]+)+[\\/]?`,
    String.raw`[\w@+-][\w@.+-]*\.[A-Za-z][A-Za-z0-9]{0,9}`
  ].map(source => `${BEFORE}(?:${source})${SUFFIX}`).join('|'),
  'g'
)
// An absolute path that may hold spaces: up to the end of the line, a character no path holds, or
// where another path starts.
const NEXT = String.raw`\s+(?:[A-Za-z]:[\\/]|\\\\|~[\\/]|\.{0,2}\/)`
const SPACED = new RegExp(String.raw`${BEFORE}(?:[A-Za-z]:[\\/]|\\\\[^\s\\]|~[\\/]|\/(?=[\w.~]))(?:(?!${NEXT})[^\n\t\`"<>|*?])*`, 'g')
// The most places one spaced path is offered ending at: each costs a look at the disk.
const ENDS = 24
// A whole inline code span that is a path: it may hold spaces when it starts as a path does.
const SPAN = /^(?:(?:~|\.{1,2})?[\\/]|[A-Za-z]:[\\/]|\\\\|file:\/\/)[^\n`]*[^\s`]$/

/** `text` without the punctuation a sentence puts after a path; a `)` only where it closes nothing in it. */
function trimEnd (text: string) {
  let out = text.replace(/\s+$/, '')
  for (;;) {
    if (TRAILING.test(out)) out = out.slice(0, -1)
    else if (out.endsWith(')') && out.split('(').length < out.split(')').length) out = out.slice(0, -1)
    else return out
  }
}

/** The path a candidate names: `:line` cut, a `file://` address turned into its path. */
function clean (text: string) {
  let target = text.replace(LINE, '')
  const url = /^file:\/\/(?:localhost)?(\/.*)$/i.exec(target)
  if (url) {
    try {
      target = decodeURIComponent(url[1]!)
    } catch {
      target = url[1]!
    }
    if (/^\/[A-Za-z]:\//.test(target)) target = target.slice(1)
  }
  return /[\w~]/.test(target) && target !== '~' ? target : undefined
}

/** The line a path's text names after it (`src/x.ts:12`, `src/x.ts:12:5`), if it names one. */
export function lineOf (text: string) {
  const match = /:(\d+)(?::\d+)?$/.exec(text)
  return match ? Number(match[1]) : undefined
}

/** Every path `text` may name, overlapping candidates included, in the order they start. */
export function pathsIn (text: string): Found[] {
  const urls = [...text.matchAll(URL)].map(match => [match.index, match.index + match[0].length] as const)
  const inUrl = (start: number) => urls.some(([from, to]) => start >= from && start < to)
  const found = new Map<string, Found>()
  const add = (start: number, raw: string) => {
    const trimmed = trimEnd(raw)
    const target = trimmed && clean(trimmed)
    if (target && !inUrl(start)) found.set(`${start}:${trimmed.length}`, { start, end: start + trimmed.length, target })
  }
  for (const match of text.matchAll(FILE_URL)) add(match.index, match[0])
  for (const match of text.matchAll(PLAIN)) add(match.index, match[0])
  for (const match of text.matchAll(SPACED)) {
    const spaced = match[0]
    if (!/\s/.test(spaced.trim())) continue
    const ends = [...spaced.matchAll(/\s+/g)].map(space => space.index).concat(spaced.length)
    for (const end of ends.slice(-ENDS)) add(match.index, spaced.slice(0, end))
  }
  return [...found.values()].sort((a, b) => a.start - b.start || b.end - a.end)
}

/** The path an inline code span holds whole (`` `~/a b/c.mp4` `` or `` `src/x.ts:12` ``), if it holds one. */
export function pathOfSpan (code: string): string | undefined {
  const text = code.trim()
  if (SPAN.test(text)) return clean(text)
  const found = pathsIn(text)
  return found.length === 1 && found[0]!.start === 0 && found[0]!.end === text.length ? found[0]!.target : undefined
}

/**
 * Of candidates that lead somewhere, those to draw: where two overlap the longer wins, and they come
 * back in the order they start.
 */
export function longest<T extends { start: number; end: number }> (found: T[]): T[] {
  const kept: T[] = []
  for (const one of [...found].sort((a, b) => b.end - b.start - (a.end - a.start) || a.start - b.start)) {
    if (kept.every(other => one.end <= other.start || one.start >= other.end)) kept.push(one)
  }
  return kept.sort((a, b) => a.start - b.start)
}

const WINDOWS_ROOT = /^(?:[A-Za-z]:[\\/]|\\\\)/

/** `.` and `..` folded in `parts`, a `..` above the root dropped. */
function fold (parts: string[]) {
  const out: string[] = []
  for (const part of parts) {
    if (part === '' || part === '.') continue
    if (part === '..') out.pop()
    else out.push(part)
  }
  return out
}

/**
 * Where `target` lands: home for `~`, the working folder for a relative path; `.` and `..` folded.
 * On Windows (a working folder such as `C:\…`) the answer is a Windows path: `/` read as `\`, Git
 * Bash's `/c/…` and WSL's `/mnt/c/…` as `C:\…`, a path from the root on the working folder's drive.
 * Elsewhere a POSIX path, a Windows one (`C:\…`) read as WSL mounts it (`/mnt/c/…`).
 */
export function resolve (target: string, cwd: string, home: string | undefined) {
  if (WINDOWS_ROOT.test(cwd)) {
    let path = target.replace(/\//g, '\\')
    const mounted = /^\\(?:mnt\\)?([A-Za-z])(?:\\|$)(.*)$/.exec(path)
    if (mounted && !/^\\\\/.test(path)) path = `${mounted[1]!.toUpperCase()}:\\${mounted[2]}`
    if (path === '~' || path.startsWith('~\\')) {
      if (!home) return undefined
      path = home.replace(/\//g, '\\') + path.slice(1)
    } else if (/^[A-Za-z]:(?!\\)/.test(path)) {
      return undefined
    } else if (/^\\(?!\\)/.test(path)) {
      path = cwd.slice(0, 2) + path
    } else if (!WINDOWS_ROOT.test(path)) {
      path = `${cwd.replace(/\//g, '\\')}\\${path}`
    }
    const unc = /^(\\\\[^\\]+\\[^\\]+)(.*)$/.exec(path)
    const [root, rest] = unc ? [unc[1]!, unc[2]!] : [path.slice(0, 2).toUpperCase(), path.slice(2)]
    return `${root}\\${fold(rest.split('\\')).join('\\')}`
  }
  let path = target
  const drive = /^([A-Za-z]):[\\/](.*)$/.exec(path)
  if (drive) path = `/mnt/${drive[1]!.toLowerCase()}/${drive[2]!.replace(/\\/g, '/')}`
  if (path === '~' || path.startsWith('~/')) {
    if (!home) return undefined
    path = home + path.slice(1)
  } else if (!path.startsWith('/')) {
    path = `${cwd}/${path}`
  }
  return `/${fold(path.split('/')).join('/')}`
}
