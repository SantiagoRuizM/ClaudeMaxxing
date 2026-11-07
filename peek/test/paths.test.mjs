// node --test peek/test (Node 22.6+ reads the .ts module, its types stripped)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { lineOf, longest, pathOfSpan, pathsIn, resolve } from '../hooks/paths.ts'

const DRIVE = 'C:\\Users\\user\\Mi unidad (x@gmail.com)\\Atlas\\05. Modulo\\png\\056.png'

// What a hooks module would link: the candidates whose resolved path is in `exists`, longest first.
function linked (text, exists, cwd = 'C:\\Users\\user\\Atlas', home = 'C:\\Users\\user') {
  const found = pathsIn(text).filter(f => exists.includes(resolve(f.target, cwd, home)))
  return longest(found).map(f => text.slice(f.start, f.end))
}

test('a Windows path with spaces and parentheses, bare, in a sentence', () => {
  assert.deepEqual(linked(`Mira ${DRIVE} y dime.`, [DRIVE]), [DRIVE])
})

test('a Windows path alone on its line (as in a code block)', () => {
  assert.deepEqual(linked(`${DRIVE}\nC:\\Users\\user\\a b.txt`, [DRIVE, 'C:\\Users\\user\\a b.txt']), [DRIVE, 'C:\\Users\\user\\a b.txt'])
})

test('two paths on one line: the second is not swallowed by the first', () => {
  const a = 'C:\\Users\\user\\Mi unidad\\a.png'
  const b = 'C:\\Users\\user\\b.png'
  assert.deepEqual(linked(`${a} y ${b}`, [a, b]), [a, b])
})

test('a folder whose name ends in a parenthesis keeps it; a sentence parenthesis is dropped', () => {
  const dir = 'C:\\Users\\user\\Mi unidad (x@gmail.com)'
  assert.deepEqual(linked(`La carpeta ${dir} es la raiz`, [dir]), [dir])
  assert.deepEqual(linked('(ver C:\\x\\y.txt)', ['C:\\x\\y.txt']), ['C:\\x\\y.txt'])
})

test('forward slashes, Git Bash and file URLs land on the Windows path', () => {
  const cwd = 'C:\\Users\\user\\Atlas'
  assert.equal(resolve('C:/Users/user/a.png', cwd), 'C:\\Users\\user\\a.png')
  assert.equal(resolve('/c/Users/user/a.png', cwd), 'C:\\Users\\user\\a.png')
  assert.equal(resolve('/mnt/d/x/y.mp4', cwd), 'D:\\x\\y.mp4')
  const [url] = pathsIn('abre file:///C:/Users/user/Mi%20unidad/a.pdf ya')
  assert.equal(url.target, 'C:/Users/user/Mi unidad/a.pdf')
  assert.equal(resolve(url.target, cwd), 'C:\\Users\\user\\Mi unidad\\a.pdf')
})

test('relative paths, either slash, from the working folder; ~ from home; .. folded', () => {
  const cwd = 'C:\\Users\\user\\Atlas'
  assert.equal(resolve('src/app.ts', cwd), 'C:\\Users\\user\\Atlas\\src\\app.ts')
  assert.equal(resolve('src\\app.ts', cwd), 'C:\\Users\\user\\Atlas\\src\\app.ts')
  assert.equal(resolve('../x.md', cwd), 'C:\\Users\\user\\x.md')
  assert.equal(resolve('~/notes.txt', cwd, 'C:\\Users\\user'), 'C:\\Users\\user\\notes.txt')
  assert.equal(resolve('\\Windows\\win.ini', cwd), 'C:\\Windows\\win.ini')
  assert.equal(resolve('\\\\server\\share\\a\\..\\b.txt', cwd), '\\\\server\\share\\b.txt')
  assert.deepEqual(linked('edita lib\\theme.ps1 y src/app.ts', ['C:\\Users\\user\\Atlas\\lib\\theme.ps1', 'C:\\Users\\user\\Atlas\\src\\app.ts']), ['lib\\theme.ps1', 'src/app.ts'])
})

test('POSIX paths on Linux and macOS, and a Windows path under WSL', () => {
  assert.equal(resolve('src/a.ts', '/home/me/p'), '/home/me/p/src/a.ts')
  assert.equal(resolve('~/a b/c.mp4', '/home/me', '/home/me'), '/home/me/a b/c.mp4')
  assert.equal(resolve('C:\\Users\\me\\a.png', '/home/me'), '/mnt/c/Users/me/a.png')
  assert.deepEqual(linked('el video /home/me/My Videos/a.mp4 listo', ['/home/me/My Videos/a.mp4'], '/home/me'), ['/home/me/My Videos/a.mp4'])
})

test('a line after the path, web addresses ignored, inline code spans whole', () => {
  const [found] = pathsIn('ver src/app.ts:42:7 ahora')
  assert.equal(found.target, 'src/app.ts')
  assert.equal(lineOf('src/app.ts:42:7'), 42)
  assert.deepEqual(pathsIn('https://example.com/a/b.png'), [])
  assert.equal(pathOfSpan(DRIVE), DRIVE)
  assert.equal(pathOfSpan('~/a b/c.mp4'), '~/a b/c.mp4')
})
