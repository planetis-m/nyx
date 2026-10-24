## Terminal look and interaction: colors, logo, prompts, and results.

import std/[syncio, strutils, parseutils, terminal, colors, os]

const
  Logo = slurp("../assets/logo.ans")
  WordmarkRows = 4
  Reset* = ansiResetCode
  # Fire gradient of the NYX wordmark, top row to bottom row.
  MarkColors = [(255, 226, 52), (255, 161, 23), (245, 103, 10), (226, 52, 14)]

type
  Choice* = object
    label*: string
    detail*: string
    tag*: string       ## short colored marker, e.g. "pro"
    group*: string     ## section header; printed when it changes

let
  Bold* = ansiStyleCode(styleBright)
  White* = ansiForegroundColorCode(rgb(238, 238, 232))
  Bone* = ansiForegroundColorCode(rgb(196, 192, 186))
  Ash* = ansiForegroundColorCode(rgb(120, 118, 114))
  Gold* = ansiForegroundColorCode(rgb(230, 184, 40))
  Ember* = ansiForegroundColorCode(rgb(255, 128, 8))
  Blood* = ansiForegroundColorCode(rgb(226, 52, 14))

proc interactive*(): bool =
  ## False when stdout is not a terminal: no animation, no redraws.
  terminal.isatty(stdout)

proc sleepMs*(ms: int) =
  if not interactive(): return
  os.sleep(ms)

proc put*(s: string) =
  stdout.write s
  flushFile stdout

proc line*(s = "") =
  put s & Reset & "\n"

proc markColor(c: (int, int, int); k: float): string =
  ## Bold `c` scaled to brightness `k` (0..1).
  Bold & ansiForegroundColorCode(rgb(int(float(c[0]) * k), int(float(c[1]) * k),
                                     int(float(c[2]) * k)))

proc stripAnsi(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\x1b':
      while i < s.len and s[i] != 'm': inc i
    else:
      result.add s[i]
    inc i

proc logoParts(): (seq[string], seq[string]) =
  let all = Logo.strip(leading = false).split('\n')
  var art: seq[string] = @[]
  var mark: seq[string] = @[]
  for i in 0 ..< all.len:
    if i >= all.len - WordmarkRows: mark.add stripAnsi(all[i])
    elif all[i].len > 0 or i < all.len - WordmarkRows - 1: art.add all[i]
  result = (art, mark)

proc ignite(mark: seq[string]; ms: int) =
  ## Fade the wordmark up from ember to full fire.
  let steps = if interactive(): 10 else: 1
  for s in 1 .. steps:
    if s > 1:  # back to the start of the wordmark's first line
      cursorUp(stdout, mark.len)
      setCursorXPos(stdout, 0)
    let k = if steps == 1: 1.0 else: (float(s) / float(steps)) * (float(s) / float(steps))
    for i in 0 ..< mark.len:
      put "  " & markColor(MarkColors[min(i, MarkColors.high)], k) & mark[i] & Reset & "\n"
    sleepMs(ms div steps)

proc splash*() =
  ## Display the title.
  let (art, mark) = logoParts()
  hideCursor(stdout)
  line()
  for l in art:
    put "  " & l & Reset & "\n"
    sleepMs(600 div art.len)
  line()
  ignite(mark, 400)
  showCursor(stdout)
  line()

proc banner*() =
  ## Compact header for the non-wizard commands: just the burning wordmark.
  let (_, mark0) = logoParts()
  var indent = high(int)
  for l in mark0: indent = min(indent, l.len - l.strip(trailing = false).len)
  var mark: seq[string] = @[]
  for l in mark0: mark.add l.substr(indent)
  hideCursor(stdout)
  line()
  ignite(mark, 250)
  showCursor(stdout)
  line()

# --- output helpers -------------------------------------------------------

proc heading*(s: string) =
  line "  " & Bold & Gold & s.toUpperAscii

proc field*(label, value: string) =
  line "  " & Ash & alignLeft(label, 9) & Reset & value

proc ok*(s: string) =
  line "  " & Gold & "+ " & Reset & s

proc warn*(s: string) =
  line "  " & Ember & "! " & Reset & s

proc fail*(s: string) =
  line "  " & Blood & "x " & Reset & s

proc dim*(s: string): string = Ash & s & Reset

# --- input ----------------------------------------------------------------

proc ask*(prompt: string): string =
  ## Read one line; EOF (ctrl-d) aborts the whole run quietly.
  put "  " & Gold & "> " & Reset & Ash & prompt & Reset & " "
  var s = ""
  if not readLine(stdin, s):
    line()
    line "  " & dim("aborted")
    quit(1)
  result = s.strip()

proc confirm*(prompt: string; default: bool): bool =
  let hint = if default: "[Y/n]" else: "[y/N]"
  let a = ask(prompt & " " & hint).toLowerAscii
  if a.len == 0: result = default
  else: result = a[0] == 'y'

proc drawChoices(items: seq[Choice]; sel: seq[bool]): int =
  ## Prints the list, returns how many lines it used.
  result = 0
  var width = 0
  for it in items: width = max(width, it.label.len)
  var group = ""
  for i in 0 ..< items.len:
    let it = items[i]
    if it.group != group:
      group = it.group
      line "  " & Ash & "-- " & group
      inc result
    let box = if sel[i]: Gold & "[x]" else: Ash & "[ ]"
    let name = (if sel[i]: White else: Bone) & alignLeft(it.label, width + 2)
    let tag = if it.tag.len > 0: Gold & alignLeft(it.tag, 4) else: ""
    line "  " & Ash & align($(i + 1), 2) & " " & box & " " & name & tag & Ash & it.detail
    inc result

proc choose*(items: seq[Choice]; sel: var seq[bool]; minOne: bool) =
  ## Numbered checkbox list. Type numbers to toggle (e.g. `1 3`), `a` for all,
  ## `n` for none, enter to accept. Redraws in place.
  var drawn = drawChoices(items, sel)
  while true:
    let a = ask("toggle 1-" & $items.len & ", a/n, enter to accept")
    let lines = drawn + 1
    if a.len == 0:
      if true in sel or not minOne:
        if interactive(): put "\x1b[1F\x1b[J"   # drop the spent prompt line
        break
      put "\x1b[" & $lines & "F\x1b[J"
      drawn = drawChoices(items, sel)
      warn "pick at least one"
      inc drawn
    else:
      case a
      of "a":
        for i in 0 ..< sel.len: sel[i] = true
      of "n":
        for i in 0 ..< sel.len: sel[i] = false
      else:
        for tok in a.split(Whitespace + {','}):
          var n = BiggestInt(0)
          if parseBiggestInt(tok, n) == tok.len and n >= 1 and n <= items.len:
            sel[int(n) - 1] = not sel[int(n) - 1]
      if interactive():
        put "\x1b[" & $lines & "F\x1b[J"
      drawn = drawChoices(items, sel)

proc done*(label, detail: string) =
  line "  " & Gold & "+ " & Reset & alignLeft(label, 25) & dim(detail)
