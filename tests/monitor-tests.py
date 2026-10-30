#!/usr/bin/env python3
"""Exercise real Launch Services, production handshake, and kernel exit events.

Uses a disposable app; never imports, deletes, or requests access to Photos.
Pass a built lrphotoslauncher path as the first argument.
"""
import pathlib
import plistlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
launcher = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="lrphotos-monitor-tests-") as temp:
    directory = pathlib.Path(temp)
    app = directory / "Monitor's Test.app"
    executable = app / "Contents/MacOS/fixture"
    executable.parent.mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleIdentifier": "org.buddin.lrphotossync.monitor-tests",
                      "CFBundleName": "Monitor Test", "CFBundleExecutable": "fixture",
                      "CFBundleVersion": "1", "CFBundlePackageType": "APPL", "LSUIElement": True}, file)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                    str(ROOT / "importer/Sources/LaunchSupport/StartupHandshake.swift"),
                    str(ROOT / "tests/fixtures/LaunchFixture.swift"), "-o", str(executable)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", str(app)], check=True)

    def run(arguments, app_path=app):
        stdout, stderr, status = [directory / name for name in ("stdout", "stderr", "status")]
        for path in (stdout, stderr, status):
            path.write_text("")
        result = subprocess.run([str(launcher), "--app", str(app_path), "--stdout", str(stdout),
                                 "--stderr", str(stderr), "--status", str(status),
                                 "--startup-timeout", "2", "--", *arguments],
                                capture_output=True, text=True, timeout=15)
        record = dict(line.split("=", 1) for line in status.read_text().splitlines())
        assert record["version"] == "1", (result, record)
        return result, record, stdout.read_text()

    for code in (0, 23, 134, 255):
        result, record, output = run([str(code)])
        assert result.returncode == 0, result.stderr
        assert record["state"] == "exited" and int(record["exitCode"]) == code, record
        assert int(record["rawStatus"]) == code << 8, record
    for mode, signal in (("abort", 6), ("kill", 9), ("success-then-abort", 6)):
        result, record, output = run([mode])
        assert result.returncode == 0, result.stderr
        assert record["state"] == "signaled" and int(record["signal"]) == signal, record
        if mode == "success-then-abort":
            assert "<status>success</status>" in output, output
    for _ in range(10):
        result, record, output = run(["echo", "a 'quote' $(touch never-run)", "--option-like-argument"])
        assert result.returncode == 0 and record["exitCode"] == "0", (result, record)
        assert output == "a 'quote' $(touch never-run)\n--option-like-argument\n", output
    result, record, output = run(["before-handshake"])
    assert result.returncode != 0 and record["state"] == "startupFailed", (result, record)
    assert "exit status is unavailable" in result.stderr, result.stderr
    result, record, output = run(["0"], directory / "Missing.app")
    assert result.returncode != 0 and record["state"] == "startupFailed", (result, record)
    assert "Launch Services failed" in result.stderr, result.stderr
    # A helper without its launcher must time out without executing its command.
    handshake = directory / "abandoned-handshake"
    handshake.mkdir()
    result = subprocess.run([str(executable), "--launcher-handshake", str(handshake), "echo", "MUST NOT RUN"],
                            capture_output=True, text=True, timeout=5)
    assert result.returncode != 0 and "MUST NOT RUN" not in result.stdout, result
    assert "Timed out waiting" in result.stderr, result.stderr
print("PASS: actual exit codes, SIGABRT, SIGKILL, crash after XML, fast exits, quoting, startup failures, missing monitor")
