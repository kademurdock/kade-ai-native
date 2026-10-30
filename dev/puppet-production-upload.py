"""Prepare a guarded manual, upload-only signing lane using CLI tools0.70.0.

Official command contracts: https://docs.codemagic.io/knowledge-codemagic/codemagic-cli-tools/
and https://github.com/codemagic-ci-cd/cli-tools/tree/v0.70.0/docs .
Tool/source revisions remain independent. Never create certificates, profiles or
keys; never submit/cancel review, distribute beta groups or edit notifications.
No raw signing logs or cloud artifacts. An uncertain upload needs Apple-side
reconciliation before a new dispatch; ephemeral IPA bytes are not retained.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import time
import uuid
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile

TOOLS = Path(__file__).resolve().parents[1]
REPOSITORY = "kademurdock/kade-ai-native"
PRODUCTION = "claude/release-device-20261016"
HOST_BRANCH = "claude/release-host-20261016"
XCODE = "/Applications/Xcode_26.4.1.app/Contents/Developer"
TEAM = "JQPWZ2RL9P"
VERSION = "2.2.17"
APPLE_APP_ID = "6791024001"
CLI_VERSION = "0.70.0"
CAST_IMAGES = {
    'CharacterDellaArticulatedReview':(1254,1254),'CharacterDellaBustBody':(1254,1254),'CharacterDellaBustMask':(1254,1254),
    'CharacterHarleyBustBody':(1024,1536),'CharacterHarleyBustMask':(1254,1254),
    'CharacterHarleyFaces':(1254,1254),'CharacterHarleyMouths':(1254,1254),'CharacterHarleyNuance':(1254,1254),
    'CharacterKianaFaces':(1254,1254),'CharacterKianaMouths':(1254,1254),'CharacterKianaNuance':(1254,1254),
    'CharacterLillyBustBody':(1254,1254),'CharacterLillyFaces':(1254,1254),'CharacterLillyMouths':(1254,1254),'CharacterLillyNuance':(1254,1254),
    'CharacterWitherspoonBustBody':(1024,1536),'CharacterWitherspoonFaces':(1254,1254),'CharacterWitherspoonMouths':(1254,1254),
}
CAST_DATA = 'CharacterAngelVectorArt'
FAMILY_CERT_SHA256 = "204a2f30ebd65d84987704393bc972b750009d4690a10ff132f10fdf4886785d"
FAMILY_SPKI_SHA256 = "fbaa89a5aae82c6ad496e471bfa1afb9db2f03850941cb322e741165840294c3"
PROFILE_IDS = {"com.kademurdock.kadeai": "RG74TP8255", "com.kademurdock.kadeai.keyboard": "52LRHX7PMA",
               "com.kademurdock.kadeai.share": "589T68NL92", "com.kademurdock.kadeai.widgets": "A9ZZX36PD2"}
GENERATED_PLISTS = {"Sources/Info.plist", "KeyboardExtension/Info.plist", "ShareExtension/Info.plist", "WidgetExtension/Info.plist"}
LIMIT = 1980  # Shared33 minutes, with2 minutes left inside the35-minute job.
BUNDLES = {"KadeAI.app": "com.kademurdock.kadeai",
           "KadeAI.app/PlugIns/KadeKeyboard.appex": "com.kademurdock.kadeai.keyboard",
           "KadeAI.app/PlugIns/KadeShare.appex": "com.kademurdock.kadeai.share",
           "KadeAI.app/PlugIns/KadeWidgets.appex": "com.kademurdock.kadeai.widgets"}
CREDENTIALS = {"KADE_FAMILY_CERT_KEY_BASE64", "KADE_ASC_ISSUER_ID", "KADE_ASC_KEY_ID", "KADE_ASC_PRIVATE_KEY_PEM"}


class ControlledError(ValueError):
    pass


def require(value, message):
    if not value:
        raise ControlledError(message)


def archive_failure_codes(raw):
    """Return only fixed codes/booleans; matched signing text never leaves memory."""
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw.decode("utf-8", errors="replace"))
    patterns = {
        "provisioning-profile-missing": r"no (?:matching )?profiles? for|requires a provisioning profile|no matching provisioning profiles",
        "provisioning-profile-mismatch": r"provisioning profile[^\n]*(?:does not|doesn't) (?:include|match|support)",
        "signing-identity-missing": r"no signing certificate|no code signing identity found|could not find a signing identity",
        "signing-key-access": r"errSecInternalComponent|user interaction is not allowed|unable to build chain to self-signed root",
        "signing-error": r"(?:codesign|code signing)[^\n]*(?:failed|error)",
        "entitlements-mismatch": r"(?:error:[^\n]*entitlements?|entitlements?[^\n]*(?:does not|doesn't|mismatch))",
        "compiler-error": r"\.(?:swift|m|mm|c|cc|cpp|h):\d+(?::\d+)?:\s*error:|(?:SwiftCompile|CompileSwift)[^\n]*failed",
        "linker-error": r"undefined symbols|linker command failed|ld: [^\n]*(?:error|not found)",
        "resource-error": r"(?:actool|ibtool)[^\n]*error:|CompileAssetCatalog[^\n]*failed",
        "sdk-destination-error": r"unable to find a destination matching|SDK[^\n]*(?:cannot be located|not found)",
        "build-settings-error": r"invalid option|unrecognized option|unknown build action",
        "script-error": r"command PhaseScriptExecution failed",
        "export-error": r"error: exportArchive|failed to export archive",
    }
    categories = sorted(code for code, pattern in patterns.items() if re.search(pattern, text, re.IGNORECASE))
    # Fixed phrases from codemagic0.70.0 XcodeProject.build_ipa/Xcodebuild;
    # these are diagnostic observations, never artifact or upload proof.
    stages = {"archiveStarted": r"^\s*Archive .+$", "archiveCompleted": r"^\s*Successfully created archive at ",
              "exportStarted": r"^\s*Export .+ to .+$", "exportCompleted": r"^\s*Successfully exported ipa to ",
              "archiveFailureReported": r"Failed to archive |\*\* ARCHIVE FAILED \*\*",
              "exportFailureReported": r"Failed to export archive |\*\* EXPORT FAILED \*\*"}
    return {"categories": categories or ["unknown"],
            **{key: bool(re.search(pattern, text, re.MULTILINE)) for key, pattern in stages.items()}}


def archive_failure_diagnostic(path, operation, receipt):
    limit, raw = 2 * 1024 * 1024, b""
    try:
        with path.open("rb") as stream:
            if operation["logBytes"] > limit:
                raw = stream.read(limit // 2)
                stream.seek(-limit // 2, os.SEEK_END)
                raw += stream.read(limit // 2)
            else:
                raw = stream.read(limit)
    except OSError:
        pass  # Preserve the original false operation without exposing exception text.
    scope = {key: value if isinstance(value, str) and re.fullmatch(r"[a-f0-9]{40}", value) else None
             for key, value in (("sourceCommit", receipt.get("sourceCommit")), ("toolCommit", receipt.get("toolCommit")))}
    run = os.environ.get("GITHUB_RUN_ID", "")
    return {"schema": "kade.archive-failure-diagnostics.v1", "operation": "signed-archive-and-ipa", "passed": False,
            **scope, "githubRunId": run if re.fullmatch(r"[1-9][0-9]{0,19}", run) else None,
            **{key: operation[key] for key in ("exitCode", "timedOut", "outputLimitExceeded", "logBytes", "logSha256")},
            "scanBytes": len(raw), "scanTruncated": len(raw) < operation["logBytes"], **archive_failure_codes(raw)}


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def work():
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve()
    raw = temporary / "puppet-approved-upload"
    require(not raw.is_symlink(), "Ephemeral signing directory must not be a symlink")
    folder = raw.resolve()
    require(folder.parent == temporary, "Invalid ephemeral signing directory")
    return folder


def scope(expected, event, environment):
    require(re.fullmatch(r"[0-9a-f]{40}", expected) is not None, "An exact production SHA is required")
    repository, inputs = event.get("repository", {}), event.get("inputs", {})
    require(repository.get("private") is False and repository.get("full_name") == REPOSITORY
            and environment.get("GITHUB_REPOSITORY") == REPOSITORY
            and environment.get("GITHUB_REPOSITORY_OWNER") == "kademurdock"
            and environment.get("GITHUB_ACTOR") == environment.get("GITHUB_TRIGGERING_ACTOR") == "kademurdock"
            and environment.get("GITHUB_REF") == "refs/heads/main"
            and environment.get("GITHUB_WORKFLOW_REF") == REPOSITORY + "/.github/workflows/puppet-production-upload.yml@refs/heads/main"
            and environment.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and environment.get("GITHUB_RUN_ATTEMPT") == "1"
            and environment.get("RUNNER_OS") == "macOS"
            and environment.get("DEVELOPER_DIR") == XCODE
            and environment.get("KADE_UPLOAD_CONFIRMED") == "true"
            and (inputs.get("upload") is True or isinstance(inputs.get("upload"), str) and inputs["upload"] == "true")
            and inputs.get("expected_sha") == expected,
            "Exact owner/public/manual-dispatch scope failed")
    for key, variable in (("native_host_run_id", "KADE_HOST_PROOF_RUN"),
                          ("unsigned_device_run_id", "KADE_DEVICE_PROOF_RUN")):
        require(re.fullmatch(r"[1-9][0-9]{0,19}", environment.get(variable, "")) is not None
                and inputs.get(key) == environment[variable], "Exact proof run IDs are required")
    require(re.fullmatch(r"[0-9a-f]{64}", environment.get("KADE_FAMILY_CERT_SHA256", "")) is not None
            and environment["KADE_FAMILY_CERT_SHA256"] == FAMILY_CERT_SHA256
            and inputs.get("family_certificate_sha256") == environment["KADE_FAMILY_CERT_SHA256"],
            "Approved existing family certificate fingerprint is required")


class Runner:
    def __init__(self, folder, receipt, source):
        self.folder, self.receipt, self.source = folder, receipt, source
        self.deadline = int(os.environ["KADE_UPLOAD_STARTED_EPOCH"]) + LIMIT

    def run(self, name, command, seconds=30, cap=1024 * 1024, cwd=None, credentials=False):
        budget = min(seconds, self.deadline - time.time())
        require(budget > 0, "Shared operation deadline expired")
        path, started = self.folder / (name + ".log"), time.monotonic()
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("APP_STORE_CONNECT_", "CERTIFICATE_PRIVATE_KEY", "XCODE_PROJECT_"))
                       and (credentials or key not in CREDENTIALS)}
        timed_out = overflow = False
        with path.open("wb") as stream:
            process = subprocess.Popen(command, cwd=cwd or self.source, env=environment,
                                       stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            while process.poll() is None:
                timed_out, overflow = time.monotonic() - started >= budget, path.stat().st_size > cap
                if timed_out or overflow:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    break
                time.sleep(0.2)
            process.wait(timeout=5)
        timed_out = timed_out or time.monotonic() - started > budget
        overflow = overflow or path.stat().st_size > cap
        record = {"name": name, "exitCode": process.returncode, "timedOut": timed_out,
                  "outputLimitExceeded": overflow, "elapsedSeconds": round(time.monotonic() - started, 3),
                  "timeoutSeconds": round(budget, 3), "logBytes": path.stat().st_size,
                  "logSha256": sha(path), "passed": process.returncode == 0 and not timed_out and not overflow}
        self.receipt["operations"].append(record)
        if name == "signed-archive-and-ipa" and not record["passed"]:
            print("KADE_ARCHIVE_FAILURE_DIAGNOSTIC " + json.dumps(
                archive_failure_diagnostic(path, record, self.receipt), sort_keys=True, separators=(",", ":")), flush=True)
        # Never echo signing output, environment dumps, profiles or private material.
        require(record["passed"], "Bounded operation failed: " + name)
        return path

    def text(self, name, command, **options):
        return self.run(name, command, **options).read_text(encoding="utf-8").strip()

    def inputs(self, excluded=()):
        names = self.text("source-input-list", ["git", "ls-files", "-z"]).split("\0")
        data = {name: sha(self.source / name) for name in names if name and name not in excluded}
        return len(data), hashlib.sha256(json.dumps(data, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def github(self, path):
        require(path.startswith("/repos/" + REPOSITORY + "/"), "Unexpected GitHub proof endpoint")
        request = Request("https://api.github.com" + path, headers={"Accept": "application/vnd.github+json",
                          "Authorization": "Bearer " + os.environ["GH_TOKEN"], "X-GitHub-Api-Version": "2022-11-28"})
        budget = min(30, self.deadline - time.time())
        require(budget > 0, "Proof request deadline expired")
        class NoRedirect(HTTPRedirectHandler):
            def redirect_request(self, request, file, code, message, headers, url):
                return None
        with build_opener(NoRedirect).open(request, timeout=budget) as response:
            require(response.url.startswith("https://api.github.com/repos/" + REPOSITORY + "/"),
                    "GitHub proof request unexpectedly redirected")
            raw = response.read(2 * 1024 * 1024 + 1)
        require(len(raw) <= 2 * 1024 * 1024, "GitHub proof response exceeded bound")
        return json.loads(raw)


def proof(run, jobs, expected, branch, workflow, job_name, steps):
    require(run.get("head_sha") == expected and run.get("head_branch") == branch and run.get("event") == "push"
            and run.get("path") == ".github/workflows/" + workflow
            and run.get("status") == "completed" and run.get("conclusion") == "success"
            and run.get("repository", {}).get("full_name") == REPOSITORY
            and run.get("repository", {}).get("private") is False
            and run.get("head_repository", {}).get("full_name") == REPOSITORY
            and run.get("head_repository", {}).get("private") is False,
            "Exact source-bound proof run did not succeed")
    rows = jobs.get("jobs", [])
    require(jobs.get("total_count") == 1 and len(rows) == 1, "Expected exactly one genuine proof job")
    job = rows[0]
    require(job.get("name") == job_name and job.get("head_sha") == expected and job.get("run_id") == run["id"]
            and job.get("status") == "completed" and job.get("conclusion") == "success"
            and "macos-26" in job.get("labels", []) and "self-hosted" not in job.get("labels", [])
            and job.get("runner_id", 0) > 0, "Actual standard-runner proof job did not succeed")
    actual = job.get("steps", [])
    for name in steps:
        matched = [step for step in actual if step.get("name") == name]
        require(len(matched) == 1 and matched[0].get("status") == "completed"
                and matched[0].get("conclusion") == "success" and matched[0].get("started_at")
                and matched[0].get("completed_at"), "Required proof step was skipped or failed: " + name)
    return {"runId": run["id"], "attempt": run["run_attempt"], "jobId": job["id"],
            "source": expected, "workflow": workflow, "branch": branch, "successfulSteps": len(steps)}


def gate(source, receipt):
    expected = os.environ["KADE_EXPECTED_COMMIT"]
    scope(expected, json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8")), os.environ)
    folder = work()
    folder.mkdir(exist_ok=False)
    runner = Runner(folder, receipt, source)
    tool_sha = runner.text("tool-head", ["git", "rev-parse", "HEAD"], cwd=TOOLS)
    require(tool_sha == os.environ["KADE_TOOL_COMMIT"] == os.environ["GITHUB_SHA"]
            and re.fullmatch(r"[0-9a-f]{40}", tool_sha) is not None, "Trusted signing tool checkout drifted")
    runner.run("tool-clean", ["git", "diff-index", "--quiet", "HEAD", "--"], cwd=TOOLS)
    require(runner.text("app-head", ["git", "rev-parse", "HEAD"]) == expected, "Production checkout SHA drifted")
    runner.run("app-clean", ["git", "diff-index", "--quiet", "HEAD", "--"])
    tip = runner.github("/repos/" + REPOSITORY + "/git/ref/heads/" + PRODUCTION)
    require(tip.get("object", {}).get("sha") == expected, "Approved source is not the exact production branch head")
    records = []
    for variable, branch, workflow, name in (("KADE_HOST_PROOF_RUN", HOST_BRANCH, "della-host-layout-review.yml", "unsigned-review"),
                                             ("KADE_DEVICE_PROOF_RUN", PRODUCTION, "puppet-production-device-verify.yml", "unsigned-release-device")):
        run_id = os.environ[variable]
        run = runner.github("/repos/" + REPOSITORY + "/actions/runs/" + run_id)
        require(str(run.get("id")) == run_id and isinstance(run.get("run_attempt"), int)
                and 0 < run["run_attempt"] < 100, "Proof run/attempt binding changed")
        jobs = runner.github("/repos/" + REPOSITORY + "/actions/runs/" + run_id + "/attempts/"
                             + str(run["run_attempt"]) + "/jobs?per_page=100")
        document = (source / ".github/workflows" / workflow).read_text(encoding="utf-8")
        steps = re.findall(r"^\s+- name: ([^\n]+)$", document, re.M)
        require(len(steps) >= (18 if branch == HOST_BRANCH else 3)
                and len(steps) == len(set(steps)), "Frozen proof step contract is missing")
        if branch == HOST_BRANCH:
            require(all("id: " + value in document for value in ("ui-large", "ui-small", "native-ui-results", "completion-boot", "completion-ui", "completion-capture", "host-capture")),
                    "Complete native UI/capture gates must be present in proved source")
        records.append(proof(run, jobs, expected, branch, workflow, name, steps))
    count, source_digest = runner.inputs()
    immutable_count, immutable_digest = runner.inputs(GENERATED_PLISTS)
    tracked_plists = set(runner.text("tracked-generated-plists", ["git", "ls-files", "-z", "--", *sorted(GENERATED_PLISTS)]).split("\0"))
    receipt.update({"passed": True, "sourceCommit": expected, "toolCommit": tool_sha,
                    "sourceInputCount": count, "sourceInputSha256": source_digest, "proofs": records,
                    "immutableSourceInputCount": immutable_count, "immutableSourceInputSha256": immutable_digest,
                    "generatedPlists": {name: {"originalTracked": name in tracked_plists,
                                              "originalSha256": sha(source / name) if (source / name).is_file() else None}
                                        for name in sorted(GENERATED_PLISTS)},
                    "githubRunId": os.environ["GITHUB_RUN_ID"], "operationStartedEpoch": int(os.environ["KADE_UPLOAD_STARTED_EPOCH"]),
                    "familyCertificateSha256": os.environ["KADE_FAMILY_CERT_SHA256"]})
    (folder / "gate.json").write_text(json.dumps(receipt), encoding="utf-8")


def profile(info, identifier, fingerprint):
    expires = info.get("ExpirationDate")
    require(isinstance(expires, datetime), "Existing profile expiration is missing")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    entitlements = info.get("Entitlements", {})
    require(info.get("TeamIdentifier") == [TEAM] and entitlements.get("application-identifier") == TEAM + "." + identifier
            and entitlements.get("get-task-allow") is False and entitlements.get("beta-reports-active") is True
            and not info.get("ProvisionedDevices") and not info.get("ProvisionsAllDevices")
            and expires > datetime.now(timezone.utc)
            and fingerprint in {hashlib.sha256(value).hexdigest() for value in info.get("DeveloperCertificates", [])}
            and isinstance(info.get("UUID"), str) and info["UUID"], "Existing App Store/family profile is unsuitable")
    return {"uuid": info["UUID"], "bundleId": identifier, "expiresUtc": expires.isoformat()}


def signed_bundle(bundle, identifier, build, extension):
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == identifier and info.get("CFBundleShortVersionString") == VERSION
            and str(info.get("CFBundleVersion")) == str(build)
            and info.get("CFBundlePackageType") == ("XPC!" if extension else "APPL")
            and info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"] and info.get("DTPlatformName") == "iphoneos",
            "Signed artifact bundle identity/platform changed")
    name = info.get("CFBundleExecutable")
    require(isinstance(name, str) and Path(name).name == name and name
            and (bundle / "_CodeSignature/CodeResources").is_file()
            and (bundle / "embedded.mobileprovision").is_file(), "Signed executable/profile material missing")
    with (bundle / name).open("rb") as binary:
        header = binary.read(32)
        require(len(header) == 32, "Truncated signed Mach-O")
        magic, cpu, _, kind, commands, size, _, _ = struct.unpack("<8I", header)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C and kind == 2 and 0 < commands < 2048
                and 0 < size <= 4 * 1024 * 1024, "Expected signed arm64 executable")
        data = binary.read(size)
    offset, platforms, signatures = 0, [], 0
    for _ in range(commands):
        require(offset + 8 <= len(data), "Truncated signed Mach-O load command")
        command, length = struct.unpack_from("<II", data, offset)
        require(length >= 8 and offset + length <= len(data), "Invalid signed load command")
        if command == 0x32:
            require(length >= 24, "Truncated signed platform command")
            platforms.append(struct.unpack_from("<I", data, offset + 8)[0])
        if command == 0x1D:
            require(length == 16 and struct.unpack_from("<I", data, offset + 12)[0] > 0, "Empty code signature")
            signatures += 1
        offset += length
    require(offset == size and platforms == [2] and signatures == 1, "Signed binary must target actual device iOS")
    return {"bundleId": identifier, "version": VERSION, "build": str(build), "architecture": "arm64", "platform": "IOS",
            "infoPlistSha256": sha(bundle / "Info.plist"), "executableSha256": sha(bundle / name)}


def asc_leaf(key_id):
    require(re.fullmatch(r"[A-Za-z0-9]{10}", key_id) is not None, "Invalid approved ASC key identifier")
    home = Path.home().resolve()
    raw = home / ".private_keys"
    require(not raw.is_symlink() and raw.resolve().parent == home, "Invalid native altool key directory")
    leaf = raw / ("AuthKey_" + key_id + ".p8")
    require(not leaf.is_symlink() and leaf.resolve().parent == raw.resolve(), "Invalid native altool key leaf")
    return leaf


def register_asc_leaf(folder):
    key_id = os.environ["KADE_ASC_KEY_ID"]
    leaf = asc_leaf(key_id)
    # The pinned altool helper would overwrite this path; protect any prior file.
    require(not leaf.exists(), "A preexisting ASC key file must be preserved")
    marker = {"schema": "kade.job-owned-asc-key.v1", "keyId": key_id,
              "githubRunId": os.environ["GITHUB_RUN_ID"], "preexisting": False}
    (folder / "owned-asc-key.json").write_text(json.dumps(marker), encoding="utf-8")


def cleanup_asc_leaf(folder):
    marker_path = folder / "owned-asc-key.json"
    require(not marker_path.is_symlink(), "Invalid owned ASC key marker")
    if not marker_path.exists():
        return
    marker = json.loads(marker_path.read_text(encoding="utf-8"))
    require(marker.get("schema") == "kade.job-owned-asc-key.v1" and marker.get("preexisting") is False
            and marker.get("githubRunId") == os.environ["GITHUB_RUN_ID"], "Fresh exact ASC key ownership is required")
    asc_leaf(marker["keyId"]).unlink(missing_ok=True)
    marker_path.unlink()


def profile_destination_root():
    # Codemagic0.70 ProvisioningProfile.DEFAULT_LOCATION, for Xcode16+.
    root = Path.home()
    require(not root.is_symlink() and root.is_dir(), "Invalid native profile home")
    for name in ("Library", "Developer", "Xcode", "UserData", "Provisioning Profiles"):
        root = root / name
        require(not root.is_symlink(), "Native profile directory must not be a symlink")
        root.mkdir(exist_ok=True)
        require(root.is_dir(), "Native profile directory required")
    return root.resolve()


def write_profile_ledger(path, ledger, exclusive=False):
    require(not path.is_symlink(), "Owned profile ledger must not be a symlink")
    temporary = path if exclusive else path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    created = False
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            created = True
            stream.write(json.dumps(ledger, sort_keys=True)); stream.flush(); os.fsync(stream.fileno())
        if not exclusive:
            require(not path.is_symlink() and not temporary.is_symlink()
                    and temporary.resolve().parent == path.resolve().parent, "Confined atomic profile ledger required")
            os.replace(temporary, path)
    finally:
        if not exclusive and created and temporary.exists():
            require(not temporary.is_symlink() and temporary.resolve().parent == path.resolve().parent,
                    "Confined owned ledger temporary required")
            temporary.unlink()


def install_approved_profiles(folder, selected):
    require(set(selected) == set(BUNDLES.values()), "Exactly four approved native profiles required")
    require(len({item[1]["uuid"] for item in selected.values()}) == 4, "Four distinct approved profile UUIDs required")
    require(not (folder / "profiles").is_symlink() and (folder / "profiles").resolve().parent == folder.resolve(),
            "Confined approved profile source directory required")
    destination_root, marker = profile_destination_root(), folder / "owned-native-profiles.json"
    ledger = {"schema": "kade.job-owned-native-profiles.v1", "githubRunId": os.environ["GITHUB_RUN_ID"], "profiles": []}
    write_profile_ledger(marker, ledger, exclusive=True)
    for identifier in BUNDLES.values():
        source, metadata = selected[identifier]
        profile_uuid = metadata["uuid"]
        require(isinstance(profile_uuid, str) and re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", profile_uuid),
                "Canonical approved profile UUID required")
        require(not source.is_symlink() and source.resolve().parent == (folder / "profiles").resolve()
                and source.is_file() and 0 < source.stat().st_size <= 4 * 1024 * 1024,
                "Bounded exact approved profile source required")
        raw = source.read_bytes()
        require(hashlib.sha256(raw).hexdigest() == metadata["sha256"], "Approved profile bytes changed before installation")
        destination = destination_root / (profile_uuid + ".mobileprovision")
        require(not destination.is_symlink() and destination.resolve().parent == destination_root,
                "Confined native profile leaf required")
        with destination.open("xb") as stream:
            owned = os.fstat(stream.fileno())
            entry = {"uuid": profile_uuid, "sha256": metadata["sha256"], "device": owned.st_dev,
                     "inode": owned.st_ino, "complete": False}
            ledger["profiles"].append(entry)
            # Record exact exclusive ownership before copying any profile bytes.
            try:
                write_profile_ledger(marker, ledger)
            except Exception:
                state = destination.stat()
                require(not destination.is_symlink() and (state.st_dev, state.st_ino) == (owned.st_dev, owned.st_ino)
                        and state.st_size == 0, "New empty native profile ownership changed")
                destination.unlink()
                raise
            stream.write(raw); stream.flush(); os.fsync(stream.fileno())
        require(sha(destination) == metadata["sha256"], "Installed native profile bytes differ")
        entry["complete"] = True
        write_profile_ledger(marker, ledger)


def cleanup_native_profiles(folder):
    marker = folder / "owned-native-profiles.json"
    require(not marker.is_symlink(), "Owned native profile marker must not be a symlink")
    if not marker.exists():
        return
    require(marker.stat().st_size <= 16 * 1024, "Owned profile ledger exceeded bound")
    ledger = json.loads(marker.read_text(encoding="utf-8"))
    entries = ledger.get("profiles", [])
    require(set(ledger) == {"schema", "githubRunId", "profiles"} and ledger["schema"] == "kade.job-owned-native-profiles.v1"
            and ledger["githubRunId"] == os.environ["GITHUB_RUN_ID"] and isinstance(entries, list) and len(entries) <= 4,
            "Fresh exact native profile ownership required")
    destination_root = profile_destination_root()
    failures = False
    for entry in entries:
        try:
            require(set(entry) == {"uuid", "sha256", "device", "inode", "complete"}
                    and isinstance(entry["uuid"], str)
                    and re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", entry["uuid"])
                    and re.fullmatch(r"[a-f0-9]{64}", entry["sha256"])
                    and type(entry["device"]) is int and entry["device"] >= 0
                    and type(entry["inode"]) is int and entry["inode"] > 0 and type(entry["complete"]) is bool,
                    "Bounded owned native profile entry required")
            path = destination_root / (entry["uuid"] + ".mobileprovision")
            require(not path.is_symlink() and path.resolve().parent == destination_root, "Confined owned native profile leaf required")
            if path.exists():
                state = path.stat()
                require(path.is_file() and (state.st_dev, state.st_ino) == (entry["device"], entry["inode"])
                        and state.st_size <= 4 * 1024 * 1024, "Native profile ownership changed")
                require(not entry["complete"] or sha(path) == entry["sha256"], "Owned native profile bytes changed")
                path.unlink()  # Only this run's exclusive, inode-bound UUID leaf.
        except Exception:
            failures = True
    require(not failures, "Owned native profile cleanup incomplete")
    marker.unlink()


def sign(source, receipt):
    folder = work()
    prior = json.loads((folder / "gate.json").read_text(encoding="utf-8"))
    require(prior.get("passed") is True and prior.get("sourceCommit") == os.environ["KADE_EXPECTED_COMMIT"]
            and prior.get("toolCommit") == os.environ["KADE_TOOL_COMMIT"]
            and prior.get("githubRunId") == os.environ["GITHUB_RUN_ID"]
            and prior.get("operationStartedEpoch") == int(os.environ["KADE_UPLOAD_STARTED_EPOCH"]), "Fresh proof gate is required")
    receipt.update({key: prior[key] for key in ("sourceCommit", "toolCommit", "sourceInputCount", "sourceInputSha256", "proofs",
                                               "familyCertificateSha256", "immutableSourceInputCount", "immutableSourceInputSha256", "generatedPlists")})
    runner = Runner(folder, receipt, source)
    require(runner.inputs() == (prior["sourceInputCount"], prior["sourceInputSha256"]), "Production source drifted after proof gate")
    require(runner.text("sign-app-head", ["git", "rev-parse", "HEAD"]) == prior["sourceCommit"]
            and runner.text("sign-tool-head", ["git", "rev-parse", "HEAD"], cwd=TOOLS) == prior["toolCommit"], "Source/tool revision drifted")
    require(all(os.environ.get(key) for key in CREDENTIALS), "Approved existing signing credentials are not configured")
    project = (source / "project.yml").read_text(encoding="utf-8")
    require(re.findall(r'MARKETING_VERSION: "([0-9.]+)"', project) == [VERSION] * 4
            and re.findall(r"CURRENT_PROJECT_VERSION: (\d+)", project) == ["100"] * 4, "Proved source identity changed")
    require(runner.text("sign-xcode-version", ["xcodebuild", "-version"]).splitlines()[0] == "Xcode 26.4.1", "Fixed Xcode required")
    environment = folder / "cli-venv"
    runner.run("create-cli-environment", [sys.executable, "-m", "venv", str(environment)])
    runner.run("install-pinned-cli", [str(environment / "bin/python"), "-m", "pip", "install", "--disable-pip-version-check", "--no-cache-dir",
               "codemagic-cli-tools==" + CLI_VERSION], seconds=180, cap=4 * 1024 * 1024)
    cli = lambda name: str(environment / "bin" / name)
    asc = lambda *actions: [cli("app-store-connect"), *actions, "--silent", "--no-color", "--disable-jwt-cache",
                          "--api-unauthorized-retries", "1", "--api-server-error-retries", "1",
                          "--issuer-id", "@env:KADE_ASC_ISSUER_ID", "--key-id", "@env:KADE_ASC_KEY_ID",
                          "--private-key", "@env:KADE_ASC_PRIVATE_KEY_PEM"]
    latest_command = asc("get-latest-build-number") + ["--all-versions", "--platform", "IOS", APPLE_APP_ID]
    latest_text = runner.text("latest-apple-build", latest_command, seconds=45, credentials=True)
    require(re.fullmatch(r"[0-9]{1,9}", latest_text) is not None and int(latest_text) >= 331, "Apple latest build lookup did not complete")
    latest, build = int(latest_text), int(latest_text) + 1
    receipt["generatedBuild"] = {"latestAppleBuild": latest, "build": build, "version": VERSION,
                                 "sourceBuild": 100, "sourceVersion": VERSION}
    key = folder / "family-cert-key.pem"
    encoded_key = "".join(os.environ["KADE_FAMILY_CERT_KEY_BASE64"].split())
    key.write_bytes(base64.b64decode(encoded_key, validate=True))
    key.chmod(0o600)
    certificates, profiles = folder / "certificates", folder / "profiles"
    runner.run("fetch-existing-family", asc("fetch-signing-files") + [BUNDLES["KadeAI.app"], "--type", "IOS_APP_STORE",
                   "--strict-match-identifier", "--certificate-key", "@file:" + str(key),
                   "--certificates-dir", str(certificates), "--profiles-dir", str(profiles)], seconds=90, credentials=True)
    approved_uuids = {}
    for index, (identifier, resource_id) in enumerate(PROFILE_IDS.items()):
        record = json.loads(runner.text("approved-profile-" + str(index), asc("profiles", "get")
                            + [resource_id, "--json", "--save", "--profiles-dir", str(profiles)], credentials=True))
        attrs = record.get("attributes", {})
        require(record.get("id") == resource_id and attrs.get("profileState") == "ACTIVE"
                and attrs.get("profileType") == "IOS_APP_STORE" and attrs.get("platform") == "IOS"
                and isinstance(attrs.get("uuid"), str) and attrs["uuid"], "Approved existing Apple profile changed")
        approved_uuids[identifier] = attrs["uuid"]
    matching = []
    for index, certificate in enumerate(sorted(certificates.glob("*.p12"))):
        require(index < 8, "Existing certificate inventory exceeded bound")
        pem, der = folder / "public-cert.pem", folder / "public-cert.der"
        # CLI 0.70 exports PEM certificate/key bags for its empty-password default,
        # retaining the .p12 suffix. Extract only the public certificate as PEM.
        runner.run("certificate-public-" + str(index), ["openssl", "x509", "-inform", "PEM", "-in", str(certificate), "-outform", "PEM", "-out", str(pem)])
        runner.run("certificate-der-" + str(index), ["openssl", "x509", "-in", str(pem), "-outform", "DER", "-out", str(der)])
        if sha(der) == prior["familyCertificateSha256"]:
            runner.run("certificate-validity-" + str(index), ["openssl", "x509", "-in", str(pem), "-checkend", "0", "-noout"])
            public = runner.run("certificate-public-key-" + str(index), ["openssl", "x509", "-in", str(pem), "-pubkey", "-noout"])
            spki = folder / "public-key.der"
            runner.run("certificate-spki-" + str(index), ["openssl", "pkey", "-pubin", "-in", str(public), "-outform", "DER", "-out", str(spki)])
            require(sha(spki) == FAMILY_SPKI_SHA256, "Existing family public key changed")
            matching.append(certificate)
    require(len(matching) == 1, "Exactly one approved existing family certificate must be available")
    selected, ledger = {}, []
    for index, path in enumerate(sorted(profiles.glob("*.mobileprovision"))):
        require(index < 32, "Existing profile inventory exceeded bound")
        info = plistlib.loads(runner.run("decode-profile-" + str(index), ["security", "cms", "-D", "-i", str(path)]).read_bytes())
        identifier = info.get("Entitlements", {}).get("application-identifier", "").removeprefix(TEAM + ".")
        if identifier not in BUNDLES.values() or info.get("UUID") != approved_uuids.get(identifier):
            continue
        try:
            metadata = profile(info, identifier, prior["familyCertificateSha256"])
        except ValueError:
            continue  # Never select expired/non-family material from the bounded existing inventory.
        if identifier not in selected or metadata["expiresUtc"] > selected[identifier][1]["expiresUtc"]:
            selected[identifier] = (path, {**metadata, "sha256": sha(path), "resourceId": PROFILE_IDS[identifier]})
    require(set(selected) == set(BUNDLES.values()), "Existing family profiles for all four bundles are required")
    ledger = [selected[identifier][1] for identifier in BUNDLES.values()]
    receipt["existingProfiles"] = ledger
    install_approved_profiles(folder, selected)
    keychain = folder / "signing.keychain-db"
    require(not keychain.is_symlink() and keychain.resolve().parent == folder, "Invalid ephemeral keychain path")
    runner.run("initialize-keychain", [cli("keychain"), "initialize", "--path", str(keychain), "--timeout", "2100"])
    runner.run("import-existing-certificate", [cli("keychain"), "add-certificates", "--path", str(keychain), "--certificate", str(matching[0])])
    if shutil.which("xcodegen") is None:
        runner.run("install-xcodegen", ["brew", "install", "xcodegen"], seconds=180, cap=4 * 1024 * 1024)
    runner.run("generate-signing-project", ["xcodegen", "generate"])
    for name in GENERATED_PLISTS:
        receipt["generatedPlists"][name]["xcodegenSha256"] = sha(source / name)
    runner.run("generated-build-number", ["agvtool", "new-version", "-all", str(build)])
    for name in GENERATED_PLISTS:
        generated = source / name
        info = plistlib.loads(generated.read_bytes())
        require(str(info.get("CFBundleVersion")) == str(build), "Generated build number drifted")
        receipt["generatedPlists"][name].update({"generatedSha256": sha(generated), "generatedBuild": str(build),
                                                "versionExpression": str(info.get("CFBundleShortVersionString", ""))})
    export = folder / "export-options.plist"
    command = [cli("xcode-project"), "use-profiles", "--project", "KadeAI.xcodeproj", "--archive-method", "app-store",
               "--export-options-plist", str(export), "--custom-export-options",
               json.dumps({"manageAppVersionAndBuildNumber": False, "uploadSymbols": False, "destination": "export"})]
    # The CLI's nargs='+' replaces earlier occurrences; supply all four paths together.
    command += ["--profile", *(str(selected[identifier][0]) for identifier in BUNDLES.values())]
    runner.run("apply-existing-profiles", command)
    export_info = plistlib.loads(export.read_bytes())
    require(export_info.get("teamID") == TEAM and export_info.get("method") in {"app-store", "app-store-connect"}
            and export_info.get("manageAppVersionAndBuildNumber") is False
            and export_info.get("destination") == "export"
            and set(export_info.get("provisioningProfiles", {})) == set(BUNDLES.values()), "Exact existing-profile export policy changed")
    archives, ipas = folder / "archives", folder / "ipas"
    runner.run("signed-archive-and-ipa", [cli("xcode-project"), "build-ipa", "--project", "KadeAI.xcodeproj", "--scheme", "KadeAI",
               "--config", "Release", "--no-show-build-settings", "--disable-xcpretty", "--archive-directory", str(archives),
               "--ipa-directory", str(ipas), "--export-options-plist", str(export),
               "--archive-flags", shlex.join(["-jobs", "2", "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
                                               "-derivedDataPath", str(folder / "DerivedData")])], seconds=1200, cap=32 * 1024 * 1024)
    artifacts, archive_paths = list(ipas.glob("*.ipa")), list(archives.glob("*.xcarchive"))
    require(len(artifacts) == len(archive_paths) == 1, "Exactly one signed archive/IPA is required")
    ipa = artifacts[0]
    require(0 < ipa.stat().st_size <= 1024 * 1024 * 1024, "Signed IPA size exceeded bound")
    with zipfile.ZipFile(ipa) as package:
        members = package.infolist()
        require(len(members) <= 20000 and sum(item.file_size for item in members) <= 2 * 1024 * 1024 * 1024
                and all(not item.filename.startswith("/") and ".." not in Path(item.filename).parts
                        and (item.external_attr >> 16) & 0o170000 != 0o120000 for item in members), "Unsafe or oversized signed IPA")
    unpacked = folder / "exported-ipa"
    runner.run("unpack-signed-ipa", ["ditto", "-x", "-k", str(ipa), str(unpacked)], seconds=60)
    payload = unpacked / "Payload"
    require({path.name for path in payload.glob("*.app")} == {"KadeAI.app"}, "Unexpected exported application")
    bundles = {}
    catalogs = {}
    tool = shutil.which("assetutil") or ("/usr/bin/assetutil" if Path("/usr/bin/assetutil").is_file() else None)
    if tool is None:
        tool = runner.text("find-assetutil", ["xcrun", "--find", "assetutil"])
    require(tool and Path(tool).is_file(), "Native signed catalog inspection is required")
    for suffix, app in (("archive", archive_paths[0] / "Products/Applications/KadeAI.app"), ("ipa", payload / "KadeAI.app")):
        require({path.name for path in (app / "PlugIns").glob("*.appex")} == {"KadeKeyboard.appex", "KadeShare.appex", "KadeWidgets.appex"},
                "Exactly three signed extensions must be embedded")
        catalog = app / "Assets.car"
        require(catalog.is_file() and catalog.stat().st_size > 0, "Signed compiled catalog is missing")
        rows = json.loads(runner.text("signed-catalog-" + suffix, [tool, "--info", str(catalog)], cap=16 * 1024 * 1024))
        require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows), "Invalid native signed catalog output")
        matches = [row for row in rows if row.get("Name") == "CharacterDellaArticulatedReview"]
        require(matches and all(row.get("AssetType") == "Image" and row.get("PixelWidth") == row.get("PixelHeight") == 1254
                                for row in matches), "Actual signed Della catalog/name/dimensions changed")
        images = {}
        for name,pixels in CAST_IMAGES.items():
            found = [row for row in rows if row.get('Name') == name]
            require(found and all(row.get('AssetType') == 'Image'
                    and type(row.get('PixelWidth')) is int and type(row.get('PixelHeight')) is int
                    and (row['PixelWidth'],row['PixelHeight']) == pixels for row in found),
                    'Actual signed all-cast image/name/dimensions changed: '+name)
            images[name] = {'pixels':list(pixels),'matchingRenditions':len(found)}
        data = [row for row in rows if row.get('Name') == CAST_DATA]
        require(data and all(row.get('AssetType') == 'Data' for row in data),'Actual signed Angel vector data asset missing')
        catalogs[suffix] = {"sha256": sha(catalog), "bytes": catalog.stat().st_size, "matchingRenditions": len(matches),
                            "name": "CharacterDellaArticulatedReview", "pixels": [1254, 1254], "nativeTool": tool,
                            'requiredImages':images,'requiredDataAssets':[CAST_DATA]}
    for index, (name, identifier) in enumerate(BUNDLES.items()):
        for suffix, bundle in (("archive", archive_paths[0] / "Products/Applications" / name), ("ipa", payload / name)):
            metadata = signed_bundle(bundle, identifier, build, name.endswith(".appex"))
            runner.run("verify-signature-" + suffix + str(index), ["codesign", "--verify", "--strict", str(bundle)])
            extracted = folder / ("signer-" + suffix + str(index))
            extracted.mkdir(exist_ok=False)
            runner.run("verify-signer-" + suffix + str(index), ["codesign", "--display", "--extract-certificates", str(bundle)], cwd=extracted)
            require(sha(extracted / "codesign0") == prior["familyCertificateSha256"], "Actual signer is not the approved existing family certificate")
            decoded = plistlib.loads(runner.run("verify-profile-" + suffix + str(index), ["security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")]).read_bytes())
            require(profile(decoded, identifier, prior["familyCertificateSha256"])["uuid"] == approved_uuids[identifier],
                    "Actual signed profile differs from the approved existing resource")
            bundles[suffix + "/" + name] = metadata
    require(runner.inputs(GENERATED_PLISTS) == (prior["immutableSourceInputCount"], prior["immutableSourceInputSha256"]),
            "Tracked production source outside the four generated plists changed during signing")
    receipt["artifact"] = {"file": ipa.name, "bytes": ipa.stat().st_size, "sha256": sha(ipa), "sourceCommit": prior["sourceCommit"],
                           "toolCommit": prior["toolCommit"], "platform": "IOS", "version": VERSION, "build": str(build),
                           "bundles": bundles, "catalogs": catalogs, "familyPublicKeySha256": FAMILY_SPKI_SHA256}
    print("KADE_SIGNED_IPA_RECEIPT " + json.dumps(receipt, sort_keys=True, separators=(",", ":")), flush=True)
    require(runner.text("recheck-apple-build", latest_command, seconds=45, credentials=True) == latest_text,
            "Another Apple build appeared; reconcile before any upload")
    register_asc_leaf(folder)
    receipt["uploadStatus"] = "unknown"
    runner.run("single-upload-only", asc("publish") + ["--path", str(ipa), "--altool-retries", "1",
               "--max-find-build-wait", "1", "--max-build-processing-wait", "0"], seconds=300, credentials=True)
    receipt.update({"passed": True, "uploadStatus": "acknowledged", "processingVerified": False})


def cleanup():
    folder = work()
    if not folder.exists():
        return
    failures = []
    try:
        cleanup_native_profiles(folder)
    except Exception:
        failures.append("owned native profiles")
    try:
        cleanup_asc_leaf(folder)
    except Exception:
        failures.append("owned ASC leaf")
    keychain = folder / "signing.keychain-db"
    try:
        require(not keychain.is_symlink() and keychain.resolve().parent == folder, "Invalid ephemeral keychain path")
        if keychain.exists():
            subprocess.run(["security", "delete-keychain", str(keychain)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=15, check=True)
    except Exception:
        failures.append("keychain")
    for name in ("family-cert-key.pem",):
        try:
            (folder / name).unlink(missing_ok=True)
        except Exception:
            failures.append("family key")
    for name in ("certificates", "profiles"):
        try:
            raw = folder / name
            path = raw.resolve()
            require(path.parent == folder and not raw.is_symlink(), "Invalid ephemeral credential path")
            if path.exists():
                shutil.rmtree(path)
        except Exception:
            failures.append(name)
    require(not failures, "Bounded credential cleanup incomplete: " + ", ".join(failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("gate", "sign", "cleanup"))
    parser.add_argument("--app-source", type=Path)
    args = parser.parse_args()
    receipt = {"schema": "kade.puppet-production-upload.v2", "phase": args.phase, "passed": False,
               "uploadStatus": "not-started", "operations": [], "operationTimeoutSeconds": LIMIT,
               "reviewSubmissionRequested": False, "previousReviewCancelled": False,
               "betaGroupChangesRequested": False, "externalNotificationsRequested": False,
               "notificationSettingsChanged": False, "signingResourcesCreated": False,
               "githubArtifactsUploaded": False, "githubCachesUploaded": False, "physicalPhoneVerified": False,
               "physicalBatteryVerified": False, "physicalVoiceOverVerified": False, "runtimeAcceptance": False}
    try:
        require(sys.platform == "darwin", "This lane requires the actual approved macOS CI runner")
        if args.phase == "cleanup":
            cleanup()
            receipt["passed"] = True
        else:
            require(args.app_source and args.app_source.is_dir() and args.app_source.resolve() != TOOLS,
                    "Separate approved app checkout is required")
            (gate if args.phase == "gate" else sign)(args.app_source.resolve(), receipt)
    except Exception as error:
        receipt["errorType"] = type(error).__name__
        # Only controlled error messages; subprocess/private output is never copied here.
        receipt["error"] = str(error)[:400] if isinstance(error, ControlledError) else "Phase failed; private output is suppressed"
    receipt["finishedAtUtc"] = datetime.now(timezone.utc).isoformat()
    print("KADE_MANUAL_UPLOAD_RECEIPT " + json.dumps(receipt, sort_keys=True, separators=(",", ":")), flush=True)
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
