// The surface module of a path in a reply: it draws its part of the path (a path a row wraps is
// drawn in parts, one a row), and says when the pointer comes onto it and leaves it, so the hooks
// module shows that path's preview and hides it; and when it is clicked, so the hooks module
// shows the path in the file manager (opens it, with alt, ctrl or the right or middle button).
import type { ClientModule } from 'claude-code'

/** The part drawn, the path it belongs to and the line it names, and the style of the text around it. */
type Props = { label: string; path: string; line?: number; bold?: boolean; italic?: boolean; strike?: boolean }

const REPEAT_MS = 50

const Link: ClientModule<Props, { isOver: boolean; isPressed?: boolean; isOpening?: boolean }> = (props, surface) => {
  const where = { path: props.path, ...(props.line !== undefined && { line: props.line }) }
  surface.onPointer(event => {
    // A click is a button let go over the part it went down on: the left shows, any other or a modifier opens.
    if (event.type === 'down') {
      if (event.button) surface.setState({ isOver: true, isPressed: true, isOpening: event.button !== 'left' || event.alt === true || event.ctrl === true })
      return
    }
    if (event.type === 'up') {
      // A region not laid out yet (0 by 0) says nothing of where the pointer is.
      const isInside = surface.columns === 0 || (event.x >= 0 && event.y >= 0 && event.x < surface.columns && event.y < surface.rows)
      if (surface.state?.isPressed && isInside) surface.post({ ...where, isOver: true, isClicked: true, ...((surface.state.isOpening || event.alt || event.ctrl) && { isAlt: true }) })
      surface.setState({ isOver: isInside, isPressed: false, isOpening: false })
      return
    }
    // A move over the part says so again: a preview hidden while the pointer stayed comes back.
    const isOver = event.type !== 'leave'
    surface.post({ ...where, isOver })
    if (isOver !== (surface.state?.isOver ?? false)) surface.setState({ isOver, isPressed: surface.state?.isPressed, isOpening: surface.state?.isOpening })
    // Going straight from one part to the next, the leave and the enter post in one frame, and the
    // later replaces the other: the enter says so again a frame on.
    if (event.type === 'enter') {
      const stop = surface.every(REPEAT_MS, () => {
        stop()
        if (surface.state?.isOver) surface.post({ ...where, isOver: true })
      })
    }
  })
  const { Text } = surface.elements
  return (
    <Text color="permission" bold={props.bold} italic={props.italic} strikethrough={props.strike} underline={surface.state?.isOver === true}>
      {props.label}
    </Text>
  )
}

export default Link
