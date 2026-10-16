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

  check(display(home & sep & "documents" & sep & "file.txt"),
        "~" & sep & "documents" & sep & "file.txt", "home")
  check(display(cwd & sep & "src" & sep & "file.ts"),
        "~" & sep & "projects" & sep & "myproject" & sep & "src" & sep & "file.ts",
        "prefer home")
  check(rel(Ctx(root: outside), outside & sep & "src" & sep & "file.ts"),
        "src" & sep & "file.ts", "cwd outside home")
  check(display(log), log, "unrelated home")
  check(rel(Ctx(root: outside), log), log, "unrelated cwd")
  check(display(home), "~", "exact home")
  check(display(cwd), "~" & sep & "projects" & sep & "myproject",
        "exact cwd under home")
  check(rel(Ctx(root: outside), outside), outside,
        "exact cwd outside home")
  check(display(home & "er" & sep & "file.txt"), home & "er" & sep & "file.txt",
        "sibling home")
  check(display(cwd & "2" & sep & "file.txt"),
        "~" & sep & "projects" & sep & "myproject2" & sep & "file.txt",
        "sibling cwd still under home")
  check(rel(Ctx(root: cwd), cwd & "2" & sep & "file.txt"),
        cwd & "2" & sep & "file.txt", "sibling cwd is not relative")

  for (p, want) in [
      ("", ""), ("relative", "relative"), (drive & sep & "Users", drive & sep & "Users"),
      (home & "2", home & "2"), (home & ".old" & sep & "x", home & ".old" & sep & "x"),
      (home & sep, "~" & sep), (home & sep & "x", "~" & sep & "x"),
      (home & sep & "λ 技能", "~" & sep & "λ 技能"),
      (home & sep & sep & "x", "~" & sep & sep & "x")]:
    check(display(p), want, "display boundary " & p)
  for suffix in [sep, sep & sep]:
    putEnv(key, home & suffix)
    check(display(home), "~", "trailing home: exact")
    check(display(home & sep & "x"), "~" & sep & "x", "trailing home: child")
    check(display(home & "2" & sep & "x"), home & "2" & sep & "x", "trailing home: sibling")
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
    check(rel(Ctx(root: root), p), want, "rel boundary " & root & " -> " & p)

  let root = drive & sep
  putEnv(key, root)
  check(display(root), "~", "filesystem root home: exact")
  check(display(root & "f"), "~" & sep & "f", "filesystem root home: one-character child")
  check(display(root & "file"), "~" & sep & "file", "filesystem root home: child")
  check(display("relative"), "relative", "filesystem root home: unrelated")
  check(rel(Ctx(root: root), root), root, "filesystem project root: exact")
  check(rel(Ctx(root: root), root & "f"), "f", "filesystem project root: one-character child")
  check(rel(Ctx(root: root), root & "file"), "file", "filesystem project root: child")
  check(rel(Ctx(root: root), "relative"), "relative", "filesystem project root: unrelated")

  putEnv(key, home)
  check(display(home.toUpperAscii & sep & "x"), home.toUpperAscii & sep & "x",
        "display remains case-sensitive")
  check(rel(Ctx(root: cwd), cwd.toUpperAscii & sep & "x"), cwd.toUpperAscii & sep & "x",
        "rel remains case-sensitive")
  when defined(windows):
    check(display(home & "/x"), "~/x", "alternate home separator")
    check(rel(Ctx(root: cwd), cwd & "/x"), "x", "alternate project separator")
    putEnv(key, "C:/")
    check(display("C:/file"), "~/file", "alternate drive root")
    check(display("C:"), "C:", "drive-relative path is not drive root")
    check(display("D:\\file"), "D:\\file", "another drive")
    check(rel(Ctx(root: "C:\\"), "D:\\file"), "D:\\file", "another project drive")
  else:
    check(display(home & "\\x"), home & "\\x", "backslash is a filename character")
    check(rel(Ctx(root: cwd), cwd & "\\x"), cwd & "\\x", "backslash is not a boundary")
    putEnv(key, home & "\\")
    check(display(home & "\\/x"), "~/x", "literal backslash in home is preserved")
