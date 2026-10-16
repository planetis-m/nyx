## Path formatting tests.
include ../src/nyx
import std/envvars

proc testPaths*(): int {.raises.} =
  result = 0
  template check(actual, expected: string; label: string) =
    if actual != expected:
      echo "FAIL: paths: ", label, ": got [", actual, "], expected [", expected, "]"
      inc result

  const key = when defined(windows): "USERPROFILE" else: "HOME"
  let hadHome = existsEnv(key)
  let oldHome = getEnv(key)
  defer:
    if hadHome: putEnv(key, oldHome)
    else: delEnv(key)

  let sep = $DirSep
  let drive = when defined(windows): "C:" else: ""
  let home = drive & sep & "Users" & sep & "test"
  let cwd = home & sep & "projects" & sep & "myproject"
  let outside = drive & sep & "var" & sep & "www" & sep & "myproject"
  let log = drive & sep & "var" & sep & "log" & sep & "system.log"
  putEnv(key, home)

  check(display(path(home & sep & "documents" & sep & "file.txt")),
        "~" & sep & "documents" & sep & "file.txt", "home")
  check(display(path(cwd & sep & "src" & sep & "file.ts")),
        "~" & sep & "projects" & sep & "myproject" & sep & "src" & sep & "file.ts",
        "prefer home")
  check(rel(Ctx(root: path(outside)), path(outside & sep & "src" & sep & "file.ts")),
        "src" & sep & "file.ts", "cwd outside home")
  check(display(path(log)), log, "unrelated home")
  check(rel(Ctx(root: path(outside)), path(log)), log, "unrelated cwd")
  check(display(path(home)), "~", "exact home")
  check(display(path(cwd)), "~" & sep & "projects" & sep & "myproject",
        "exact cwd under home")
  check(rel(Ctx(root: path(outside)), path(outside)), outside,
        "exact cwd outside home")
  check(display(path(home & "er" & sep & "file.txt")), home & "er" & sep & "file.txt",
        "sibling home")
  check(display(path(cwd & "2" & sep & "file.txt")),
        "~" & sep & "projects" & sep & "myproject2" & sep & "file.txt",
        "sibling cwd still under home")
  check(rel(Ctx(root: path(cwd)), path(cwd & "2" & sep & "file.txt")),
        cwd & "2" & sep & "file.txt", "sibling cwd is not relative")

  for (p, want) in [
      ("", ""), ("relative", "relative"), (drive & sep & "Users", drive & sep & "Users"),
      (home & "2", home & "2"), (home & ".old" & sep & "x", home & ".old" & sep & "x"),
      (home & sep, "~" & sep), (home & sep & "x", "~" & sep & "x"),
      (home & sep & "λ 技能", "~" & sep & "λ 技能"),
      (home & sep & sep & "x", "~" & sep & sep & "x")]:
    check(display(path(p)), want, "display boundary " & p)
  for suffix in [sep, sep & sep]:
    putEnv(key, home & suffix)
    check(display(path(home)), "~", "trailing home: exact")
    check(display(path(home & sep & "x")), "~" & sep & "x", "trailing home: child")
    check(display(path(home & "2" & sep & "x")), home & "2" & sep & "x", "trailing home: sibling")
  putEnv(key, home)

  for (root, p, want) in [
      (cwd, "", ""), (cwd, home, home), (cwd, cwd & "2", cwd & "2"),
      (cwd, cwd & sep, ""), (cwd, cwd & sep & "f", "f"),
      (cwd, cwd & sep & "dir" & sep & "f", "dir" & sep & "f"),
      (cwd, cwd & sep & "λ 技能", "λ 技能"),
      (cwd, cwd & sep & sep & "f", sep & "f"),
      (cwd & sep, cwd & sep, cwd & sep),
      (cwd & sep, cwd & sep & "file", "file"),
      ("", "relative", "relative"), ("", drive & sep & "x", drive & sep & "x")]:
    check(rel(Ctx(root: path(root)), path(p)), want, "rel boundary " & root & " -> " & p)

  let root = drive & sep
  putEnv(key, root)
  check(display(path(root)), "~", "filesystem root home: exact")
  check(display(path(root & "f")), "~" & sep & "f", "filesystem root home: one-character child")
  check(display(path(root & "file")), "~" & sep & "file", "filesystem root home: child")
  check(display(path("relative")), "relative", "filesystem root home: unrelated")
  check(rel(Ctx(root: path(root)), path(root)), root, "filesystem project root: exact")
  check(rel(Ctx(root: path(root)), path(root & "f")), "f",
    "filesystem project root: one-character child")
  check(rel(Ctx(root: path(root)), path(root & "file")), "file", "filesystem project root: child")
  check(rel(Ctx(root: path(root)), path("relative")), "relative",
    "filesystem project root: unrelated")

  putEnv(key, home)
  check(display(path(home.toUpperAscii & sep & "x")), home.toUpperAscii & sep & "x",
        "display remains case-sensitive")
  check(rel(Ctx(root: path(cwd)), path(cwd.toUpperAscii & sep & "x")), cwd.toUpperAscii & sep & "x",
        "rel remains case-sensitive")
  when defined(windows):
    check(display(path(home & "/x")), "~/x", "alternate home separator")
    check(rel(Ctx(root: path(cwd)), path(cwd & "/x")), "x", "alternate project separator")
    putEnv(key, "C:/")
    check(display(path("C:/file")), "~/file", "alternate drive root")
    check(display(path("C:")), "C:", "drive-relative path is not drive root")
    check(display(path("D:\\file")), "D:\\file", "another drive")
    check(rel(Ctx(root: path("C:\\")), path("D:\\file")), "D:\\file", "another project drive")
  else:
    check(display(path(home & "\\x")), home & "\\x", "backslash is a filename character")
    check(rel(Ctx(root: path(cwd)), path(cwd & "\\x")), cwd & "\\x", "backslash is not a boundary")
    putEnv(key, home & "\\")
    check(display(path(home & "\\/x")), "~/x", "literal backslash in home is preserved")
