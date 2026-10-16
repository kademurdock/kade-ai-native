"""Bounded, source-bound unsigned Release/device compile proof; no runtime proof.

CI only. Existing immutable-art/model gates run before the generic iOS build.
Native assetutil inspection is required; an unavailable tool leaves proof false.
Only compact receipts and a bounded failure tail are emitted through job logs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "kademurdock/kade-ai-native"
BRANCH = "claude/release-device-20261016"
XCODE = "/Applications/Xcode_26.4.1.app/Contents/Developer"
VERSION = "2.2.14"
OPERATION_SECONDS = 1800
EXPECTED_MODEL_CHECKS = 171686
MODEL_GROUPS = {"Character motion", "Call meter and expression", "Character reactions and playback ownership",
                "Authored facial selection", "Isolated hand study", "Layered figure motion",
                "Character bust review and transforms", "Production puppet identity and safety",
                "Character stage layout", "Angel vector geometry and motion", "Fresh agent chat routing"}
MASTER_SHA = "285b6e1f176b79ba08cfc7a4252a3d8864901eabbdcbc1e58f304299164206d2"
ASSET_NAME = "CharacterDellaArticulatedReview"
CAST_IMAGES = {
    'CharacterDellaArticulatedReview':(1254,1254),'CharacterDellaBustBody':(1254,1254),'CharacterDellaBustMask':(1254,1254),
    'CharacterHarleyBustBody':(1024,1536),'CharacterHarleyBustMask':(1254,1254),
    'CharacterHarleyFaces':(1254,1254),'CharacterHarleyMouths':(1254,1254),'CharacterHarleyNuance':(1254,1254),
    'CharacterKianaFaces':(1254,1254),'CharacterKianaMouths':(1254,1254),'CharacterKianaNuance':(1254,1254),
    'CharacterLillyBustBody':(1254,1254),'CharacterLillyFaces':(1254,1254),'CharacterLillyMouths':(1254,1254),'CharacterLillyNuance':(1254,1254),
    'CharacterWitherspoonBustBody':(1024,1536),'CharacterWitherspoonFaces':(1254,1254),'CharacterWitherspoonMouths':(1254,1254),
}
CAST_DATA = 'CharacterAngelVectorArt'
BUNDLES = {"KadeAI.app": "com.kademurdock.kadeai",
           "KadeAI.app/PlugIns/KadeKeyboard.appex": "com.kademurdock.kadeai.keyboard",
           "KadeAI.app/PlugIns/KadeShare.appex": "com.kademurdock.kadeai.share",
           "KadeAI.app/PlugIns/KadeWidgets.appex": "com.kademurdock.kadeai.widgets"}
# XcodeGen materializes these from project.yml; compiled identity is checked below.
GENERATED_PLISTS = {"Sources/Info.plist", "KeyboardExtension/Info.plist",
                    "ShareExtension/Info.plist", "WidgetExtension/Info.plist"}


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def validate_scope(expected, event, environment, head, remote):
    repository = event.get("repository", {})
    require(re.fullmatch(r"[0-9a-f]{40}", expected) is not None and head == expected,
            "Expected source SHA must match the checked-out commit")
    require(repository.get("private") is False and repository.get("full_name") == REPOSITORY
            and environment.get("GITHUB_REPOSITORY") == REPOSITORY
            and environment.get("GITHUB_REF") == "refs/heads/" + BRANCH
            and environment.get("GITHUB_EVENT_NAME") == "push"
            and environment.get("GITHUB_SHA") == expected and event.get("after") == expected
            and event.get("deleted") is False and environment.get("RUNNER_OS") == "macOS"
            and environment.get("DEVELOPER_DIR") == XCODE
            and remote in {"https://github.com/" + REPOSITORY + ".git",
                           "https://github.com/" + REPOSITORY}, "Exact public CI/source scope failed")


def model_count(output):
    matches = re.findall(r"^([^\n]+): (\d+) (?:additional )?checks passed$", output, re.M)
    require(len(matches) == len(MODEL_GROUPS) and {label for label, _ in matches} == MODEL_GROUPS
            and all(int(count) > 0 for _, count in matches),
            "All existing character and routing model result groups must complete")
    count = sum(int(count) for _, count in matches)
    require(count == EXPECTED_MODEL_CHECKS, "Exact character/routing model count changed")
    return {"passed": True, "checks": count, "groups": len(matches)}


def macho_device(path):
    # Check the actual arm64 executable, including its iOS platform load command.
    with path.open("rb") as stream:
        header = stream.read(32)
        require(len(header) == 32, "Missing Mach-O header")
        magic, cpu, _, file_type, commands, byte_count, _, _ = struct.unpack("<8I", header)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C and file_type == 2 and 0 < commands < 2048
                and 0 < byte_count <= 4 * 1024 * 1024, "Expected bounded arm64 Mach-O executable")
        data = stream.read(byte_count)
    require(len(data) == byte_count, "Truncated Mach-O load commands")
    offset, platforms = 0, []
    for _ in range(commands):
        require(offset + 8 <= len(data), "Truncated Mach-O command")
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= len(data), "Invalid Mach-O command size")
        require(command != 0x1D, "Executable contains LC_CODE_SIGNATURE")
        if command == 0x32:
            require(size >= 24, "Truncated LC_BUILD_VERSION")
            platforms.append(struct.unpack_from("<I", data, offset + 8)[0])
        offset += size
    require(offset == byte_count and platforms == [2], "Executable must target device iOS, not simulator")
    return {"architecture": "arm64", "platform": "iOS", "codeSignatureLoadCommand": False}


def bundle_metadata(bundle, identifier, extension):
    require(bundle.is_dir() and not bundle.is_symlink(), "Expected real app/extension bundle")
    plist_path = bundle / "Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    require(info.get("CFBundleIdentifier") == identifier
            and info.get("CFBundleShortVersionString") == VERSION
            and str(info.get("CFBundleVersion")) == "100"
            and info.get("CFBundlePackageType") == ("XPC!" if extension else "APPL")
            and info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"]
            and info.get("DTPlatformName") == "iphoneos", "Compiled bundle identity/platform/type changed")
    name = info.get("CFBundleExecutable")
    require(isinstance(name, str) and name and Path(name).name == name
            and not (bundle / name).is_symlink() and (bundle / name).is_file(), "Invalid bundle executable")
    require(not (bundle / "_CodeSignature").exists()
            and not (bundle / "embedded.mobileprovision").exists(), "Signing/provisioning material is present")
    native = macho_device(bundle / name)
    return {"bundleId": identifier, "version": info["CFBundleShortVersionString"], "build": "100",
            "packageType": info["CFBundlePackageType"], "executable": name,
            "infoPlistSha256": digest(plist_path), "executableSha256": digest(bundle / name),
            "executableBytes": (bundle / name).stat().st_size, "unsigned": True, **native}


def catalog_metadata(records):
    require(isinstance(records, list) and all(isinstance(row, dict) for row in records),
            "Native assetutil must emit a catalog record array")
    matches = [row for row in records if row.get("Name") == ASSET_NAME]
    require(matches and all(row.get("AssetType") == "Image" and row.get("PixelWidth") == 1254
                            and row.get("PixelHeight") == 1254 for row in matches),
            "Compiled Della master image/name/1254-square dimensions are missing or changed")
    images = {}
    for name,pixels in CAST_IMAGES.items():
        found = [row for row in records if row.get('Name') == name]
        require(found and all(row.get('AssetType') == 'Image'
                and type(row.get('PixelWidth')) is int and type(row.get('PixelHeight')) is int
                and (row['PixelWidth'],row['PixelHeight']) == pixels for row in found),
                'Compiled all-cast image/name/dimensions are missing or changed: '+name)
        images[name] = {'pixels':list(pixels),'matchingRenditions':len(found)}
    data = [row for row in records if row.get('Name') == CAST_DATA]
    require(data and all(row.get('AssetType') == 'Data' for row in data),
            'Compiled Angel vector data asset is missing or changed')
    return {"passed": True, "name": ASSET_NAME, "pixels": [1254, 1254],
            "catalogRecords": len(records), "matchingImageRenditions": len(matches),
            'requiredImages':images,'requiredDataAssets':[CAST_DATA]}


class Runner:
    def __init__(self, started, folder, receipt):
        self.deadline = started + OPERATION_SECONDS
        self.folder, self.receipt = folder, receipt

    def run(self, name, arguments, seconds=30, cap=1024 * 1024, allowed=(0,)):
        budget = min(seconds, self.deadline - time.time())
        require(budget > 0, "Shared operation deadline expired")
        path = self.folder / (name + ".log")
        started = time.monotonic()
        timed_out = overflow = False
        with path.open("wb") as output:
            process = subprocess.Popen(arguments, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            while process.poll() is None:
                timed_out = time.monotonic() - started >= budget
                overflow = path.stat().st_size > cap
                if timed_out or overflow:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass  # Child exited between poll and kill; still retain failure/wait evidence.
                    break
                time.sleep(0.2)
            process.wait(timeout=5)
        timed_out = timed_out or time.monotonic() - started > budget
        overflow = overflow or path.stat().st_size > cap
        record = {"name": name, "timeoutSeconds": round(budget, 3),
                  "elapsedSeconds": round(time.monotonic() - started, 3), "exitCode": process.returncode,
                  "timedOut": timed_out, "outputLimitExceeded": overflow,
                  "logBytes": path.stat().st_size, "logSha256": digest(path),
                  "passed": process.returncode in allowed and not timed_out and not overflow}
        self.receipt["operations"].append(record)
        if not record["passed"]:
            with path.open("rb") as stream:
                stream.seek(max(0, record["logBytes"] - 12000))
                print(stream.read(12000).decode("utf-8", errors="replace"), flush=True)
            raise ValueError("Bounded operation failed: " + name)
        return path

    def text(self, name, arguments, **options):
        return self.run(name, arguments, **options).read_text(encoding="utf-8").strip()

    def snapshot(self, names):
        inputs = {name: digest(ROOT / name) for name in names if name not in GENERATED_PLISTS}
        packed = json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()
        return inputs, hashlib.sha256(packed).hexdigest()


def verify(expected, receipt):
    require(sys.platform == "darwin", "This proof requires the actual macOS/Xcode CI runner")
    started = int(os.environ["KADE_DEVICE_STARTED_EPOCH"])
    require(0 <= time.time() - started < OPERATION_SECONDS, "Invalid shared operation start")
    temporary = Path(os.environ["RUNNER_TEMP"])
    folder = temporary / "puppet-production-device-proof"
    folder.mkdir(exist_ok=False)
    runner = Runner(started, folder, receipt)
    head = runner.text("git-head", ["git", "rev-parse", "HEAD"])
    remote = runner.text("git-remote", ["git", "remote", "get-url", "origin"])
    validate_scope(expected, json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()),
                   os.environ, head, remote)
    runner.run("git-clean", ["git", "diff-index", "--quiet", "HEAD", "--"])
    names = runner.text("git-inputs", ["git", "ls-files", "-z"]).split("\0")
    names = [name for name in names if name]
    require("dev/verify-puppet-production-device.py" in names
            and ".github/workflows/puppet-production-device-verify.yml" in names,
            "The lane itself must be committed in the exact source")
    inputs, source_digest = runner.snapshot(names)
    receipt["source"] = {"sha": expected, "tree": runner.text("git-tree", ["git", "rev-parse", "HEAD^{tree}"]),
                         "repository": REPOSITORY, "branch": BRANCH, "trackedInputs": len(inputs),
                         "inputSha256": source_digest, "generatedPlists": sorted(GENERATED_PLISTS),
                         "artBlobs": sum(Path(name).suffix.lower() in {".png", ".jpg", ".jpeg", ".svg"}
                                         for name in inputs), "operationStartedEpoch": started,
                         "operationDeadlineEpoch": started + OPERATION_SECONDS}
    require(runner.text("xcode-version", ["xcodebuild", "-version"]).splitlines()[0] == "Xcode 26.4.1",
            "Fixed Xcode 26.4.1 is required")
    art = json.loads(runner.text("registered-art", ["python3", "-B", "dev/prepare-puppet-review.py", "--check"]))
    require(art.get("bundled") is True and art.get("staged") is False and len(art.get("verified", [])) == 8,
            "Eight immutable registered assets must pass")
    master = json.loads(runner.text("della-master", ["python3", "-B", "dev/prepare-della-articulated-review.py"]))
    require(master.get("productionRegistered") is True and master.get("sourceSHA256") == MASTER_SHA,
            "Registered immutable Della master must pass")
    runner.run("art-words", ["python3", "-B", "dev/art-check.py"])
    angel = json.loads(runner.text("angel-vector", ["python3", "-B", "dev/validate-angel-vector.py"]))
    require(angel.get("passed") is True, "Immutable Angel vector guard failed")
    receipt["art"] = {"passed": True, "registeredAssets": 8, "dellaMasterSha256": MASTER_SHA,
                      "angelVectorSha256": angel["sourceSHA256"]}
    receipt["models"] = model_count(runner.text("character-routing-models", ["bash", "run-character-tests.sh"],
                                                seconds=180, cap=2 * 1024 * 1024))
    speech = runner.text("speech-playback-policies", ["bash", "run-speech-tests.sh"], seconds=90)
    speech_counts = re.findall(r"Speech pipeline — (\d+) checks", speech)
    require(len(speech_counts) == 1 and "all green" in speech, "Speech playback policies must complete")
    receipt["speechPlaybackPolicies"] = {"passed": True, "checks": int(speech_counts[0])}
    voice_checks = runner.text("narration-voice-retention", ["bash", "run-narration-voice-tests.sh"], seconds=120)
    require("Narration voice retention: 7 checks passed" in voice_checks
            and "Voice catalog replacement and recovery: 12 checks passed" in voice_checks,
            "Voice retention and catalog refresh checks must both complete")
    receipt["narrationVoiceRetention"] = {"passed": True, "checks": 7}
    receipt["voiceCatalogRefresh"] = {"passed": True, "checks": 12}
    if shutil.which("xcodegen") is None:
        runner.run("install-xcodegen", ["brew", "install", "xcodegen"], seconds=180, cap=4 * 1024 * 1024)
    runner.run("generate-project", ["xcodegen", "generate"])
    derived = folder / "DerivedData"
    runner.run("release-device-build", ["xcodebuild", "-jobs", "2", "-project", "KadeAI.xcodeproj",
               "-scheme", "KadeAI", "-configuration", "Release", "-sdk", "iphoneos",
               "-destination", "generic/platform=iOS", "-derivedDataPath", str(derived),
               "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
               "DEVELOPMENT_TEAM=", "build"], seconds=1200, cap=32 * 1024 * 1024)
    receipt["compile"] = {"passed": True, "configuration": "Release", "sdk": "iphoneos",
                          "destination": "generic/platform=iOS", "signingAllowed": False}
    products = derived / "Build/Products/Release-iphoneos"
    plugins = products / "KadeAI.app/PlugIns"
    require({item.name for item in plugins.glob("*.appex")} == {"KadeKeyboard.appex", "KadeShare.appex", "KadeWidgets.appex"},
            "Exactly three expected extensions must be embedded")
    for index, (name, identifier) in enumerate(BUNDLES.items()):
        bundle = products / name
        metadata = bundle_metadata(bundle, identifier, name.endswith(".appex"))
        unsigned = runner.text("unsigned-bundle-" + str(index), ["codesign", "-d", str(bundle)], allowed=(1,))
        require("code object is not signed at all" in unsigned, "Native codesign did not confirm unsigned bundle")
        receipt["bundles"][name] = metadata
    catalog = products / "KadeAI.app/Assets.car"
    require(catalog.is_file() and catalog.stat().st_size > 0, "Compiled asset catalog is missing")
    tool = shutil.which("assetutil")
    if tool is None and Path("/usr/bin/assetutil").is_file():
        tool = "/usr/bin/assetutil"
    if tool is None:
        lookup = runner.text("find-assetutil", ["xcrun", "--find", "assetutil"], allowed=(0, 1, 72))
        if Path(lookup).is_file() and os.access(lookup, os.X_OK):
            tool = lookup
    require(tool is not None, "Native assetutil unavailable; compiled Della inclusion remains unverified")
    records = json.loads(runner.text("compiled-catalog", [tool, "--info", str(catalog)],
                                    seconds=30, cap=16 * 1024 * 1024))
    receipt["catalog"] = {**catalog_metadata(records), "tool": tool,
                           "assetsCarSha256": digest(catalog), "assetsCarBytes": catalog.stat().st_size}
    final_inputs, final_digest = runner.snapshot(names)
    require(final_inputs == inputs and final_digest == source_digest, "Tracked inputs changed during verification")
    require(runner.text("final-git-head", ["git", "rev-parse", "HEAD"]) == expected, "Source commit changed during verification")
    receipt["source"]["inputsUnchanged"] = True
    receipt["passed"] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-sha", required=True)
    arguments = parser.parse_args()
    receipt = {"schema": "kade.puppet-production-device-proof.v2", "expectedSource": arguments.expected_sha,
               "passed": False, "unsignedDeviceCompileOnly": True, "physicalPhoneVerified": False,
               "batteryPerformanceVerified": False, "physicalVoiceOverVerified": False,
               "runtimeAcceptance": False, "releasePublished": False, "artifactsUploaded": False,
               "operationTimeoutSeconds": OPERATION_SECONDS, "operations": [], "bundles": {},
               "compile": {"passed": False}, "catalog": {"passed": False}}
    began = time.time()
    try:
        verify(arguments.expected_sha, receipt)
    except Exception as error:
        receipt["errorType"], receipt["error"] = type(error).__name__, str(error)[:800]
    receipt["finishedAtUtc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    receipt["elapsedSeconds"] = round(time.time() - began, 3)
    print("KADE_PUPPET_DEVICE_RECEIPT " + json.dumps(receipt, sort_keys=True, separators=(",", ":")), flush=True)
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
