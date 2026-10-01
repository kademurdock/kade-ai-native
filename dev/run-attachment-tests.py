#!/usr/bin/env python3
"""Run the four synthetic attachment XCTest cases once on an installed simulator."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


TEST_NAMES = (
    "testCancelIgnoresOldUploadAndKeepsNextOperationBusy",
    "testTimeoutClearsBusyAndLeavesExplicitRetry",
    "testManualRetryPreservesPreparedBytesAndOriginalContext",
    "testSharedSizeGuardRejectsEmptyAndOversizedBytes",
)
TIMEOUT_SECONDS = 600


def simulator_id(devices):
    phones = [device for runtime, rows in devices["devices"].items()
              if ".iOS-" in runtime for device in rows
              if "iPhone" in device.get("name", "")
              and device.get("isAvailable", True)]
    if not phones:
        raise ValueError("No installed available iPhone simulator; no runtime will be downloaded")
    phones.sort(key=lambda device: (device.get("state") != "Booted",
                                   "Pro" not in device["name"], device["name"]))
    return phones[0]["udid"]


def passed_tests(log):
    return [name for name in TEST_NAMES
            if re.search(r"(?im)^\s*Test [Cc]ase [^\n]*ChatAttachmentPreparationTests[^\n]*"
                         + re.escape(name) + r"[^\n]*\bpassed\b", log)]


def stop_process(process):
    # Xcodebuild and its child processes share this dedicated process group.
    # Stop the same attempt on timeout; there is no rebuild or test retry.
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)
    except ProcessLookupError:
        pass


def run():
    folder = Path(os.environ.get("CM_BUILD_DIR", Path.cwd())).resolve()
    status_path = folder / "attachment-tests-status.json"
    log_path = folder / "attachment-tests.log"
    errors_path = folder / "attachment-first-errors.txt"
    result_path = folder / "attachment-tests.xcresult"
    started = time.monotonic()
    status = {"passed": False, "expectedTests": list(TEST_NAMES), "passedTests": [],
              "timeoutSeconds": TIMEOUT_SECONDS, "attempts": 1, "exitStatus": None}
    status_path.write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    exit_status = 1
    try:
        if result_path.exists():
            raise ValueError("Result bundle already exists; refusing to obscure a previous attempt")
        listing = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                                 capture_output=True, text=True, check=True, timeout=30)
        simulator = simulator_id(json.loads(listing.stdout))
        status["simulator"] = simulator
        command = ["xcodebuild", "test", "-project", "KadeAI.xcodeproj",
                   "-scheme", "KadeAIAttachmentTests", "-configuration", "Debug",
                   "-sdk", "iphonesimulator", "-destination", f"platform=iOS Simulator,id={simulator}",
                   "-destination-timeout", "60",
                   "-derivedDataPath", str(folder / "build/compile-simulator"),
                   "-resultBundlePath", str(result_path),
                   "-parallel-testing-enabled", "NO", "-test-iterations", "1",
                   "-test-timeouts-enabled", "YES",
                   "-default-test-execution-time-allowance", "30",
                   "-maximum-test-execution-time-allowance", "60",
                   "-only-testing:KadeAIAttachmentTests/ChatAttachmentPreparationTests",
                   "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                   "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -warn-long-expression-type-checking=150"]
        print(f"Attachment tests: simulator {simulator}, one attempt, {TIMEOUT_SECONDS}s deadline", flush=True)
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                exit_status = process.wait(timeout=TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                stop_process(process)
                exit_status = 124
                status["error"] = "Attachment test deadline exceeded"
        output = log_path.read_text(encoding="utf-8", errors="replace")
        status["passedTests"] = passed_tests(output)
        if exit_status == 0 and len(status["passedTests"]) != len(TEST_NAMES):
            exit_status = 1
            status["error"] = "Xcodebuild returned success without all four attachment tests passing"
        status["passed"] = exit_status == 0
        if exit_status:
            errors = [line for line in output.splitlines()
                      if re.search(r"error:|error :|failed|Testing failed|Failing tests", line, re.I)]
            errors_path.write_text("\n".join(errors[:20] or output.splitlines()[-80:]) + "\n", encoding="utf-8")
        else:
            errors_path.write_text("All four synthetic attachment tests passed.\n", encoding="utf-8")
        print("\n".join(output.splitlines()[-80:]))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        if exit_status == 0:
            exit_status = 1
        status["passed"] = False
        status["error"] = str(error)
        errors_path.write_text(str(error) + "\n", encoding="utf-8")
        if not log_path.exists():
            log_path.write_text(str(error) + "\n", encoding="utf-8")
        print(f"Attachment tests could not complete: {error}")
    finally:
        status["exitStatus"] = exit_status
        status["elapsedSeconds"] = round(time.monotonic() - started, 3)
        status_path.write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    return exit_status


if __name__ == "__main__":
    raise SystemExit(run())
