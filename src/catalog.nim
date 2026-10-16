## Skill discovery: a skill is a directory holding `SKILL.md`. Its directory
## name is the installed name; unreadable or missing frontmatter leaves the
## description empty rather than failing the catalog.

import std/[syncio, strutils, parseutils, os, dirs, algorithm]

type
  Skill* = object
    name*: string         ## directory name; also the installed name
    description*: string

proc validName*(s: string): bool =
  ## Plain names only: no separators, no `..`, no hidden or absolute paths.
  s.len > 0 and s.len <= 64 and s[0] in Letters + Digits and
    skipUntil(s, AllChars - (Letters + Digits + {'_', '-'})) == s.len

proc value(s: string; start = 0): string =
  let first = start + skipUntil(s, AllChars - Whitespace, start)
  var last = s.len
  while last > first and s[last - 1] in Whitespace: dec last
  result = s.substr(first, last - 1)

proc unquote(s: string): string =
  result = value(s)
  if result.len >= 2 and result[0] in {'"', '\''} and result[^1] == result[0]:
    result = result.substr(1, result.len - 2)

proc readDescription*(text: string): string =
  ## `description` from the YAML frontmatter of a SKILL.md, or "".
  result = ""
  var first = true
  var folded = false
  for line in splitLines(text):
    if first:
      if value(line) != "---": return
      first = false
    elif folded:
      if line.len == 0 or line[0] notin {' ', '\t'}: break
      if result.len > 0: result.add ' '
      result.add value(line)
    else:
      if value(line) == "---": break
      var n = skipUntil(line, Whitespace + {':'})
      if line.substr(0, n - 1) == "description":
        n += skipUntil(line, AllChars - Whitespace, n)
        if n < line.len and line[n] == ':':
          result = value(line, n + 1)
          if result.len > 0 and result[0] notin {'>', '|'}: break
          result = ""
          folded = true
  result = unquote(result)

proc discover*(dir: string): seq[Skill] =
  ## Skills directly under `dir`, sorted by name. Symlinked entries are
  ## skipped so the catalog cannot point outside its own directory.
  result = @[]
  try:
    for kind, p in walkDir(path(dir), relative = true):
      let name = $p
      if kind == pcDir and validName(name) and fileExists(dir / name / "SKILL.md"):
        result.add Skill(name: name)
  except:
    discard
  sort(result, proc (a, b: Skill): int = cmp(a.name, b.name))
  for s in mitems(result):
    try:
      s.description = readDescription(readFile(dir / s.name / "SKILL.md"))
    except:
      discard

proc names*(skills: seq[Skill]): seq[string] =
  result = @[]
  for s in skills: result.add s.name
