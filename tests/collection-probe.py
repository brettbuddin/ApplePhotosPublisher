#!/usr/bin/env python3
"""Measure which PhotoKit collection operations raise a macOS confirmation dialog.

Unlike the other scripts in this directory, this one DOES access Photos. It builds a
disposable app with its own bundle identifier, so macOS asks for Photos access on the
first run and the production helper's grant is left alone. The probe only mutates
collections it creates itself.

Watch the screen while it runs and allow anything it asks for. Timings tell the story:
an operation that blocked on a dialog takes human-scale time, a silent one takes
milliseconds.

Reset the probe's permission afterwards with:
  tccutil reset Photos org.buddin.lrphotossync.collection-probe

Usage: collection-probe.py [--decline] [--cleanup] [--open-url] [--rebuild] [--build-only]

--decline runs a different flow that asks you to REFUSE a deletion dialog, to learn what a
declined deletion looks like from the caller's side. Read its on-screen instructions: they
contradict the normal run's "allow everything".

--dwell SECONDS holds after opening the album URL so there is time to look at Photos before
the album is deleted. Defaults to 4, only meaningful with --open-url.

--cleanup deletes any container a previous run left behind. A declined dialog leaves the
album in place, so use this after cancelling a run.

--build-only packages and signs the probe without launching it, which checks that the
fixture still compiles without touching Photos.
"""
import pathlib
import plistlib
import re
import subprocess
import sys
import time

BUNDLE_ID = "org.buddin.lrphotossync.collection-probe"
ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "tmp/collection-probe"
APP = BUILD / "PhotoKit Collection Probe.app"
LOG = BUILD / "probe.log"
TIMEOUT = 300

# Steps that must work for the design to be viable at all. Anything else the probe
# reports is a finding, not a failure.
REQUIRED = ("create-album", "rename-album", "create-folder", "delete-album", "delete-folder")
REQUIRED_DECLINE = ("create-album",)
REQUIRED_CLEANUP = ()
# Above this many seconds, assume the operation blocked on a dialog.
DIALOG_THRESHOLD = 1.0

decline = "--decline" in sys.argv[1:]
cleanup = "--cleanup" in sys.argv[1:]
dwell = (sys.argv[sys.argv.index("--dwell") + 1]
         if "--dwell" in sys.argv[1:] and sys.argv.index("--dwell") + 1 < len(sys.argv)
         else None)
open_url = "--open-url" in sys.argv[1:]
rebuild = "--rebuild" in sys.argv[1:]
build_only = "--build-only" in sys.argv[1:]


def build():
    """Package and sign the probe. A stable path keeps the ad-hoc signature's cdhash
    stable too, so macOS does not re-prompt on every run."""
    executable = APP / "Contents/MacOS/collectionprobe"
    executable.parent.mkdir(parents=True, exist_ok=True)
    with (APP / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundleName": "PhotoKit Collection Probe",
            "CFBundleDisplayName": "PhotoKit Collection Probe",
            "CFBundleExecutable": "collectionprobe",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": "12.0",
            "LSUIElement": True,
            "NSPhotoLibraryUsageDescription":
                "Diagnostic that creates and deletes its own album to measure which "
                "PhotoKit collection operations prompt.",
        }, file)
    subprocess.run(["/usr/bin/plutil", "-lint", str(APP / "Contents/Info.plist")], check=True)
    # -parse-as-library so @main is honored rather than treated as top-level code.
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    "-O", str(ROOT / "tests/fixtures/CollectionProbe.swift"),
                    "-o", str(executable)], check=True)
    # Sign the whole bundle, not just the executable: TCC validates the app identity
    # including its Info.plist. Same reasoning as script/package-helper.sh.
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                    "--options", "runtime", "--entitlements",
                    str(ROOT / "importer/Entitlements.plist"), str(APP)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(APP)], check=True)
    # Rebuilding changes the ad-hoc cdhash, which invalidates any grant filed under this
    # bundle identifier: TCC then denies the new identity outright instead of prompting.
    # Clearing the entry here means the run that follows asks from scratch. Scoped to the
    # probe, so the production helper's grant is untouched.
    subprocess.run(["tccutil", "reset", "Photos", BUNDLE_ID],
                   check=False, capture_output=True)


if rebuild or build_only or not APP.is_dir():
    build()
    print(f"built {APP}")

if build_only:
    sys.exit(0)

LOG.write_text("")
print(f"log: {LOG}")
if cleanup:
    print("CLEANUP mode. Allow the dialog to remove anything a previous run left behind.\n")
elif decline:
    print("DECLINE mode. Follow the instructions in the log: refuse the first dialog,")
    print("then allow the second one so the probe cleans up after itself.\n")
else:
    print("Watch for confirmation dialogs and allow anything the probe asks for.\n")

subprocess.run(["open", "-n", "-a", str(APP), "--args", "--log", str(LOG)]
               + (["--open-url"] if open_url else [])
               + (["--dwell", dwell] if dwell else [])
               + (["--decline"] if decline else [])
               + (["--cleanup"] if cleanup else []), check=True)

shown = 0
deadline = time.monotonic() + TIMEOUT
while time.monotonic() < deadline:
    lines = LOG.read_text().splitlines()
    for line in lines[shown:]:
        print(line)
    shown = len(lines)
    if any(line.startswith(("@done", "STOP:")) for line in lines):
        break
    time.sleep(0.5)
else:
    sys.exit(f"\ntimed out after {TIMEOUT}s; a dialog may still be waiting")

text = LOG.read_text()
if "STOP:" in text:
    # Rebuilding changes the ad-hoc signature's cdhash. TCC still has a decision filed
    # under this bundle identifier, so it denies the new identity outright instead of
    # prompting again. Resetting the entry makes the next run ask from scratch.
    if "authorization=denied" in text or "authorization=restricted" in text:
        print("\nThe probe was denied without being asked. A rebuild invalidates an ad-hoc")
        print("grant, so clear this probe's entry and run again:")
        print(f"  tccutil reset Photos {BUNDLE_ID}")
    sys.exit("\nprobe stopped early, see the log above")

steps = {match["step"]: match for match in
         re.finditer(r"^@step (?P<step>\S+) status=(?P<status>\S+) seconds=(?P<seconds>\S+)"
                     r"(?: error=(?P<error>.*))?$", text, re.M)}
facts = dict(re.findall(r"^@fact (\S+?)=(.*)$", text, re.M))

print("\n=== timings ===")
for name, match in steps.items():
    seconds = float(match["seconds"])
    verdict = "PROMPTED?" if seconds > DIALOG_THRESHOLD else "silent"
    print(f"  {name:28} {match['status']:7} {seconds:7.3f}s  {verdict}")
    if match["error"]:
        print(f"  {'':28} {match['error']}")

print("\n=== findings ===")
for key in ("macos", "authorization", "mode", "album-capabilities", "folder-capabilities",
            "duplicate-adds-tolerated", "album-count-after-one-add",
            "album-count-after-duplicate-add", "album-parent-in-folder",
            "album-parent-after-move", "album-renamed", "album-deleted",
            "folder-deleted", "open-url", "open-url-accepted",
            "decline-threw", "decline-error", "decline-error-message",
            "decline-album-survived", "cleanup-album-deleted",
            "cleanup-albums-found", "cleanup-folders-found", "cleanup-remaining",
            "cleanup-complete"):
    if key in facts:
        print(f"  {key:34} {facts[key]}")

print("\n=== conclusions ===")
if cleanup:
    found = int(facts.get("cleanup-albums-found", 0)) + int(facts.get("cleanup-folders-found", 0))
    if facts.get("cleanup-complete") == "true":
        print(f"  removed {found} leftover container(s), nothing remains")
    else:
        print(f"  {facts.get('cleanup-remaining', '?')} of {found} still present, run again")
if decline:
    threw = facts.get("decline-threw")
    survived = facts.get("decline-album-survived")
    if threw == "true" and survived == "true":
        print("  declining throws and leaves the album, so the handler can detect a refusal")
        print(f"  error: {facts.get('decline-error', '?')}")
        if "userCancelled" in facts.get("decline-error", ""):
            print("  it reports userCancelled, which is distinguishable from a real failure")
        else:
            print("  it does NOT report userCancelled, so a refusal looks like a generic failure")
    elif threw == "false" and survived == "true":
        print("  declining reports SUCCESS but leaves the album, so the result cannot be")
        print("  trusted; verify the album is gone after deleting it")
    elif survived == "false":
        print("  the album was deleted despite the decline")
    else:
        print("  inconclusive, see the findings above")

delete = steps.get("delete-album")
if delete:
    prompted = float(delete["seconds"]) > DIALOG_THRESHOLD
    print(f"  deleteAssetCollections {'PROMPTS' if prompted else 'is silent'} "
          f"({delete['seconds']}s)")
if facts.get("album-parent-after-move") == "top-level":
    print("  adding to the top-level list moves an album out of its folder")
elif "album-parent-after-move" in facts:
    print(f"  moving to the top level did NOT work, parent is still "
          f"{facts['album-parent-after-move']}")
if facts.get("duplicate-adds-tolerated") == "true":
    print("  albums tolerate the same asset twice, so membership must be checked first")
elif facts.get("duplicate-adds-tolerated") == "false":
    print("  albums reject a duplicate add, so a membership check is belt and braces")

print(f"\nReset the probe's permission with:\n  tccutil reset Photos {BUNDLE_ID}")

required = (REQUIRED_CLEANUP if cleanup
            else REQUIRED_DECLINE if decline else REQUIRED)
failures = [name for name in required
            if name not in steps or steps[name]["status"] != "ok"]
expected_facts = (("cleanup-complete",) if cleanup
                  else ("cleanup-album-deleted",) if decline
                  else ("album-deleted", "folder-deleted"))
for key in expected_facts:
    if facts.get(key) not in ("true", "not-needed"):
        failures.append(key)
if failures:
    sys.exit(f"\nFAILED: {', '.join(failures)}")
print("\nrequired operations all succeeded")
