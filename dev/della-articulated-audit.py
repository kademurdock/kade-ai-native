"""Exact-source unsigned Della simulator review; bounded evidence uses logs only.

source is read-only apart from its local receipt. capture runs a silent DEBUG
fixture on an ephemeral simulator. emit packages only PNGs/JSON, never an app,
IPA, key, transcript or credential. No server, signing identity or release API.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import time
import zipfile
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'della-articulated-audit'
REPOSITORY = 'kademurdock/kade-ai-native'
BRANCH = 'codex/puppet-articulated-bodies-20261009'
BUNDLE_ID = 'com.kademurdock.kadeai'
MASTER_SHA = '285b6e1f176b79ba08cfc7a4252a3d8864901eabbdcbc1e58f304299164206d2'
PINS = {
    'Sources/Assets.xcassets/CharacterDellaFaces.imageset/della-expressions.jpg': 'b8d2c80015f81c59909e4a61615ce0815ed5c763d63eec0d6e22d2b4a801c4de',
    'dev/puppet-review-assets/della-head-alpha.png': '036d2ce6292fec1cb0226fe69f584789d46eadf4625e925e293ed717fecc1b1a',
    'dev/puppet-review-assets/della-body-plate.png': 'e0709e31501d6b3e2b59a18c7cff93e1012b411e489b9ba9f956e8b72281018e',
}
MAX_SCREENSHOT = 4 * 1024 * 1024
MAX_RAW = 50 * 1024 * 1024
MAX_ARCHIVE = 32 * 1024 * 1024
MAX_ENCODED = 44 * 1024 * 1024
CAPTURE_SECONDS = 240
BOOT_SECONDS = 420
MAX_FILES = 32
NATIVE_CHECKS = {
    'Optional gesture master and accepted Della torso/matte are bundled',
    'The unchanged gesture master retains its common 1254-square canvas',
    "The offline fixture uses Della's exact existing avatar registration",
    'Cached clipping paths preserve the editable authored source geometry',
    'Both phone widths, both appearances, extrema and policy stops are captured',
}


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def now():
    return datetime.now(timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(name, data):
    require(Path(name).name == name, 'Unsafe receipt filename')
    OUT.mkdir(exist_ok=True)
    (OUT / name).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True, stderr=subprocess.PIPE).strip()


def source(expected, clean=False, require_staged=False):
    require(re.fullmatch(r'[0-9a-f]{40}', expected or '') is not None and git('rev-parse', 'HEAD') == expected,
            'Exact event/source commit mismatch')
    if clean:
        require(not git('status', '--porcelain'), 'Initial candidate checkout must be clean')
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        repository = event.get('repository', {})
        require(type(repository.get('private')) is bool and repository['private'] is False
                and repository.get('full_name') == REPOSITORY
                and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY
                and os.environ.get('GITHUB_REF') == 'refs/heads/' + BRANCH
                and os.environ.get('GITHUB_EVENT_NAME') == 'push'
                and os.environ.get('GITHUB_SHA') == expected and event.get('after') == expected
                and event.get('deleted') is False
                and os.environ.get('RUNNER_OS') == 'macOS', 'Public standard-runner event scope failed')
    inputs = {}
    for name, expected_hash in PINS.items():
        require(sha(ROOT / name) == expected_hash, 'Approved art changed: ' + name)
        inputs[name] = expected_hash
    master=ROOT/'dev/della-articulated-review/della-body-gesture-master-v1.png'
    require(sha(master)==MASTER_SHA,'Immutable dev gesture master changed')
    data=master.read_bytes()
    require(data[:8]==b'\x89PNG\r\n\x1a\n' and struct.unpack('>II',data[16:24])==(1254,1254)
            and data[24]==8 and data[25]==6,'Review master must remain1254-square8bitRGBA')
    inputs[str(master.relative_to(ROOT)).replace('\\','/')]=MASTER_SHA
    catalog = ROOT / 'Sources/Assets.xcassets/CharacterDellaArticulatedReview.imageset'
    if clean:
        require(not catalog.exists(),'Initial source must exclude the optional study catalog')
    if require_staged:
        contents=json.loads((catalog/'Contents.json').read_text())
        require(contents=={'images':[{'filename':master.name,'idiom':'universal'}],
                           'info':{'author':'xcode','version':1}},'Staged review catalog metadata drift')
        require({path.name for path in catalog.iterdir()}=={master.name,'Contents.json'}
                and (catalog/master.name).read_bytes()==data,'Staged review art is not a byte-identical dev source copy')
    for name in ('Sources/CharacterDellaArticulatedGeometry.swift', 'Sources/CharacterDellaArmMotion.swift',
                 'Sources/CharacterDellaArticulatedAuditView.swift', 'Sources/CharacterPortraitView.swift',
                 'Sources/KadeAIApp.swift', 'project.yml', 'run-character-tests.sh',
                 'dev/prepare-della-articulated-review.py',
                 '.github/workflows/della-articulated-review.yml', 'dev/della-articulated-audit.py'):
        inputs[name] = sha(ROOT / name)
    return {'schema':'kade.della-native-source.v1','sha':expected,'branch':BRANCH,'repository':REPOSITORY,
            'inputs':inputs,'checkedAtUtc':now(),'unsignedSimulatorOnly':True,'releasePublished':False,
            'physicalPhoneVerified':False,'audioStarted':False,'microphoneStarted':False}


def required_phases():
    # Kept explicit and matched to the dedicated native view, not the full tour.
    return {f'della-articulated-{side}-{theme}-{pose}' for side in (160,208)
            for theme in ('light','dark')
            for pose in ('rest','counter-inward','counter-outward','still','head-left','head-right','reduce-motion')}


def sim(*args, timeout=45, env=None):
    try:
        return subprocess.check_output(['xcrun','simctl',*args],text=True,stderr=subprocess.PIPE,
                                       timeout=timeout,env=env).strip()
    except (subprocess.CalledProcessError,subprocess.TimeoutExpired) as error:
        print(f'simctl {args[0] if args else "operation"} failed ({type(error).__name__}, timeout bound{timeout}s).',file=sys.stderr)
        # bootstatus reports startup progress on stdout, including when the
        # cold simulator exceeds its readiness bound. Preserve that evidence.
        for stream_name,stream in [('stdout',error.output),('stderr',error.stderr)]:
            diagnostic=stream or ''
            if isinstance(diagnostic,bytes):
                diagnostic=diagnostic.decode('utf-8',errors='replace')
            diagnostic=re.sub(r'https?://\S+','[URL omitted]',diagnostic)
            diagnostic=re.sub(r'(?i)(authorization|api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+',
                              r'\1=[redacted]',diagnostic)
            if diagnostic:
                print(stream_name+':\n'+diagnostic[-4000:],file=sys.stderr)
        raise


def png(path):
    data=path.read_bytes()
    require(33<=len(data)<=MAX_SCREENSHOT and data[:8]==b'\x89PNG\r\n\x1a\n'
            and data[8:16]==b'\x00\x00\x00\x0dIHDR','Missing/oversized/invalid PNG capture')
    width,height=struct.unpack('>II',data[16:24])
    require(320<=width<=3000 and 600<=height<=6000,'Unexpected simulator PNG dimensions')
    cursor=8
    kinds=[]
    while cursor<len(data):
        require(cursor+12<=len(data),'Truncated PNG chunk')
        length=struct.unpack('>I',data[cursor:cursor+4])[0]
        kind=data[cursor+4:cursor+8]
        end=cursor+12+length
        require(end<=len(data),'Truncated PNG payload')
        payload=data[cursor+8:cursor+8+length]
        expected_crc=struct.unpack('>I',data[cursor+8+length:end])[0]
        require(zlib.crc32(kind+payload)&0xffffffff==expected_crc,'Corrupt PNG chunk CRC')
        kinds.append(kind)
        cursor=end
        if kind==b'IEND':
            break
    require(kinds and kinds[0]==b'IHDR' and kinds[-1]==b'IEND' and b'IDAT' in kinds
            and cursor==len(data),'Incomplete PNG image stream')
    return {'file':path.name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),
            'pixels':[width,height]}


def capture(expected):
    initial=source(expected,require_staged=True)
    old=json.loads((OUT/'source.json').read_text())
    require(initial['inputs']==old['inputs'] and old['sha']==expected,'Source changed after initial gate')
    require(sys.platform=='darwin','Native capture requires the standard macOS runner')
    runtimes=json.loads(sim('list','runtimes','--json'))['runtimes']
    choices=[r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']
             and str(r.get('version','')).startswith('26.4')]
    require(choices,'Installed iOS26.4 simulator runtime missing; no runtime download or fallback')
    runtime=choices[-1]['identifier']
    devices=json.loads(sim('list','devicetypes','--json'))['devicetypes']
    device=next((d['identifier'] for d in devices if d['name']=='iPhone 17 Pro Max'),None)
    require(device is not None,'Documented standard iPhone17ProMax simulator missing')
    identifier=sim('create','Della exact-source unsigned art review',device,runtime)
    receipt={'source':old,'simulator':{'device':device,'runtime':runtime},'captures':{},
             'nativeRenderingVerified':False,'physicalPhoneVerified':False,'audioStarted':False,
             'microphoneStarted':False,'startedAtUtc':now(),'passed':False}
    try:
        app=ROOT/'build/della-articulated-simulator/Build/Products/Debug-iphonesimulator/KadeAI.app'
        require(app.is_dir(),'Unsigned Debug simulator app missing')
        info=plistlib.loads((app/'Info.plist').read_bytes())
        require(info.get('CFBundleIdentifier')==BUNDLE_ID and info.get('CFBundleShortVersionString')=='2.2.11'
                and str(info.get('CFBundleVersion'))=='100','Built app identity/version drift')
        require(info.get('DTPlatformName')=='iphonesimulator'
                or 'iPhoneSimulator' in info.get('CFBundleSupportedPlatforms',[]),'Built app is not the simulator target')
        require(not (app/'_CodeSignature').exists(),'Signed app bundle appeared in unsigned simulator review')
        receipt['builtApp']={'bundleId':BUNDLE_ID,'marketingVersion':'2.2.11','buildVersion':'100',
                             'platform':'iphonesimulator','infoPlistSha256':sha(app/'Info.plist'),
                             'developerSigningIdentityUsed':False}
        receipt['simulator']['bootTimeoutSeconds']=BOOT_SECONDS
        sim('boot',identifier)
        boot_started=time.monotonic()
        sim('bootstatus',identifier,'-b',timeout=BOOT_SECONDS)
        receipt['simulator']['bootReady']=True
        receipt['simulator']['bootSeconds']=round(time.monotonic()-boot_started,3)
        sim('install',identifier,str(app),timeout=60)
        documents=Path(sim('get_app_container',identifier,BUNDLE_ID,'data'))/'Documents'
        documents.mkdir(exist_ok=True)
        env=dict(os.environ,SIMCTL_CHILD_KADE_CHARACTER_AUDIT='1',
                 SIMCTL_CHILD_KADE_DELLA_ARTICULATED_AUDIT='1',SIMCTL_CHILD_KADE_A11Y_AUDIT='1')
        sim('launch','--stdout='+str(OUT/'app.stdout'),'--stderr='+str(OUT/'app.stderr'),
            identifier,BUNDLE_ID,env=env)
        deadline=time.monotonic()+CAPTURE_SECONDS
        phases=required_phases()
        while time.monotonic()<deadline:
            phase=documents/'della-articulated-phase.txt'
            if phase.exists():
                label=phase.read_text().strip()
                require(label in phases,'Unexpected focused native capture phase')
                if label not in receipt['captures']:
                    path=OUT/(label+'.png')
                    sim('io',identifier,'screenshot',str(path),timeout=30)
                    receipt['captures'][label]=png(path)
                    acknowledgement=documents/'della-articulated-captured.txt'
                    temporary=documents/'della-articulated-captured.tmp'
                    temporary.write_text(label)
                    os.replace(temporary,acknowledgement)
            report=documents/'della-articulated-audit.json'
            if report.exists():
                require(report.stat().st_size<=64*1024,'Oversized synthetic native receipt')
                native=json.loads(report.read_text())
                receipt['nativeAudit']=native
                require(native.get('passed') is True,'Native Della fixture failed')
                require(isinstance(native.get('checks'),list) and NATIVE_CHECKS<=set(native['checks']),
                        'Required native resource/identity/path/capture assertions are missing')
                require(native.get('silent') is True and native.get('physicalDeviceVerified') is False
                        and native.get('productionRegistrationChanged') is False
                        and native.get('candidateDefaultEnabled') is False
                        and native.get('cropWorld')==[414,620] and native.get('sourceSide')==1254
                        and native.get('bodyDestination')==[-132,-1,677.16,677.16]
                        and native.get('facePanelWorld')==[0,0,414,414]
                        and native.get('headMaskDestination')==[35,0,350]
                        and native.get('maximumArmDegrees')==3
                        and native.get('expectedMasterSHA256')==MASTER_SHA
                        and native.get('expectedCaptureCount')==28
                        and len(native.get('captures',[]))==28 and set(native['captures'])==phases,
                        'Silent native fixture/art/policy metadata drift')
                require(set(receipt['captures'])==phases,'Focused native screenshot set is incomplete')
                receipt.update(passed=True,nativeRenderingVerified=True)
                break
            time.sleep(.15)
        require(receipt['passed'],'Focused native capture exceeded240-second watchdog')
        require(source(expected,require_staged=True)['inputs']==old['inputs'],'Source changed during simulator capture')
    except Exception as error:
        receipt['errorType']=type(error).__name__
        receipt['error']=str(error) if isinstance(error,RuntimeError) else 'Simulator operation failed; inspect normal step logs'
        if isinstance(error,(subprocess.TimeoutExpired,subprocess.CalledProcessError)):
            command=error.cmd
            if isinstance(command,(list,tuple)) and len(command)>2:
                receipt['failedOperation']=str(command[2])
            if isinstance(error,subprocess.TimeoutExpired):
                receipt['timeoutSeconds']=error.timeout
        raise
    finally:
        receipt['finishedAtUtc']=now()
        save('receipt.json',receipt)
        try:
            sim('shutdown',identifier,timeout=30)
        except Exception:
            pass
    return {'passed':receipt['passed'],'screenshots':len(receipt['captures']),
            'nativeRenderingVerified':True,'physicalPhoneVerified':False,'source':expected}


def emit(expected):
    # Exact named evidence only. App logs, binary output and account data are
    # deliberately excluded; compile/model diagnostics remain normal job logs.
    require(OUT.is_dir() and (OUT/'source.json').is_file(),'No validated candidate source receipt exists')
    initial=json.loads((OUT/'source.json').read_text())
    require(initial.get('sha')==expected and git('rev-parse','HEAD')==expected,'Evidence source mismatch')
    require(source(expected)['inputs']==initial.get('inputs'),'Exact source input hashes drifted before log packaging')
    files={'source.json':(OUT/'source.json').read_bytes()}
    if (OUT/'receipt.json').exists():
        receipt=json.loads((OUT/'receipt.json').read_text())
        require(receipt.get('source')==initial,'Capture receipt source drift')
        files['receipt.json']=(OUT/'receipt.json').read_bytes()
        for phase,metadata in receipt.get('captures',{}).items():
            require(phase in required_phases() and metadata['file']==phase+'.png','Unsafe screenshot receipt')
            path=OUT/metadata['file']
            require(png(path)==metadata,'Captured PNG changed before log packaging')
            files[path.name]=path.read_bytes()
    require(len(files)<=MAX_FILES and sum(map(len,files.values()))<=MAX_RAW,'Raw QA evidence exceeds its bound')
    manifest={'schema':'kade.della-log-evidence.v1','sha':expected,
              'files':{name:{'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()} for name,data in files.items()},
              'artifactStorageUsed':False,'ipaIncluded':False,'physicalPhoneVerified':False}
    files['evidence-manifest.json']=(json.dumps(manifest,indent=2)+'\n').encode()
    buffer=BytesIO()
    with zipfile.ZipFile(buffer,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for name,data in sorted(files.items()):
            require(Path(name).name==name and (name.endswith('.png') or name in
                    ('source.json','receipt.json','evidence-manifest.json')),'Disallowed package member')
            archive.writestr(name,data)
    data=buffer.getvalue()
    require(len(data)<=MAX_ARCHIVE,'QA archive exceeds32MiB; refuse log transport')
    encoded=base64.b64encode(data).decode('ascii')
    require(len(encoded)<=MAX_ENCODED,'Encoded QA evidence exceeds44MiB')
    archive_sha=hashlib.sha256(data).hexdigest()
    chunks=[encoded[index:index+16384] for index in range(0,len(encoded),16384)]
    header={'schema':'kade.della-log-evidence.v1','sha':expected,'archiveSha256':archive_sha,
            'archiveBytes':len(data),'encodedBytes':len(encoded),'chunks':len(chunks),
            'files':len(files),'encoding':'base64','artifactStorageUsed':False}
    print('KADE_DELLA_QA_BEGIN '+json.dumps(header,separators=(',',':')),flush=True)
    for index,chunk in enumerate(chunks,1):
        print(f'KADE_DELLA_QA_CHUNK {index:06d} '+chunk,flush=True)
    print('KADE_DELLA_QA_END '+archive_sha,flush=True)
    return None


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('source','capture','emit'))
    parser.add_argument('--expected-sha',required=True)
    args=parser.parse_args()
    if args.action=='source':
        result=source(args.expected_sha,clean=True)
        save('source.json',result)
    elif args.action=='capture':
        result=capture(args.expected_sha)
    else:
        result=emit(args.expected_sha)
    if result is not None:
        print(json.dumps(result,indent=2))


if __name__=='__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'ok':False,'errorType':type(error).__name__,
                          'message':str(error) if isinstance(error,RuntimeError) else 'Audit operation failed'}),file=sys.stderr)
        raise SystemExit(1)
