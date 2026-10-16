## Git error message formatting tests.
include ../src/nyx

proc testFirstLine*(): int {.raises.} =
  result = 0
  template check(input, expected, label: string) =
    let got = firstLine(input)
    if got != expected:
      echo "FAIL: firstLine: ", label, ": got [", got, "], expected [",
        expected, "]"
      inc result

  check("", "", "empty message shows nothing")
  check("\n", "", "one blank line shows nothing")
  check("   \n\t\n ", "", "whitespace only shows nothing")

  check("fatal: x", "fatal: x", "single line without a line break")
  check("fatal: x\nmore", "fatal: x", "first line of a message")
  check("\n\n  fatal: x\nmore", "fatal: x", "leading blank lines are dropped")
  check("   leading line\nsecond", "leading line", "leading space is dropped")
  check("fatal: x\0tail", "fatal: x\0tail", "NUL is ordinary data")

  # strip trims the end of the whole message, which is the last line only.
  check("fatal: x   \nmore", "fatal: x   ", "trailing space on an earlier line stays")
  check("fatal: x   ", "fatal: x", "trailing space on the last line goes")
  check("fatal: x  \n", "fatal: x", "trailing space before the final break goes")
  check("fatal: x  \n\n", "fatal: x", "blank lines after the last line go")
  check("fatal: x  \n \n", "fatal: x", "blank space after the last line goes")
  check("fatal: x  \r\n", "fatal: x", "CR-LF tail and trailing space go")

  check("a\rb", "a", "carriage return ends a line")
  check("remote: counting\rremote: done\n", "remote: counting",
        "progress overwritten with carriage returns")
  check("fatal: y\r\nsecond", "fatal: y", "CR-LF ends a line")
  check("h\xC3\xA9llo\nworld", "h\xC3\xA9llo", "bytes are counted, not characters")
