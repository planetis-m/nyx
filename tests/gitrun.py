"""Capture local Git output through pipes and terminals (POSIX)."""

import errno
import json
import os
from pathlib import Path
import pty
import selectors
import signal
import subprocess
import sys
import tempfile
import time


def run(binary, root, terminal, size, message, code, result, fault=False, startup=False):
    marker = root / "marker.json"
    marker.unlink(missing_ok=True)
    env = {
        **os.environ,
        "PATH": str(root) + os.pathsep + os.environ["PATH"],
        "NYX_GIT_MARKER": str(marker),
        "NYX_GIT_BYTES": str(size),
        "NYX_GIT_MESSAGE": message,
        "NYX_GIT_CODE": str(code),
        "NYX_GIT_RESULT": result,
        "NYX_GIT_FAULT": "1" if fault else "0",
        "GIT_SSH_COMMAND": "ssh -o ExistingSetting=yes",
    }
    if startup:
        env["PATH"] = str(root)
    master, slave = pty.openpty() if terminal else (None, None)
    proc = subprocess.Popen(
        [str(binary)], stdin=subprocess.DEVNULL,
        stdout=slave if terminal else subprocess.PIPE,
        stderr=subprocess.STDOUT, env=env, start_new_session=True,
    )
    if terminal:
        os.close(slave)
    output = bytearray()
    timed_out = False
    try:
        with selectors.DefaultSelector() as sel:
            sel.register(master if terminal else proc.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 5
            while sel.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                for key, _ in sel.select(min(remaining, 0.1)):
                    try:
                        data = os.read(key.fd, 65536)
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
                        data = b""
                    if data:
                        output.extend(data)
                    else:
                        sel.unregister(key.fileobj)
            if not timed_out:
                proc.wait(timeout=max(0.01, deadline - time.monotonic()))
    finally:
        # Reap the fake Git even after a timeout or failed assertion.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=2)
        if terminal:
            os.close(master)
        else:
            proc.stdout.close()

    record = json.loads(marker.read_text()) if marker.exists() else {}
    print(json.dumps({
        "terminal": terminal, "bytes": size * 3, "result": result,
        "fault": fault, "timed_out": timed_out, "exit": proc.returncode,
        "finished": record.get("finished", False),
    }), flush=True)
    assert not timed_out, "Git blocked with a full output pipe"
    assert proc.returncode == 0, output.decode(errors="replace")
    if not (fault or startup):
        assert record == {
            "finished": True, "prompt": "0", "ssh": env["GIT_SSH_COMMAND"],
        }, record
    assert b"git run passed" in output, output
    assert b"x\x00y" not in output, "Git chatter leaked to the terminal"
    assert output.strip() == b"git run passed", output


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "bin/tgitrun").resolve()
    with tempfile.TemporaryDirectory(prefix="nyx-gitrun-") as tmp:
        root = Path(tmp)
        fake = root / "git"
        fake.write_text("#!" + sys.executable + "\n" + '''
import json, os, time
from pathlib import Path
marker = Path(os.environ["NYX_GIT_MARKER"])
marker.write_text(json.dumps({"finished": False}))
def write(fd, data):
    while data:
        data = data[os.write(fd, data):]
write(1, os.environ["NYX_GIT_MESSAGE"].encode())
data = b"x\\0y" * int(os.environ["NYX_GIT_BYTES"])
mid = len(data) // 2
write(1, data[:mid])
time.sleep(0.2)
write(2, data[mid:])
marker.write_text(json.dumps({
    "finished": True, "prompt": os.environ.get("GIT_TERMINAL_PROMPT"),
    "ssh": os.environ.get("GIT_SSH_COMMAND"),
}))
raise SystemExit(int(os.environ["NYX_GIT_CODE"]))
''')
        fake.chmod(0o755)
        for terminal in (False, True):
            for size in (0, 1, 1024, 1024 * 1024):
                run(binary, root, terminal, size, "", 0, "Done")
            for message, result in (
                ("permission denied\n", "NoAccess"),
                ("could not resolve host\n", "Offline"),
                ("fatal: other problem\n", "Failed"),
            ):
                run(binary, root, terminal, 1024 * 1024, message, 1, result)
        run(binary, root, False, 0, "", 0, "Failed", fault=True)
        fake.write_text("#!/nyx-missing-interpreter\n")
        run(binary, root, False, 0, "", 0, "Failed", startup=True)
    print("Git terminal and pipe tests passed")


if __name__ == "__main__":
    main()
