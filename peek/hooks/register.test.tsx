// Mod tests, run against the engine itself: `claude plugin test peek` (the path finder alone:
// `node --test peek/test/paths.test.mjs`). A Windows session, its files and programs mocked.
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

const DRIVE = 'C:\\Users\\ana\\Mi unidad (ana@gmail.com)\\Atlas'
const IMAGE = `${DRIVE}\\05. Modulo\\png\\056.png`
const PDF = `${DRIVE}\\0. Catalogo\\build\\Catalogo_v1.pdf`
const FOLDER = `${DRIVE}\\05. Modulo`
const VIDEO = 'C:\\Users\\ana\\Videos\\demo.mp4'
const SOURCE = 'C:\\Users\\ana\\proj\\src\\app.ts'
const CODE = ['export function start () {', '  return 1', '}', ''].join('\n')
const SCREEN = { columns: 120, rows: 40, isFullscreen: true }

/** A Windows session: the files that are there, the programs it runs and the window's program. */
function world (on: On) {
  const clock = mock.clock(on, { now: 0 })
  mock.env(on, { OS: 'Windows_NT', USERPROFILE: 'C:\\Users\\ana' })
  const there: Record<string, 'file' | 'dir'> = { [IMAGE]: 'file', [PDF]: 'file', [FOLDER]: 'dir', [VIDEO]: 'file', [SOURCE]: 'file' }
  const runs: { argv: string[]; env: Record<string, string> }[] = []
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: 'C:\\Users\\ana\\proj' }))
  on('session.root', () => ({ value: 'C:\\Users\\ana\\proj' }))
  on('process.run', ($, e) => {
    runs.push({ argv: [...e.argv], env: { ...e.init?.env } })
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.stat', ($, e) => {
    const kind = there[e.path]
    if (!kind) return { deny: `ENOENT: ${e.path}` }
    return { value: { kind, size: e.path === SOURCE ? CODE.length : 2048, mtimeMs: 0, isLink: false } }
  })
  on('fs.read', ($, e) => (e.path === SOURCE ? { value: CODE } : { deny: `ENOENT: ${e.path}` }))
  const windows: { argv: string[]; env: Record<string, string>; isEnded: boolean }[] = []
  on('process.spawn', async function * ($, e) {
    const opened = { argv: [...e.argv], env: { ...e.env }, isEnded: false }
    windows.push(opened)
    try {
      yield { stream: 'stdout' as const, text: 'shown\r\n' }
      for (;;) {
        await clock.sleep(100)
        yield { stream: 'stdout' as const, text: '.\r\n' }
      }
    } finally {
      opened.isEnded = true
    }
  })
  on('ui.render', ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
  return { clock, runs, windows }
}

const startSession = ($: Engine) => $.session.start({ cwd: 'C:\\Users\\ana\\proj', surface: 'terminal', isInteractive: true })
const reply = ($: Engine, text: string) =>
  $.ui.mount({ plugin: 'maxx-peek', surface: 'terminal', component: 'AssistantMessage', requestId: 'a-1', props: { text, isFirstOfReply: true }, viewport: SCREEN })

test('paths in a code block, with spaces and parentheses, are listed under the reply with their kind', async ($, on) => {
  world(on)
  await startSession($)
  const ui = await reply($, `Aquí van:\n\`\`\`\n${IMAGE}\n${PDF}\n${FOLDER}\nC:\\no\\existe.png\n\`\`\``)
  expect(await ui.find({ key: 'engine' })).toBeUndefined()
  // The code block stays the engine's Markdown.
  expect(await ui.find({ type: 'Markdown', text: /```/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Referencias · 3' })).toBeDefined()
  expect(await ui.find({ key: 'path:0:0' })).toMatchObject({ props: { props: { label: IMAGE, path: IMAGE } } })
  expect(await ui.find({ key: 'path:1:0' })).toMatchObject({ props: { props: { path: PDF } } })
  expect(await ui.find({ key: 'path:2:0' })).toMatchObject({ props: { props: { path: FOLDER } } })
  expect(await ui.find({ type: 'Text', text: /^imagen +$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^pdf +$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^carpeta +$/ })).toBeDefined()
})

test('a bare Windows path with spaces in a sentence, and a relative one with /, are links in the text', async ($, on) => {
  world(on)
  await startSession($)
  const ui = await reply($, `Mira ${IMAGE} y también src/app.ts:2 ahora.`)
  expect(await ui.find({ key: 'path:0:0' })).toMatchObject({ props: { props: { label: IMAGE, path: IMAGE } } })
  expect(await ui.find({ key: 'path:1:0' })).toMatchObject({ props: { props: { label: 'src/app.ts:2', path: SOURCE, line: 2 } } })
  expect(await ui.find({ type: 'Text', text: 'Mira ' })).toBeDefined()
})

test('the pointer on a picture opens the Windows window; on code, its card shows instead', async ($, on) => {
  const w = world(on)
  await startSession($)
  const ui = await reply($, `Listo: ${VIDEO} y \`src/app.ts\``)
  await ui.pointer({ type: 'enter', x: 0, y: 0, in: 'path:0:0' })
  await w.clock.advance(100)
  expect(w.windows).toHaveLength(1)
  expect(w.windows[0]!.argv.at(-1)).toMatch(/[\\/]windows[\\/]preview\.ps1$/)
  expect(w.windows[0]!.env).toMatchObject({ PEEK_FILE: VIDEO, PEEK_AGO: 'hace' })
  await ui.pointer({ type: 'leave', x: 3, y: 0, in: 'path:0:0' })
  await w.clock.advance(300)
  expect(w.windows[0]!.isEnded).toBe(true)
  expect(await ui.find({ key: 'card:1:0' })).toBeDefined()
  await ui.pointer({ type: 'enter', x: 0, y: 0, in: 'path:1:0' })
  await w.clock.advance(100)
  expect(w.windows).toHaveLength(1)
})

test('a click shows the path in Explorer; a right click opens it', async ($, on) => {
  const w = world(on)
  await startSession($)
  const ui = await reply($, `Listo: ${VIDEO}`)
  await ui.resize({ columns: VIDEO.length, rows: 1, in: 'path:0:0' })
  await ui.pointer({ type: 'down', x: 2, y: 0, button: 'left', in: 'path:0:0' })
  await ui.pointer({ type: 'up', x: 2, y: 0, button: 'left', in: 'path:0:0' })
  await w.clock.settle()
  const reveal = w.runs.filter(run => /reveal\.ps1$/.test(run.argv.at(-1) ?? ''))
  expect(reveal).toHaveLength(1)
  expect(reveal[0]!.env).toMatchObject({ PEEK_FILE: VIDEO, PEEK_OPEN: '0' })
  await ui.pointer({ type: 'down', x: 2, y: 0, button: 'right', in: 'path:0:0' })
  await ui.pointer({ type: 'up', x: 2, y: 0, button: 'right', in: 'path:0:0' })
  await w.clock.settle()
  const opened = w.runs.filter(run => /reveal\.ps1$/.test(run.argv.at(-1) ?? ''))
  expect(opened).toHaveLength(2)
  expect(opened[1]!.env).toMatchObject({ PEEK_FILE: VIDEO, PEEK_OPEN: '1' })
})

test('with references off, a reply whose only path is in a code block is the engine\'s', { options: { references: 'off' } }, async ($, on) => {
  world(on)
  await startSession($)
  const ui = await reply($, `\`\`\`\n${IMAGE}\n\`\`\``)
  expect(await ui.find({ key: 'engine' })).toBeDefined()
})
