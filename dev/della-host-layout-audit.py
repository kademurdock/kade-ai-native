"""Exact-source silent actual-host simulator QA; bounded evidence uses logs only.

This separate lane preserves the accepted puppet and previous art audit. Only
synthetic host readiness, PNGs and receipts enter the bounded evidence archive.
No server, signing, app package, account transcript, artifact storage or release.
"""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
from io import BytesIO
import json
import math
import os
from pathlib import Path
import plistlib
import re
import selectors
import signal
import struct
import subprocess
import sys
import time
import zipfile
import zlib

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/della-host-layout-audit'
REPOSITORY='kademurdock/kade-ai-native'
BRANCH='codex/puppet-body-host-layout-20261010'
BUNDLE_ID='com.kademurdock.kadeai'
APP=ROOT/'build/della-host-layout-simulator/Build/Products/Debug-iphonesimulator/KadeAI.app'
MASTER_SHA='285b6e1f176b79ba08cfc7a4252a3d8864901eabbdcbc1e58f304299164206d2'
PINS={
    'Sources/Assets.xcassets/CharacterDellaFaces.imageset/della-expressions.jpg':'b8d2c80015f81c59909e4a61615ce0815ed5c763d63eec0d6e22d2b4a801c4de',
    'dev/puppet-review-assets/della-head-alpha.png':'036d2ce6292fec1cb0226fe69f584789d46eadf4625e925e293ed717fecc1b1a',
    'dev/puppet-review-assets/della-body-plate.png':'e0709e31501d6b3e2b59a18c7cff93e1012b411e489b9ba9f956e8b72281018e',
    'dev/della-articulated-review/della-body-gesture-master-v1.png':MASTER_SHA,
    'Sources/CharacterPortraitView.swift':'09d76168ae6ca6084bbf0595c6ced3f3894fd04860ace64beee1ad75411a16ca',
    'Sources/CharacterDellaArticulatedGeometry.swift':'51ae3a0aed8b9d122287b3ede13eaffb81d9a646bedbe8329930788ed3f568fb',
}
SOURCE_INPUTS=(
    'Sources/CallView.swift','Sources/ConversationDetailView.swift',
    'Sources/CharacterConversationStage.swift','Sources/KadeAPIClient.swift',
    'Sources/KadeUITestMode.swift',
    'Sources/CharacterDellaHostAudit.swift','Sources/CharacterDellaArmMotion.swift',
    'Sources/CharacterDellaHostReview.swift','Sources/CharacterMotion.swift',
    'Sources/CharacterPuppetLabView.swift',
    'Sources/CharacterStageLayout.swift','UITests/DellaHostControlsUITests.swift',
    'Sources/KadeAIApp.swift','project.yml','run-character-tests.sh',
    'CharacterMotionTests/main.swift','CharacterMotionTests/CharacterDellaArmMotionTests.swift',
    'CharacterMotionTests/CharacterDellaArticulatedGeometryTests.swift',
    'Sources/KadeFreshAgentChat.swift','FreshAgentChatTests/main.swift',
    'run-fresh-agent-chat-tests.sh','dev/prepare-puppet-review.py',
    'dev/prepare-della-articulated-review.py','dev/validate-angel-vector.py',
    '.github/workflows/della-host-layout-review.yml','dev/della-host-layout-audit.py',
)
HOST_MODEL_INPUTS=('Sources/CharacterDellaHostLayout.swift',
                   'CharacterMotionTests/CharacterDellaHostLayoutTests.swift')
PHASES=(
    'chat-roomy-light','chat-packed-dark','chat-keyboard-dark','chat-keyboard-scrolled-dark',
    'chat-a11y-dark','chat-a11y-scrolled-dark',
    'chat-off-dark','chat-small-light','call-roomy-light','call-captions-dark',
    'call-captions-scrolled-dark','call-camera-light','call-camera-scrolled-dark',
    'call-a11y-dark','call-a11y-scrolled-dark','call-off-camera-dark','call-small-light',
    'chat-a11y-keyboard-dark','chat-a11y-keyboard-card-scrolled-dark',
    'chat-a11y-keyboard-controls-scrolled-dark','chat-a11y-small-light',
    'chat-a11y-card-scrolled-small-light','chat-a11y-controls-scrolled-small-light',
    'chat-a11y-keyboard-small-light','chat-a11y-keyboard-card-scrolled-small-light',
    'chat-a11y-keyboard-controls-scrolled-small-light',
    'chat-a11y-empty-keyboard-small-light','chat-a11y-empty-controls-scrolled-small-light',
)
DEVICES={
    'large':{'name':'iPhone 17 Pro Max',
             'type':'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max',
             'points':[440,956],'scale':3},
    'small':{'name':'iPhone SE (3rd generation)',
             'type':'com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation',
             'points':[375,667],'scale':2},
}
UI_PHASES={
    'chat-roomy-light','chat-packed-dark','chat-keyboard-dark','chat-keyboard-scrolled-dark',
    'chat-a11y-dark','chat-a11y-scrolled-dark',
    'call-roomy-light','call-captions-dark','call-captions-scrolled-dark',
    'call-camera-light','call-camera-scrolled-dark','call-a11y-dark','call-a11y-scrolled-dark',
    'chat-a11y-keyboard-dark','chat-a11y-keyboard-card-scrolled-dark',
    'chat-a11y-keyboard-controls-scrolled-dark','chat-a11y-small-light',
    'chat-a11y-card-scrolled-small-light','chat-a11y-controls-scrolled-small-light',
    'chat-a11y-keyboard-small-light','chat-a11y-keyboard-card-scrolled-small-light',
    'chat-a11y-keyboard-controls-scrolled-small-light',
    'chat-a11y-empty-keyboard-small-light','chat-a11y-empty-controls-scrolled-small-light',
}
UI_METHODS={
    'testChatRoomyLight':'chat-roomy-light','testChatPackedDark':'chat-packed-dark',
    'testChatKeyboardDark':'chat-keyboard-dark','testChatKeyboardScrolledDark':'chat-keyboard-scrolled-dark',
    'testChatAccessibilityDark':'chat-a11y-dark','testChatAccessibilityScrolledDark':'chat-a11y-scrolled-dark',
    'testCallRoomyLight':'call-roomy-light','testCallCaptionsDark':'call-captions-dark',
    'testCallCaptionsScrolledDark':'call-captions-scrolled-dark','testCallCameraLight':'call-camera-light',
    'testCallCameraScrolledDark':'call-camera-scrolled-dark','testCallAccessibilityDark':'call-a11y-dark',
    'testCallAccessibilityScrolledDark':'call-a11y-scrolled-dark',
    'testChatAccessibilityKeyboardDark':'chat-a11y-keyboard-dark',
    'testChatAccessibilityKeyboardCardScrolledDark':'chat-a11y-keyboard-card-scrolled-dark',
    'testChatAccessibilityKeyboardControlsScrolledDark':'chat-a11y-keyboard-controls-scrolled-dark',
    'testChatAccessibilitySmallLight':'chat-a11y-small-light',
    'testChatAccessibilityCardScrolledSmallLight':'chat-a11y-card-scrolled-small-light',
    'testChatAccessibilityControlsScrolledSmallLight':'chat-a11y-controls-scrolled-small-light',
    'testChatAccessibilityKeyboardSmallLight':'chat-a11y-keyboard-small-light',
    'testChatAccessibilityKeyboardCardScrolledSmallLight':'chat-a11y-keyboard-card-scrolled-small-light',
    'testChatAccessibilityKeyboardControlsScrolledSmallLight':'chat-a11y-keyboard-controls-scrolled-small-light',
    'testChatAccessibilityEmptyKeyboardSmallLight':'chat-a11y-empty-keyboard-small-light',
    'testChatAccessibilityEmptyControlsScrolledSmallLight':'chat-a11y-empty-controls-scrolled-small-light',
}
UI_COUNTS={'large':16,'small':8}
CORE_BUTTONS=('attach','thinkingButton','micButton','send')
VOICE_BUTTONS=('agentButton','voiceButton','hearRepliesButton','speedButton')
CALL_PRIMARY=('muteButton','hangUpButton')
CALL_SECONDARY=('cameraButton','spotterButton','deepThinkButton','stopTalkingButton')
GEOMETRY_KEYS={
    'window','stage','transcript','composer','chatControls','attachment','invite',
    'viewport','callViewport','primaryControls','camera','secondaryControls','keyboard',
    'cameraButton','spotterButton','deepThinkButton','stopTalkingButton','muteButton','hangUpButton',
    'attach','composerField','send','inviteTurnOn','inviteNotNow','thinkingButton','micButton',
    'agentButton','voiceButton','hearRepliesButton','speedButton','transcriptScroll',
}
AGENT_ID='agent_BSOLa3eNEZyjs-7abCjMt'
AVATAR_PATH='/images/agent-agent_BSOLa3eNEZyjs-7abCjMt-avatar-1788941611099.png'
NATIVE_CHECKS={
    'Requested actual host and original Della ownership match',
    'Real portrait phone dimensions and settled stage frame agree',
    'Camera, audio, microphone and network fixtures stayed silent',
    'Candidate, keyboard, accessibility and scroll policies match the case',
    'Measured stage paint respects the viewport and fixed call controls',
    'The transcript stays usable while its invitation and voice controls remain reachable',
}
MAX_SCREENSHOT=4*1024*1024
MAX_RAW=50*1024*1024
MAX_ARCHIVE=32*1024*1024
MAX_ENCODED=44*1024*1024
MAX_FILES=32
CAPTURE_SECONDS=480
AGGREGATE_CAPTURE_SECONDS=960
SCREENSHOT_SECONDS=75
READY_SECONDS=30
BOOT_SECONDS=420
INSTALL_SECONDS=180
UI_SECONDS={'large':600,'small':480}
UI_LOG_BYTES=8*1024*1024
UI_STOP_SECONDS=10
EXPECTED_MODEL_CHECKS=27192
JOB_SECONDS=55*60
OPERATION_SECONDS=52*60
FINAL_RESERVE_SECONDS=JOB_SECONDS-OPERATION_SECONDS
_OPERATION_DEADLINE=None
_DEADLINE_ROLE='sharedOperationDeadline'


def operation_remaining(bound):
    if _OPERATION_DEADLINE is None: return bound
    remaining=_OPERATION_DEADLINE-time.time()
    require(remaining>0,'Shared host operation deadline expired; final receipts are reserved')
    return min(bound,remaining)


def validate_operation_source(initial):
    started=datetime.fromisoformat(initial['operationStartedAtUtc'])
    deadline=datetime.fromisoformat(initial['operationDeadlineUtc'])
    checked=datetime.fromisoformat(initial['checkedAtUtc'])
    require(all(value.tzinfo is not None for value in (started,deadline,checked))
            and abs((deadline-started).total_seconds()-OPERATION_SECONDS)<2
            and started<=checked and initial.get('operationTimeoutSeconds')==OPERATION_SECONDS
            and initial.get('jobTimeoutSeconds')==JOB_SECONDS
            and initial.get('finalReceiptReserveSeconds')==FINAL_RESERVE_SECONDS,
            'Original before-checkout shared deadline/reserve source record mismatch')
    return initial

def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def now():
    return datetime.now(timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(name, data):
    require(Path(name).name == name, 'Unsafe receipt filename')
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT / name).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True, stderr=subprocess.PIPE,
                                   timeout=operation_remaining(30)).strip()


def sim(*args, timeout=45, env=None):
    timeout=operation_remaining(timeout)
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


def required_phases():
    require(len(PHASES)==len(set(PHASES))==28 and bool(HOST_MODEL_INPUTS) and bool(NATIVE_CHECKS),
            'Host fixture phase/source/readiness contract drift')
    require(len(UI_METHODS)==len(UI_PHASES)==24 and set(UI_METHODS.values())==UI_PHASES,
            'Targeted two-device UI method/phase contract drift')
    require(all(re.fullmatch(r'(chat|call)-[a-z0-9-]+',phase) for phase in PHASES),
            'Invalid frozen host case label')
    return set(PHASES)


def source(expected,clean=False,require_staged=False):
    required_phases()
    require(re.fullmatch(r'[a-f0-9]{40}',expected or '') is not None
            and git('rev-parse','HEAD')==expected,'Exact event/source commit mismatch')
    if clean:
        require(not git('status','--porcelain'),'Initial host checkout must be clean')
    if os.environ.get('GITHUB_ACTIONS')=='true':
        event=json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        repository=event.get('repository',{})
        require(type(repository.get('private')) is bool and repository['private'] is False
                and repository.get('full_name')==REPOSITORY
                and os.environ.get('GITHUB_REPOSITORY')==REPOSITORY
                and os.environ.get('GITHUB_REF')=='refs/heads/'+BRANCH
                and os.environ.get('GITHUB_EVENT_NAME')=='push'
                and os.environ.get('GITHUB_SHA')==expected and event.get('after')==expected
                and event.get('deleted') is False and os.environ.get('RUNNER_OS')=='macOS',
                'Exact public host-runner event scope failed')
    else:
        require(git('branch','--show-current')==BRANCH,'Exact local host branch mismatch')
    inputs={}
    for name,digest in PINS.items():
        require(sha(ROOT/name)==digest,'Accepted puppet input changed: '+name)
        inputs[name]=digest
    master=ROOT/'dev/della-articulated-review/della-body-gesture-master-v1.png'
    data=master.read_bytes()
    require(data[:8]==b'\x89PNG\r\n\x1a\n' and struct.unpack('>II',data[16:24])==(1254,1254)
            and data[24]==8 and data[25]==6,'Unchanged master must remain1254-square8bitRGBA')
    catalog=ROOT/'Sources/Assets.xcassets/CharacterDellaArticulatedReview.imageset'
    if clean:
        require(not catalog.exists(),'Initial host source must exclude optional study catalog')
    if require_staged:
        contents=json.loads((catalog/'Contents.json').read_text())
        require(contents=={'images':[{'filename':master.name,'idiom':'universal'}],
                           'info':{'author':'xcode','version':1}},'Staged catalog metadata drift')
        require({path.name for path in catalog.iterdir()}=={master.name,'Contents.json'}
                and (catalog/master.name).read_bytes()==data,'Staged master byte drift')
    for name in SOURCE_INPUTS+HOST_MODEL_INPUTS:
        inputs[name]=sha(ROOT/name)
    declared=set(re.findall(r'\bfunc (test[A-Za-z]+)\(',
                            (ROOT/'UITests/DellaHostControlsUITests.swift').read_text(encoding='utf-8')))
    require(declared==set(UI_METHODS),'Exact native UI method/device selector source drift')
    return {'schema':'kade.della-host-native-source.v1','sha':expected,'repository':REPOSITORY,
            'branch':BRANCH,'inputs':inputs,'checkedAtUtc':now(),'unsignedSimulatorOnly':True,
            'releasePublished':False,'physicalPhoneVerified':False,'batteryPerformanceVerified':False,
            'physicalVoiceOverVerified':False,'audioStarted':False,'microphoneStarted':False,
            'cameraStarted':False,'networkStarted':False}


def case_device(phase):
    require(phase in required_phases(),'Unknown host case')
    return 'small' if phase.endswith('-small-light') else 'large'


def case_policy(phase):
    require(phase in required_phases(),'Unknown host policy case')
    chat=phase.startswith('chat-')
    device=case_device(phase)
    accessibility='-a11y-' in phase
    scrolled='-scrolled-' in phase
    keyboard_initial=chat and 'keyboard' in phase
    keyboard=keyboard_initial and not (device=='small' and scrolled)
    hidden=chat and accessibility and (keyboard or DEVICES[device]['points'][1]<700)
    target='none'
    if scrolled:
        target='callControls' if not chat else 'chatControls' if '-controls-scrolled-' in phase else 'invitation'
    invitation='none' if not chat else 'transcript' if keyboard_initial or accessibility \
        else 'footer' if phase in ('chat-packed-dark','chat-off-dark') else 'none'
    return {'chat':chat,'keyboardVisible':keyboard,'keyboardPresentedInitially':keyboard_initial,
            'composerEditing':keyboard,'portraitVisible':not hidden,
            'chatControlsPlacement':'none' if not chat else 'transcript' if hidden else 'footer',
            'scrollTarget':target,'invitationPlacement':invitation}


def ui_methods(device):
    require(device in UI_COUNTS,'Unknown UI simulator group')
    methods={method:phase for method,phase in UI_METHODS.items() if case_device(phase)==device}
    require(len(methods)==UI_COUNTS[device],'Exact native UI device/method group drift')
    return methods


def initial_source(expected):
    initial=json.loads((OUT/'source.json').read_text())
    require(initial.get('sha')==expected and source(expected)['inputs']==initial.get('inputs'),
            'Host source changed after initial gate')
    return initial


def simulator_preflight(expected):
    initial=initial_source(expected)
    require(not (OUT/'simulators.json').exists(),'Fresh simulator preflight may run only once')
    require(sys.platform=='darwin','Real phone preflight requires standard macOS')
    # The focus fixture must show a real software keyboard. This setting is
    # confined to the fresh ephemeral runner, before either phone is booted.
    subprocess.check_call(['defaults','write','com.apple.iphonesimulator','ConnectHardwareKeyboard',
                           '-bool','false'],timeout=30)
    runtimes=json.loads(sim('list','runtimes','--json'))['runtimes']
    choices=[runtime for runtime in runtimes if runtime.get('isAvailable')
             and '.iOS-' in runtime['identifier']
             and re.fullmatch(r'26\.4(?:\.[0-9]+)?',str(runtime.get('version',''))) is not None]
    require(choices,'Installed iOS26.4 runtime missing; no download or fallback')
    runtime=choices[-1]['identifier']
    types=json.loads(sim('list','devicetypes','--json'))['devicetypes']
    known={item['identifier'] for item in types}
    result={'schema':'kade.della-host-simulators.v1','source':initial,'devices':{},'createdAtUtc':now(),
            'softwareKeyboardRequired':True}
    for key,device in DEVICES.items():
        require(device['type'] in known,'Required real simulator device type unavailable: '+device['name'])
        identifier=sim('create','Della silent host review '+key,device['type'],runtime)
        require(re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}',identifier)
                is not None,'Unexpected simulator identifier')
        result['devices'][key]={'identifier':identifier,'runtime':runtime,**device}
    save('simulators.json',result)
    return {'passed':True,'devices':{key:{'name':device['name'],'identifier':device['identifier'],
                                        'runtime':device['runtime']} for key,device in result['devices'].items()}}


def simulator_record(expected):
    initial=initial_source(expected)
    record=json.loads((OUT/'simulators.json').read_text())
    require(record.get('schema')=='kade.della-host-simulators.v1' and record.get('source')==initial
            and record.get('softwareKeyboardRequired') is True
            and set(record.get('devices',{}))==set(DEVICES),'Fresh simulator/source record mismatch')
    installed=json.loads(sim('list','devices','--json'))['devices']
    for key,device in record['devices'].items():
        require(all(device.get(field)==value for field,value in DEVICES[key].items()),'Recorded device type drift')
        matches=[item for item in installed.get(device['runtime'],[]) if item.get('udid')==device['identifier']]
        require(len(matches)==1 and matches[0].get('isAvailable') is True
                and matches[0].get('deviceTypeIdentifier')==device['type'],'Requested real simulator no longer available')
    return record


def compiled_tests(expected):
    """Bind test-without-building to the unchanged products of the one build."""
    initial=initial_source(expected)
    products=ROOT/'build/della-host-layout-simulator/Build/Products'
    candidates=list(products.glob('KadeAIA11yAudit_*.xctestrun'))
    require(len(candidates)==1,'Exactly one compiled audit xctestrun is required')
    run=candidates[0]
    require(run.stat().st_size<=1024*1024,'Oversized compiled xctestrun')
    data=plistlib.loads(run.read_bytes())
    version=data.get('__xctestrun_metadata__',{}).get('FormatVersion')
    if version==1:
        targets=[dict(value,BlueprintName=value.get('BlueprintName',key))
                 for key,value in data.items() if key!='__xctestrun_metadata__' and isinstance(value,dict)]
    elif version==2:
        configurations=data.get('TestConfigurations',[])
        require(isinstance(configurations,list) and len(configurations)==1,
                'Unexpected multiple compiled test configurations')
        require(configurations[0].get('IsEnabled',True) is True,'Compiled test configuration is disabled')
        targets=configurations[0].get('TestTargets',[])
    else: raise RuntimeError('Unsupported compiled xctestrun format')
    require(isinstance(targets,list) and len(targets)==1,'Unexpected compiled test target set')
    target=targets[0]
    require(target.get('BlueprintName')=='KadeAIUITests' and target.get('IsUITestBundle') is True
            and target.get('UseDestinationArtifacts',False) is False,
            'Compiled runner must be the original local UI test target')
    def resolve(value,host=None):
        require(isinstance(value,str) and 0<len(value)<=2048,'Invalid compiled artifact path')
        value=value.replace('__TESTROOT__',str(run.parent))
        if host is not None: value=value.replace('__TESTHOST__',str(host))
        require('__' not in value,'Unsupported artifact path placeholder')
        path=Path(value).resolve()
        require(path.is_relative_to(products.resolve()),'Compiled artifact escaped the exact build products')
        return path
    host=resolve(target.get('TestHostPath'))
    bundle=resolve(target.get('TestBundlePath'),host)
    app=resolve(target.get('UITargetAppPath'),host)
    require(host==(products/'Debug-iphonesimulator/KadeAIUITests-Runner.app').resolve()
            and bundle==(host/'PlugIns/KadeAIUITests.xctest').resolve()
            and app==APP.resolve(),'Compiled app/runner/test bundle paths drift')
    roles=(('app',app,'KadeAI'),('runner',host,'KadeAIUITests-Runner'),('testBundle',bundle,'KadeAIUITests'))
    inventory={role:{'path':str(path.relative_to(ROOT)),'directoryExists':path.is_dir(),
                     'infoPlistExists':(path/'Info.plist').is_file(),
                     'expectedExecutableExists':(path/executable).is_file(),
                     'codeSignatureExists':(path/'_CodeSignature').exists()}
               for role,path,executable in roles}
    print('KADE_DELLA_HOST_COMPILED_ARTIFACTS '+json.dumps(inventory,separators=(',',':')),flush=True)
    artifacts={}
    identities={'app':BUNDLE_ID,'runner':'com.kademurdock.kadeai.uitests.xctrunner',
                'testBundle':'com.kademurdock.kadeai.uitests'}
    for role,path in (('app',app),('runner',host),('testBundle',bundle)):
        require(path.is_dir() and not (path/'_CodeSignature').exists(),'Unsigned compiled '+role+' missing or signed')
        require((path/'Info.plist').is_file() and 0<(path/'Info.plist').stat().st_size<=1024*1024,
                'Compiled '+role+' Info.plist is missing or oversized')
        info=plistlib.loads((path/'Info.plist').read_bytes())
        require(info.get('CFBundleIdentifier')==identities[role]
                and (info.get('DTPlatformName')=='iphonesimulator'
                     or 'iPhoneSimulator' in info.get('CFBundleSupportedPlatforms',[])),
                'Compiled '+role+' simulator identity mismatch')
        executable=info.get('CFBundleExecutable')
        require(isinstance(executable,str) and Path(executable).name==executable
                and (path/executable).is_file() and (path/executable).stat().st_size<=512*1024*1024,
                'Compiled '+role+' executable missing or unbounded')
        if role=='app':
            require(info.get('CFBundleShortVersionString')=='2.2.11' and str(info.get('CFBundleVersion'))=='100'
                    and info.get('UISupportedInterfaceOrientations')==['UIInterfaceOrientationPortrait'],
                    'Compiled app version/orientation drift')
        artifacts[role]={'path':str(path.relative_to(ROOT)),'bundleId':identities[role],
                         'infoPlistSha256':sha(path/'Info.plist'),'executableSha256':sha(path/executable)}
    result={'schema':'kade.della-host-compiled-tests.v1','source':initial,'formatVersion':version,
            'xctestrun':str(run.relative_to(ROOT)),'xctestrunSha256':sha(run),'artifacts':artifacts,
            'unsignedSimulatorOnly':True,'testTarget':'KadeAIUITests'}
    return validate_compiled_record(result,initial)


def validate_compiled_record(data,initial):
    require(isinstance(data,dict) and data.get('schema')=='kade.della-host-compiled-tests.v1'
            and data.get('source')==initial and type(data.get('formatVersion')) is int
            and data['formatVersion'] in (1,2) and data.get('unsignedSimulatorOnly') is True
            and data.get('testTarget')=='KadeAIUITests','Compiled test record/source mismatch')
    require(isinstance(data.get('xctestrun'),str) and re.fullmatch(
        r'build/della-host-layout-simulator/Build/Products/KadeAIA11yAudit_[A-Za-z0-9_.-]+\.xctestrun',data['xctestrun'])
        and re.fullmatch(r'[a-f0-9]{64}',data.get('xctestrunSha256','')),'Invalid exact compiled xctestrun record')
    expected={'app':('Debug-iphonesimulator/KadeAI.app',BUNDLE_ID),
              'runner':('Debug-iphonesimulator/KadeAIUITests-Runner.app','com.kademurdock.kadeai.uitests.xctrunner'),
              'testBundle':('Debug-iphonesimulator/KadeAIUITests-Runner.app/PlugIns/KadeAIUITests.xctest','com.kademurdock.kadeai.uitests')}
    require(isinstance(data.get('artifacts'),dict) and set(data['artifacts'])==set(expected),'Compiled artifact roles drift')
    for role,(path,identifier) in expected.items():
        item=data['artifacts'][role]
        require(isinstance(item,dict) and set(item)=={'path','bundleId','infoPlistSha256','executableSha256'}
                and item['path']=='build/della-host-layout-simulator/Build/Products/'+path and item['bundleId']==identifier
                and all(re.fullmatch(r'[a-f0-9]{64}',item.get(key,'')) for key in ('infoPlistSha256','executableSha256')),
                'Compiled artifact identity/hash record drift: '+role)
    return data


def validate_ui_boot(report,key,initial):
    require(isinstance(report,dict) and report.get('source')==initial and report.get('device')==key
            and type(report.get('passed')) is bool and report.get('timeoutSeconds')==BOOT_SECONDS,
            'Explicit UI boot diagnostic/source mismatch')
    if 'identifier' in report:
        require(isinstance(report['identifier'],str) and re.fullmatch(
            r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}',report['identifier']), 'Invalid explicit UI device UUID')
    if 'alreadyBooted' in report:require(type(report['alreadyBooted']) is bool,'Invalid UI boot-state observation')
    require(number(report.get('elapsedSeconds')) and 0<=report['elapsedSeconds']<=BOOT_SECONDS+5,
            'Unbounded explicit UI boot elapsed time')
    if report['passed']:
        require('identifier' in report and 'alreadyBooted' in report and 'errorType' not in report
                and report['elapsedSeconds']<=BOOT_SECONDS+1,'Failed explicit UI boot retained success')
    return report


def boot_ui(expected,key):
    initial=initial_source(expected)
    report={'source':initial,'device':key,'passed':False,'timeoutSeconds':BOOT_SECONDS,'startedAtUtc':now()}
    started=time.monotonic()
    try:
        require(sys.platform=='darwin','Explicit UI simulator boot requires standard macOS')
        records=simulator_record(expected)['devices']
        identifier=records[key]['identifier'];report['identifier']=identifier
        deadline=started+operation_remaining(BOOT_SECONDS)
        def remaining(bound):
            seconds=deadline-time.monotonic()
            require(seconds>0,'Explicit UI simulator boot watchdog expired')
            return min(bound,seconds)
        installed=json.loads(sim('list','devices','--json',timeout=remaining(45)))['devices']
        states={item['udid']:item.get('state') for items in installed.values() for item in items}
        other=records['small' if key=='large' else 'large']['identifier']
        if states.get(other)=='Booted': sim('shutdown',other,timeout=remaining(30))
        report['alreadyBooted']=states.get(identifier)=='Booted'
        if not report['alreadyBooted']: sim('boot',identifier,timeout=remaining(45))
        sim('bootstatus',identifier,'-b',timeout=remaining(BOOT_SECONDS))
        report['passed']=True
    except Exception as error:
        report.update(passed=False,errorType=type(error).__name__,
                      error=str(error) if isinstance(error,RuntimeError) else 'Explicit UI simulator boot failed')
        raise
    finally:
        report['elapsedSeconds']=round(time.monotonic()-started,3);report['finishedAtUtc']=now()
        save('ui-boot-'+key+'.json',report)
    return report


def sanitize_ui_line(line):
    line=re.sub(r'https?://\S+','[URL omitted]',line)
    line=re.sub(r'(?:github_pat_|ghp_)[A-Za-z0-9_]+','[credential omitted]',line)
    line=re.sub(r'(authorization|api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+',
                r'\1=[redacted]',line,flags=re.I)
    return ''.join(character for character in line if character=='\t' or ord(character)>=32)[:320]


def observe_ui_line(report,line,key):
    methods=ui_methods(key)
    if re.search(r'Command line invocation:|xcodebuild |Build settings from command line:|Testing started|Test Suite .* started|Selected tests|Preparing|Writing result bundle|[Ss]imulator|destination',line):
        report['startupMessages']=(report['startupMessages']+[sanitize_ui_line(line)])[-6:]
    if re.search(r'\bt\s*=\s*[0-9.]+s?\s+(Launch|Wait for|Find|Get number|Checking|Query|Tap|Scroll|Swipe)\b',line):
        report['activityMessages']=(report['activityMessages']+[sanitize_ui_line(line)])[-12:]
    if 'Testing started' in line or re.search(r'Test Suite .* started',line): report['startupStage']='testingStarted'
    match=re.search(r'Test Case [^\r\n]{0,180}DellaHostControlsUITests[ .]+(test[A-Za-z]+)'
                    r'[^\r\n]{0,8} (started|passed|failed)(?: \(([0-9.]+) seconds\))?',line)
    if match and match[1] in methods:
        method,state,duration=match.groups();entry=report['testMethods'].setdefault(method,{'phase':methods[method]})
        entry['status']=state;report['startupStage']='testCaseStarted'
        if state=='started': report['lastStartedMethod']=method
        if duration is not None and number(float(duration)) and 0<=float(duration)<=3600:
            entry['durationSeconds']=float(duration)
        print('KADE_DELLA_HOST_UI_TEST '+json.dumps({'device':key,'method':method,**entry},separators=(',',':')),flush=True)
    if re.search(r'\berror:|XCTAssert|failed -|Error Domain|Failed to|Unable to|Testing failed|\*\* TEST FAILED \*\*|KADE_DELLA_HOST_CONTROLS_FAILED',line):
        bounded=sanitize_ui_line(line)
        report['failureLines']=(report['failureLines']+[bounded])[-12:]


def stop_ui_process(process):
    if process.poll() is not None: return
    try: os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError: pass
    try: process.wait(timeout=UI_STOP_SECONDS)
    except subprocess.TimeoutExpired:
        try: os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait(timeout=UI_STOP_SECONDS)


def build_tests(expected):
    initial=initial_source(expected)
    require(sys.platform=='darwin','Unsigned native build requires standard macOS')
    identifier=simulator_record(expected)['devices']['large']['identifier']
    command=['xcodebuild','-jobs','2','-project','KadeAI.xcodeproj','-scheme','KadeAIA11yAudit',
             '-configuration','Debug','-sdk','iphonesimulator','-destination','platform=iOS Simulator,id='+identifier,
             '-derivedDataPath','build/della-host-layout-simulator','CODE_SIGNING_ALLOWED=NO',
             'CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=','DEVELOPMENT_TEAM=','build-for-testing']
    report={'source':initial,'passed':False,'timedOut':False,'logLimitExceeded':False,'failureLines':[],
            'startedAtUtc':now(),'timeoutSeconds':900,'exitCode':None}
    process=None;started=time.monotonic()
    try:
        effective=operation_remaining(900)
        process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,bufsize=0,cwd=ROOT)
        deadline=time.monotonic()+effective;written=0;pending=b'';drain_deadline=None
        with (OUT/'compile.log').open('wb') as log, selectors.DefaultSelector() as selector:
            selector.register(process.stdout,selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic()>=deadline and process.poll() is None:
                    report['timedOut']=True;stop_ui_process(process)
                if process.poll() is not None:
                    if drain_deadline is None:drain_deadline=time.monotonic()+UI_STOP_SECONDS
                    if time.monotonic()>=drain_deadline:break
                for selected,_ in selector.select(.25):
                    chunk=os.read(selected.fileobj.fileno(),65536)
                    if not chunk:selector.unregister(selected.fileobj);continue
                    log.write(chunk[:max(0,UI_LOG_BYTES-written)]);written+=len(chunk);pending+=chunk
                    if written>UI_LOG_BYTES:report['logLimitExceeded']=True;stop_ui_process(process)
                    while b'\n' in pending:
                        line,pending=pending.split(b'\n',1);line=line[:4096].decode('utf-8','replace')
                        if re.search(r'\berror:|\*\* BUILD FAILED \*\*',line):
                            report['failureLines']=(report['failureLines']+[sanitize_ui_line(line)])[-12:]
                    if len(pending)>4096:pending=pending[-4096:]
        report['exitCode']=process.wait(timeout=UI_STOP_SECONDS)
        require(report['exitCode']==0 and not report['timedOut'] and not report['logLimitExceeded'],
                'The single bounded unsigned build-for-testing failed')
        result=compiled_tests(expected);save('compiled-tests.json',result);report['passed']=True
    finally:
        if process is not None:
            try:stop_ui_process(process)
            except Exception as error:report.update(passed=False,cleanupErrorType=type(error).__name__)
            report['exitCode']=process.poll()
        report['elapsedSeconds']=round(time.monotonic()-started,3);save('build-tests.json',report)
        for line in report['failureLines']:print('KADE_DELLA_HOST_BUILD_FAILURE '+line,flush=True)
        print('KADE_DELLA_HOST_BUILD '+json.dumps({name:report[name] for name in
              ('passed','timedOut','logLimitExceeded','exitCode','elapsedSeconds')},separators=(',',':')),flush=True)
    return result


def ui_launch_record(initial,key):
    return {'schema':'kade.della-host-ui-launch.v1','source':initial,'device':key,'passed':False,
            'timeoutSeconds':UI_SECONDS[key],'timedOut':False,'logLimitExceeded':False,
            'startupStage':'notStarted','testMethods':{},'lastStartedMethod':None,'failureLines':[],
            'startupMessages':[],'activityMessages':[],
            'exitCode':None,'startedAtUtc':now(),'status':'startupFailed'}


def run_ui(expected,key):
    initial=initial_source(expected)
    report=ui_launch_record(initial,key)
    started=time.monotonic();process=None
    try:
        require(sys.platform=='darwin','Bounded native UI launch requires standard macOS')
        boot=json.loads((OUT/('ui-boot-'+key+'.json')).read_text())
        require(boot.get('source')==initial and boot.get('device')==key and boot.get('passed') is True,
                'UI launch requires the exact successful explicit device boot')
        report['boot']=boot
        compiled=compiled_tests(expected);report['compiledRunner']=compiled
        identifier=simulator_record(expected)['devices'][key]['identifier']
        require(identifier==boot['identifier'],'UI launch device differs from explicit boot')
        bundle=OUT/('ui-tests-'+key+'.xcresult')
        require(not bundle.exists(),'Refusing to overwrite a native UI result bundle')
        command=['xcodebuild','-jobs','2','test-without-building','-xctestrun',str(ROOT/compiled['xctestrun']),
                 '-destination','platform=iOS Simulator,id='+identifier,'-resultBundlePath',str(bundle),
                 '-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1',
                 *['-only-testing:KadeAIUITests/DellaHostControlsUITests/'+method for method in ui_methods(key)],
                 'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=','DEVELOPMENT_TEAM=']
        effective=operation_remaining(UI_SECONDS[key]);report['effectiveTimeoutSeconds']=effective
        process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                                 start_new_session=True,bufsize=0,cwd=ROOT)
        report['startupStage']='processStarted';report['status']='running';launched=time.monotonic()
        deadline=launched+effective;raw_bytes=0;pending=b'';drain_deadline=None
        with (OUT/('ui-tests-'+key+'.log')).open('wb') as log, selectors.DefaultSelector() as selector:
            selector.register(process.stdout,selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic()>=deadline and process.poll() is None:
                    report['timedOut']=True;report['status']='timeout';stop_ui_process(process)
                    report['timeoutCause']='testDeadline' if effective==UI_SECONDS[key] else _DEADLINE_ROLE
                if process.poll() is not None:
                    if drain_deadline is None: drain_deadline=time.monotonic()+UI_STOP_SECONDS
                    if time.monotonic()>=drain_deadline:
                        for selected in list(selector.get_map().values()): selector.unregister(selected.fileobj)
                        break
                for selected,_ in selector.select(.25):
                    chunk=os.read(selected.fileobj.fileno(),65536)
                    if not chunk: selector.unregister(selected.fileobj);continue
                    keep=max(0,UI_LOG_BYTES-raw_bytes);log.write(chunk[:keep]);raw_bytes+=len(chunk)
                    if raw_bytes>UI_LOG_BYTES:
                        report['logLimitExceeded']=True;report['status']='logLimit';stop_ui_process(process)
                    pending+=chunk
                    while b'\n' in pending:
                        line,pending=pending.split(b'\n',1);observe_ui_line(report,line[:4096].decode('utf-8','replace'),key)
                    if len(pending)>4096: pending=pending[-4096:]
                if process.poll() is not None and not selector.get_map(): break
            if pending: observe_ui_line(report,pending.decode('utf-8','replace'),key)
        report['testElapsedSeconds']=round(time.monotonic()-launched,3)
        report['exitCode']=process.wait(timeout=UI_STOP_SECONDS)
        if not report['timedOut'] and not report['logLimitExceeded']:
            report['status']='completed' if report['exitCode']==0 else 'processFailed'
        report['passed']=report['status']=='completed'
        require(compiled_tests(expected)==compiled,'Compiled test runner changed during UI launch')
        require(report['passed'],'Bounded native UI launch did not complete successfully: '+key)
    except Exception as error:
        report.update(passed=False,errorType=type(error).__name__,
                      error=str(error) if isinstance(error,RuntimeError) else 'Bounded UI launcher failed')
        raise
    finally:
        if process is not None:
            try: stop_ui_process(process)
            except Exception as error:
                report.update(passed=False,cleanupErrorType=type(error).__name__)
            report['exitCode']=process.poll()
        report['elapsedSeconds']=round(time.monotonic()-started,3);report['finishedAtUtc']=now()
        save('ui-run-'+key+'.json',report)
        for line in report['failureLines']: print('KADE_DELLA_HOST_UI_FAILURE '+line,flush=True)
        print('KADE_DELLA_HOST_UI_LAUNCH '+json.dumps({name:report[name] for name in
              ('device','status','startupStage','timedOut','logLimitExceeded','lastStartedMethod','exitCode')},separators=(',',':')),flush=True)
    return report


def validate_ui_launch(report,key,initial):
    require(isinstance(report,dict) and report.get('schema')=='kade.della-host-ui-launch.v1'
            and report.get('source')==initial and report.get('device')==key
            and report.get('timeoutSeconds')==UI_SECONDS[key], 'Native UI launcher/source/device contract mismatch')
    require(type(report.get('passed')) is bool and type(report.get('timedOut')) is bool
            and type(report.get('logLimitExceeded')) is bool
            and report.get('status') in ('startupFailed','running','completed','processFailed','timeout','logLimit','interrupted')
            and report.get('startupStage') in ('notStarted','processStarted','testingStarted','testCaseStarted'),
            'Invalid native UI launcher status')
    require(report.get('exitCode') is None or type(report.get('exitCode')) is int,
            'Invalid native UI exit status')
    methods=report.get('testMethods',{})
    known=ui_methods(key)
    require(isinstance(methods,dict) and set(methods)<=set(known)
            and report.get('lastStartedMethod') in {None,*known},'Unknown native UI test method diagnostic')
    require(report.get('lastStartedMethod') is None or report['lastStartedMethod'] in methods,
            'Last native method has no observed test-start record')
    for method,entry in methods.items():
        require(isinstance(entry,dict) and set(entry)<={'phase','status','durationSeconds'}
                and entry.get('phase')==known[method] and entry.get('status') in ('started','passed','failed'),
                'Invalid native UI method diagnostic')
        if 'durationSeconds' in entry:
            require(number(entry['durationSeconds']) and 0<=entry['durationSeconds']<=3600,
                    'Unbounded native UI test duration')
    for name,bound in (('failureLines',12),('startupMessages',6),('activityMessages',12)):
        lines=report.get(name)
        require(isinstance(lines,list) and len(lines)<=bound
                and all(isinstance(line,str) and len(line)<=320 and sanitize_ui_line(line)==line for line in lines),
                'Unsafe/unbounded native UI diagnostic text')
    for name,maximum in (('elapsedSeconds',720 if key=='large' else 600),
                         ('testElapsedSeconds',UI_SECONDS[key]+2*UI_STOP_SECONDS),
                         ('effectiveTimeoutSeconds',UI_SECONDS[key])):
        if name in report:require(number(report[name]) and 0<=report[name]<=maximum+5,
                                  'Unbounded native UI timing diagnostic: '+name)
    if 'timeoutCause' in report:
        require(report['timedOut'] is True and report['timeoutCause'] in
                ('testDeadline','sharedOperationDeadline','actionGuardDeadline'),'Invalid native UI timeout diagnostic')
    if report['passed']:
        require(report['status']=='completed' and report['exitCode']==0 and report['timedOut'] is False
                and report['logLimitExceeded'] is False and 'errorType' not in report
                and report.get('boot',{}).get('passed') is True,
                'Failed/partial native UI launch retained a success flag')
    if 'boot' in report:validate_ui_boot(report['boot'],key,initial)
    if 'compiledRunner' in report:validate_compiled_record(report['compiledRunner'],initial)
    if report['passed']:require('compiledRunner' in report,'Successful UI launch lacks exact compiled runner proof')
    return report


def number(value):
    return type(value) in (int,float) and math.isfinite(value)


def rectangle(value):
    return isinstance(value,list) and len(value)==4 and all(number(item) and abs(item)<=10000 for item in value) \
        and value[2]>=0 and value[3]>=0


def intersection(first,second):
    x=max(first[0],second[0]); y=max(first[1],second[1])
    width=max(0,min(first[0]+first[2],second[0]+second[2])-x)
    height=max(0,min(first[1]+first[3],second[1]+second[3])-y)
    return [x,y,width,height]


def failed_native_geometry(data,phase):
    """Finite numeric observations only, explicitly excluded from native proof."""
    require(phase in required_phases(),'Unknown failed native diagnostic phase')
    diagnostic={'phase':phase}
    if not isinstance(data,dict): return diagnostic
    points=data.get('windowPoints')
    if isinstance(points,list) and len(points)==2 and all(number(item) and abs(item)<=10000 for item in points):
        diagnostic['windowPoints']=points
    stage=data.get('stage')
    if stage is None and 'stage' in data:
        diagnostic['stage']=None
    elif isinstance(stage,dict):
        bounded={key:value for key,value in stage.items() if key in ('side','portraitHeight','frameHeight')
                 and number(value) and abs(value)<=10000}
        if type(stage.get('articulated')) is bool: bounded['articulated']=stage['articulated']
        if bounded: diagnostic['stage']=bounded
    geometry=data.get('geometry')
    if isinstance(geometry,dict):
        bounded={key:value for key,value in geometry.items() if key in GEOMETRY_KEYS and rectangle(value)}
        if bounded: diagnostic['geometry']=bounded
    validate_failed_native_geometry(diagnostic)
    return diagnostic


def validate_failed_native_geometry(diagnostic):
    require(isinstance(diagnostic,dict) and set(diagnostic)<={'phase','windowPoints','stage','geometry'}
            and diagnostic.get('phase') in required_phases(),'Invalid failed native geometry diagnostic schema')
    if 'windowPoints' in diagnostic:
        points=diagnostic['windowPoints']
        require(isinstance(points,list) and len(points)==2
                and all(number(item) and abs(item)<=10000 for item in points),
                'Unbounded failed native window diagnostic')
    if 'stage' in diagnostic:
        stage=diagnostic['stage']
        require(stage is None or isinstance(stage,dict) and set(stage)<={'side','portraitHeight','frameHeight','articulated'}
                and all(type(value) is bool if key=='articulated' else number(value) and abs(value)<=10000
                        for key,value in stage.items()),'Unbounded failed native stage diagnostic')
    if 'geometry' in diagnostic:
        geometry=diagnostic['geometry']
        require(isinstance(geometry,dict) and set(geometry)<=GEOMETRY_KEYS
                and all(rectangle(value) for value in geometry.values()),'Unbounded failed native CGRect diagnostic')
    return diagnostic


def contains(outer,inner,tolerance=1):
    return inner[0]>=outer[0]-tolerance and inner[1]>=outer[1]-tolerance \
        and inner[0]+inner[2]<=outer[0]+outer[2]+tolerance \
        and inner[1]+inner[3]<=outer[1]+outer[3]+tolerance


def disjoint(rectangles):
    for first in range(len(rectangles)):
        for second in range(first+1,len(rectangles)):
            overlap=intersection(rectangles[first],rectangles[second])
            if overlap[2]>1 and overlap[3]>1: return False
    return True


def validate_ready(data,phase,device):
    fields={'schema','phase','host','windowPoints','orientation','appearance','stage','geometry','viewportIntersectsStage',
            'actualHost','hostFrameMatchesPortrait','motionPausedForLayoutAudit',
            'keyboardVisible','composerEditing','candidateEnabled','dynamicTypeAccessibility','scrolled',
            'invitationPlacement','portraitVisible','chatControlsPlacement','scrollTarget','keyboardPresentedInitially',
            'sourceAvatarPath','agentID','resourceComplete','audioStarted','microphoneStarted','cameraStarted',
            'networkStarted','networkRequestsBlocked','blockedRequestCount',
            'physicalPhoneVerified','voiceOverVerified','batteryMeasured'}
    require(isinstance(data,dict) and set(data)==fields,'Native host readiness schema fields drift')
    host=phase.split('-',1)[0]
    policy=case_policy(phase)
    require(data['schema']=='kade.della-host-ready.v2' and data['phase']==phase and data['host']==host
            and data['actualHost']==('ConversationDetailView' if host=='chat' else 'CallView')
            and data['orientation']=='portrait'
            and data['appearance']==('dark' if phase.endswith('-dark') else 'light'),
            'Native requested actual host/case/orientation/appearance mismatch')
    require(data['motionPausedForLayoutAudit'] is True,'Native paused fixture mismatch')
    require(data['agentID']==AGENT_ID and data['sourceAvatarPath']==AVATAR_PATH
            and data['resourceComplete'] is True,'Original Della ownership/resources mismatch')
    for flag in ('audioStarted','microphoneStarted','cameraStarted','networkStarted',
                 'physicalPhoneVerified','voiceOverVerified','batteryMeasured'):
        require(data[flag] is False,'Silent host fixture/physical claim drift: '+flag)
    require(data['networkRequestsBlocked'] is True and type(data['blockedRequestCount']) is int
            and 0<=data['blockedRequestCount']<=1000,'Native offline network fence is not active')
    points=data['windowPoints']
    require(isinstance(points,list) and len(points)==2 and all(number(item) for item in points)
            and all(abs(actual-wanted)<=1 for actual,wanted in zip(points,device['points']))
            and points[1]>points[0],'Real portrait phone window dimensions mismatch')
    require(data['candidateEnabled'] is ('-off-' not in phase)
            and data['dynamicTypeAccessibility'] is ('-a11y-' in phase)
            and data['scrolled'] is ('-scrolled-' in phase),'Candidate/accessibility/scroll case mismatch')
    for key in ('keyboardVisible','keyboardPresentedInitially','composerEditing','portraitVisible'):
        require(data[key] is policy[key],'Requested actual host policy mismatch: '+key)
    for key in ('invitationPlacement','chatControlsPlacement','scrollTarget'):
        require(data[key]==policy[key],'Requested actual host policy mismatch: '+key)
    geometry=data['geometry']
    require(isinstance(geometry,dict) and set(geometry)<=GEOMETRY_KEYS
            and all(rectangle(value) for value in geometry.values()),'Invalid/unbounded native CGRect observations')
    required={'window','transcript','transcriptScroll','composer','chatControls','composerField',*CORE_BUTTONS,*VOICE_BUTTONS} \
        if host=='chat' else {'window','primaryControls','secondaryControls',*CALL_PRIMARY,*CALL_SECONDARY}
    if host=='chat' and phase not in ('chat-roomy-light','chat-small-light'): required.add('attachment')
    if policy['portraitVisible']: required.add('stage')
    require(required<=set(geometry),'Required actual host geometry missing')
    require(all(geometry[key][2]>0 and geometry[key][3]>0 for key in required),
            'Required actual host geometry has an empty frame')
    require(all(abs(actual-wanted)<=1 for actual,wanted in zip(geometry['window'],[0,0,*points])),
            'Measured native window and real phone dimensions disagree')
    stage=data['stage']
    if policy['portraitVisible']:
        require(data['hostFrameMatchesPortrait'] is True,'Native parent/child frame mismatch')
        require(isinstance(stage,dict) and set(stage)=={'side','portraitHeight','frameHeight','articulated'}
                and all(number(stage[key]) and 0<stage[key]<1000 for key in ('side','portraitHeight','frameHeight'))
                and type(stage['articulated']) is bool,'Settled stage schema invalid')
        portrait=stage['side']*620/414 if stage['articulated'] else stage['side']
        require(abs(stage['portraitHeight']-portrait)<=1
                and abs(stage['frameHeight']-(stage['portraitHeight']+40))<=1,'Natural parent/child stage height drift')
        if phase=='chat-roomy-light': sides={208};tall=True
        elif 'keyboard' in phase: sides={84};tall=False
        elif phase.endswith('-small-light'): sides={132};tall=False
        elif phase=='chat-packed-dark' or '-a11y-' in phase or ('-camera-' in phase and '-off-' not in phase):
            sides={104};tall=False
        elif '-off-' in phase: sides={208} if host=='chat' else {160,208};tall=False
        else: sides={160,208};tall=True
        require(any(abs(stage['side']-side)<=1 for side in sides) and stage['articulated'] is tall,
                'Requested host stage policy mismatch')
        require(abs(geometry['stage'][3]-stage['frameHeight'])<=1,'Measured stage and resolved child frame differ')
        viewport=geometry['window'] if host=='chat' else geometry.get('viewport',geometry.get('callViewport'))
        require(rectangle(viewport) and viewport[2]>0 and viewport[3]>0,'Actual host viewport geometry missing/empty')
        visible=intersection(geometry['stage'],viewport)
        require(data['viewportIntersectsStage'] is (visible[2]>0 and visible[3]>0),
                'Observed viewport/stage intersection mismatch')
    else:
        require(stage is None and data['hostFrameMatchesPortrait'] is None
                and data['viewportIntersectsStage'] is False and 'stage' not in geometry,
                'Hidden decoration must have null stage/frame match and no fake/stale CGRect')
        visible=[0,0,0,0]
    if host=='call':
        require(not {'invite','inviteTurnOn','inviteNotNow',*VOICE_BUTTONS}&set(geometry),
                'Call host unexpectedly contains chat controls/invitation')
        overlap=intersection(visible,geometry['primaryControls'])
        require(overlap[2]<=1 or overlap[3]<=1,'Visible portrait paints into fixed call controls')
        if '-camera-' in phase: require('camera' in geometry,'Requested synthetic camera geometry missing')
        require('keyboard' not in geometry,'Call fixture retained an unexpected keyboard frame')
        for key in (*CALL_PRIMARY,*CALL_SECONDARY):
            rect=geometry[key]
            require(rect[2]>=44 and rect[3]>=44,'Actual call button lacks a44pttarget: '+key)
        require(disjoint([geometry[key] for key in CALL_PRIMARY]),'Pinned primary call controls overlap')
        for key in CALL_PRIMARY:
            require(contains(geometry['window'],geometry[key]),'Pinned call button is outside the real screen: '+key)
        require(disjoint([geometry[key] for key in CALL_SECONDARY]),'Separate secondary call controls overlap')
        if policy['scrollTarget']=='callControls':
            viewport=geometry.get('viewport',geometry.get('callViewport'))
            for key in CALL_SECONDARY:
                require(contains(viewport,geometry[key]),'Scrolled call button is outside the actual viewport: '+key)
                require(contains(geometry['window'],geometry[key]),'Scrolled call button is outside the real screen: '+key)
            require(disjoint([geometry[key] for key in (*CALL_PRIMARY,*CALL_SECONDARY)]),
                    'Scrolled secondary call controls overlap pinned primary controls')
        return data
    transcript=geometry['transcript']
    native_scroll=geometry['transcriptScroll']
    require(transcript[3]>=44,'Actual transcript is smaller than one usable44ptrow')
    require(native_scroll[3]>=44,'Actual native transcript ScrollView is smaller than one usable44ptrow')
    require(contains(geometry['window'],transcript),'Actual transcript viewport is outside the real screen')
    require(contains(geometry['window'],native_scroll),
            'Actual native transcript ScrollView is outside the real screen')
    if '-a11y-' in phase:
        require(geometry['composerField'][2]>=points[0]-64,
                'Accessibility composer field does not retain nearly full real window width')
    footer_top=geometry['composer'][1]
    if policy['chatControlsPlacement']=='footer': footer_top=min(footer_top,geometry['chatControls'][1])
    if policy['invitationPlacement']=='footer': footer_top=min(footer_top,geometry.get('invite',[0,0,0,0])[1])
    require(transcript[1]+transcript[3]<=footer_top+1,'Actual transcript viewport overlaps the pinned chat footer')
    require(native_scroll[1]+native_scroll[3]<=footer_top+1,
            'Actual native transcript ScrollView overlaps the pinned chat footer')
    keyboard=policy['keyboardVisible']
    if keyboard:
        require('keyboard' in geometry and geometry['keyboard'][2]>0 and geometry['keyboard'][3]>0,
                'Requested software keyboard has no measured system frame')
        require(abs(geometry['keyboard'][0])<=1 and abs(geometry['keyboard'][2]-points[0])<=1,
                'Requested portrait keyboard does not span the native window')
        require(transcript[1]+transcript[3]<=geometry['keyboard'][1]+1,
                'Actual transcript viewport is covered by the software keyboard')
        require(native_scroll[1]+native_scroll[3]<=geometry['keyboard'][1]+1,
                'Actual native transcript ScrollView is covered by the software keyboard')
    else: require('keyboard' not in geometry,'Dismissed/absent keyboard retained a stale CGRect')
    pinned={'composer','composerField',*CORE_BUTTONS}
    if 'attachment' in required: pinned.add('attachment')
    if policy['chatControlsPlacement']=='footer': pinned.update({'chatControls',*VOICE_BUTTONS})
    invite_keys={'invite','inviteTurnOn','inviteNotNow'}
    if policy['invitationPlacement']=='none':
        require(not invite_keys&set(geometry),'Unexpected invitation geometry in empty-card case')
    else:
        require(invite_keys<=set(geometry),'Requested real invitation/button observations missing')
        if policy['invitationPlacement']=='footer': pinned.update(invite_keys)
    for key in pinned:
        rect=geometry[key]
        require(contains(geometry['window'],rect),'Required pinned chat control outside real screen: '+key)
        if keyboard: require(rect[1]+rect[3]<=geometry['keyboard'][1]+1,
                             'Required pinned chat control is covered by the actual keyboard: '+key)
    for key in (*CORE_BUTTONS,*VOICE_BUTTONS):
        rect=geometry[key]
        require(rect[2]>=44 and rect[3]>=44,'Actual chat button lacks a44pttarget: '+key)
    core=[geometry[key] for key in CORE_BUTTONS]
    require(disjoint(core) and disjoint(core+[geometry['composerField']]),
            'Pinned core chat actions overlap each other or the native editor')
    require(disjoint([geometry[key] for key in VOICE_BUTTONS]),'Separate voice/agent controls overlap')
    if policy['scrollTarget']=='invitation': targets=['inviteTurnOn','inviteNotNow']
    elif policy['scrollTarget']=='chatControls': targets=list(VOICE_BUTTONS)
    else: targets=[]
    for key in targets:
        rect=geometry[key]
        require(rect[2]>=44 and rect[3]>=44,'Scrolled chat button lacks a44pttarget: '+key)
        require(contains(transcript,rect),'Scrolled chat button is outside the actual transcript viewport: '+key)
        require(contains(native_scroll,rect),'Scrolled chat button is outside the actual native ScrollView: '+key)
        require(contains(geometry['window'],rect),'Scrolled chat button is outside the real screen: '+key)
        if keyboard: require(rect[1]+rect[3]<=geometry['keyboard'][1]+1,
                             'Scrolled chat button is covered by the actual keyboard: '+key)
    require(disjoint([geometry[key] for key in targets]),'Scrolled independent chat buttons overlap')
    return data


def capture(expected):
    initial=initial_source(expected)
    ui=json.loads((OUT/'ui-tests.json').read_text())
    require(ui.get('source')==initial and ui.get('passed') is True and ui.get('nativeUITreeVerified') is True
            and set(ui.get('phaseChecks',{}))==UI_PHASES,
            'Actual host capture requires both successful native UI device groups first')
    require(source(expected,require_staged=True)['inputs']==initial['inputs'],'Staged source changed')
    require(sys.platform=='darwin','Native host capture requires standard macOS')
    records=simulator_record(expected)['devices']
    receipt={'source':initial,'simulators':records,'captures':{},'captureTimings':{},'nativeReady':{},
             'nativeChecks':sorted(NATIVE_CHECKS),'passed':False,'nativeRenderingVerified':False,
             'nativeHostLayoutVerified':False,'physicalPhoneVerified':False,'voiceOverVerified':False,
             'batteryMeasured':False,'cameraStarted':False,'audioStarted':False,'microphoneStarted':False,
             'networkStarted':False,'captureTimeoutSeconds':CAPTURE_SECONDS,
             'aggregateCaptureTimeoutSeconds':AGGREGATE_CAPTURE_SECONDS,'readinessTimeoutSeconds':READY_SECONDS,
             'screenshotTimeoutSeconds':SCREENSHOT_SECONDS,'startedAtUtc':now()}
    aggregate_started=None
    aggregate_finished=None
    active_phase=None
    active_device=None
    try:
        require(APP.is_dir(),'Unsigned Debug host app missing')
        info=plistlib.loads((APP/'Info.plist').read_bytes())
        require(info.get('CFBundleIdentifier')==BUNDLE_ID and info.get('CFBundleShortVersionString')=='2.2.11'
                and str(info.get('CFBundleVersion'))=='100','Built app identity/version drift')
        require(info.get('DTPlatformName')=='iphonesimulator'
                or 'iPhoneSimulator' in info.get('CFBundleSupportedPlatforms',[]),'App is not the simulator target')
        require(info.get('UISupportedInterfaceOrientations')==['UIInterfaceOrientationPortrait'],
                'Host review must retain the actual phone portrait-only app declaration')
        require(not (APP/'_CodeSignature').exists(),'Signed app appeared in unsigned host review')
        receipt['builtApp']={'bundleId':BUNDLE_ID,'marketingVersion':'2.2.11','buildVersion':'100',
                             'platform':'iphonesimulator','infoPlistSha256':sha(APP/'Info.plist'),
                             'developerSigningIdentityUsed':False}
        for key,device in records.items():
            active_device=key; active_phase=None
            identifier=device['identifier']
            def global_remaining(bound):
                if aggregate_started is None: return bound
                seconds=aggregate_started+AGGREGATE_CAPTURE_SECONDS-time.monotonic()
                require(seconds>0,'Aggregate host capture watchdog expired during '+key+' setup')
                return min(bound,seconds)
            device['bootTimeoutSeconds']=BOOT_SECONDS
            device['bootReady']=False
            boot_started=time.monotonic()
            try:
                installed=json.loads(sim('list','devices','--json',timeout=global_remaining(45)))['devices']
                states={item['udid']:item.get('state') for items in installed.values() for item in items}
                if states.get(identifier)!='Booted': sim('boot',identifier,timeout=global_remaining(45))
                sim('bootstatus',identifier,'-b',timeout=global_remaining(BOOT_SECONDS))
                device['bootReady']=True
            finally:
                device['bootSeconds']=round(time.monotonic()-boot_started,3)
            device['installReady']=False; device['installTimeoutSeconds']=INSTALL_SECONDS
            install_started=time.monotonic()
            try:
                sim('install',identifier,str(APP),timeout=global_remaining(INSTALL_SECONDS))
                device['installReady']=True
            finally:
                device['installSeconds']=round(time.monotonic()-install_started,3)
            documents=Path(sim('get_app_container',identifier,BUNDLE_ID,'data',timeout=global_remaining(45)))/'Documents'
            documents.mkdir(exist_ok=True)
            if aggregate_started is None:
                aggregate_started=time.monotonic()
                receipt['captureStartedAtUtc']=now()
            aggregate_deadline=min(aggregate_started+AGGREGATE_CAPTURE_SECONDS,
                                   time.monotonic()+operation_remaining(AGGREGATE_CAPTURE_SECONDS))
            device_started=time.monotonic()
            deadline=min(device_started+CAPTURE_SECONDS,aggregate_deadline)
            device_phases=[phase for phase in PHASES if case_device(phase)==key]
            for index,phase in enumerate(device_phases):
                active_phase=phase
                phase_started=time.monotonic()
                timing={'startedAtUtc':now()}; receipt['captureTimings'][phase]=timing
                def remaining(bound):
                    seconds=deadline-time.monotonic()
                    require(seconds>0,'Host capture watchdog expired during '+phase)
                    return min(bound,seconds)
                try:
                    if index:
                        sim('terminate',identifier,BUNDLE_ID,timeout=remaining(30))
                    ready=documents/'della-host-ready.json'
                    ready.unlink(missing_ok=True)
                    # Configure the actual ephemeral device appearance as well
                    # as the fixture's SwiftUI preference. UIWindow then reports
                    # the requested native trait, not a hosting-only override.
                    sim('ui',identifier,'appearance','dark' if phase.endswith('-dark') else 'light',
                        timeout=remaining(30))
                    env=dict(os.environ,SIMCTL_CHILD_KADE_CHARACTER_AUDIT='1',SIMCTL_CHILD_KADE_A11Y_AUDIT='1',
                             SIMCTL_CHILD_KADE_DELLA_HOST_AUDIT='1',SIMCTL_CHILD_KADE_DELLA_HOST_CASE=phase,
                             SIMCTL_CHILD_KADE_DELLA_HOST_UI_DRAG='0',
                             SIMCTL_CHILD_KADE_PUPPET_LAB='0',SIMCTL_CHILD_KADE_DELLA_ARTICULATED_AUDIT='0',
                             SIMCTL_CHILD_KADE_CHAT_LAYOUT_AUDIT='0',SIMCTL_CHILD_KADE_CALL_LAYOUT_AUDIT='0',
                             SIMCTL_CHILD_KADE_TOUR='0')
                    launch_started=time.monotonic()
                    sim('launch','--stdout='+str(OUT/(phase+'.stdout')),'--stderr='+str(OUT/(phase+'.stderr')),
                        identifier,BUNDLE_ID,env=env,timeout=remaining(45))
                    timing['launchSeconds']=round(time.monotonic()-launch_started,3)
                    ready_started=time.monotonic()
                    ready_deadline=min(deadline,ready_started+READY_SECONDS)
                    while not ready.exists() and time.monotonic()<ready_deadline:
                        time.sleep(min(.15,max(0,ready_deadline-time.monotonic())))
                    require(ready.exists() and time.monotonic()<=ready_deadline,
                            'Native host readiness timed out for '+phase)
                    require(ready.stat().st_size<=64*1024,'Oversized native host readiness')
                    raw_ready=json.loads(ready.read_text())
                    try:
                        data=validate_ready(raw_ready,phase,device)
                    except Exception:
                        receipt['failedNativeGeometry']=failed_native_geometry(raw_ready,phase)
                        raise
                    receipt['nativeReady'][phase]=data
                    timing['readySeconds']=round(time.monotonic()-ready_started,3)
                    timing['readyValidatedAtUtc']=now()
                    screenshot_started=time.monotonic()
                    path=OUT/('della-host-'+phase+'.png')
                    sim('io',identifier,'screenshot',str(path),timeout=remaining(SCREENSHOT_SECONDS))
                    timing['screenshotSeconds']=round(time.monotonic()-screenshot_started,3)
                    metadata=png(path)
                    require(all(abs(pixel-point*device['scale'])<=2 for pixel,point in zip(metadata['pixels'],data['windowPoints'])),
                            'Real portrait screenshot pixels and native window points differ')
                    receipt['captures'][phase]=metadata
                    remaining(1)
                finally:
                    timing['elapsedSeconds']=round(time.monotonic()-phase_started,3)
                    timing['captureElapsedSeconds']=round(time.monotonic()-aggregate_started,3)
            device['captureSeconds']=round(time.monotonic()-device_started,3)
            require(device['captureSeconds']<CAPTURE_SECONDS,'Per-device host capture exceeded480-second cap')
            if key=='large':
                # Avoid running two memory-heavy simulators at the same time.
                sim('shutdown',identifier,timeout=global_remaining(30))
        aggregate_finished=time.monotonic()
        require(aggregate_finished<aggregate_started+AGGREGATE_CAPTURE_SECONDS,'Aggregate capture exceeded960-second cap')
        require(set(receipt['captures'])==set(receipt['nativeReady'])==required_phases(),'Twenty-eight actual host cases incomplete')
        require(source(expected,require_staged=True)['inputs']==initial['inputs'],'Source changed during host capture')
        receipt.update(passed=True,nativeRenderingVerified=True,nativeHostLayoutVerified=True)
    except Exception as error:
        receipt.update(passed=False,nativeRenderingVerified=False,nativeHostLayoutVerified=False)
        receipt['errorType']=type(error).__name__
        receipt['error']=str(error) if isinstance(error,RuntimeError) else 'Simulator operation failed; inspect bounded normal logs'
        if active_phase is not None:
            receipt['failedPhase']=active_phase
        if active_device is not None:
            receipt['failedDevice']=active_device
        if isinstance(error,(subprocess.CalledProcessError,subprocess.TimeoutExpired)):
            if isinstance(error.cmd,(tuple,list)) and len(error.cmd)>2:
                receipt['failedOperation']=str(error.cmd[2])
            if isinstance(error,subprocess.TimeoutExpired):
                receipt['timeoutSeconds']=error.timeout
        raise
    finally:
        if aggregate_started is not None:
            receipt['aggregateCaptureElapsedSeconds']=round((aggregate_finished or time.monotonic())-aggregate_started,3)
        receipt['finishedAtUtc']=now()
        save('receipt.json',receipt)
        for device in records.values():
            try: sim('shutdown',device['identifier'],timeout=30)
            except Exception: pass
    return {'passed':True,'screenshots':len(receipt['captures']),'source':expected,
            'nativeHostLayoutVerified':True,'physicalPhoneVerified':False}


def ui_tests(expected):
    initial=initial_source(expected)
    report={'source':initial,'passed':False,'nativeUITreeVerified':False,'voiceOverVerified':False,
            'physicalPhoneVerified':False,'startedAtUtc':now(),'phaseChecks':{},'deviceResults':{},'checks':0}
    failures=[]
    try:
        for device,count in UI_COUNTS.items():
            result={'passed':False,'phaseChecks':{},'expectedTestCount':count}
            report['deviceResults'][device]=result
            try:
                boot_path=OUT/('ui-boot-'+device+'.json')
                if boot_path.exists():
                    boot=json.loads(boot_path.read_text())
                    result['boot']=validate_ui_boot(boot,device,initial)
                launch_path=OUT/('ui-run-'+device+'.json')
                launch=None
                if launch_path.exists():
                    launch=json.loads(launch_path.read_text())
                    result['launch']=validate_ui_launch(launch,device,initial)
                phases=set(ui_methods(device).values())
                log_path=OUT/('ui-tests-'+device+'.log')
                require(log_path.stat().st_size<=8*1024*1024,'Oversized synthetic UI test log for '+device)
                log=log_path.read_text(encoding='utf-8',errors='replace')
                if launch is None:
                    launch=ui_launch_record(initial,device)
                    launch.update(status='interrupted',startupStage='processStarted',
                                  errorType='MissingLauncherReceipt',outerTimeoutPossible=True)
                    for line in log.splitlines():observe_ui_line(launch,line[:4096],device)
                result['launch']=validate_ui_launch(launch,device,initial)
                result['logSha256']=sha(log_path)
                matches=re.findall(r'KADE_DELLA_HOST_CONTROLS_PASSED (\d+) ([a-z0-9-]+)',log)
                require(len(matches)<=count and len({phase for _,phase in matches})==len(matches)
                        and all(phase in phases and 0<int(checks)<=1000 for checks,phase in matches),
                        'Invalid/duplicate cross-device UI controls markers for '+device)
                result['phaseChecks']={phase:int(checks) for checks,phase in matches}
                report['phaseChecks'].update(result['phaseChecks'])
                require(launch.get('passed') is True and launch.get('exitCode')==0,
                        'Targeted native UI test process did not succeed for '+device)
                require('KADE_DELLA_HOST_CONTROLS_FAILED' not in log,
                        'Native UI controls failure marker present for '+device)
                require(len(matches)==count and set(result['phaseChecks'])==phases,
                        'Exact targeted UI controls markers incomplete for '+device)
                bundle=OUT/('ui-tests-'+device+'.xcresult')
                require(bundle.is_dir(),'Native UI result bundle missing for '+device)
                raw=subprocess.check_output(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle)],
                                            text=True,stderr=subprocess.PIPE,timeout=operation_remaining(30))
                require(len(raw)<=1024*1024,'Oversized UI test summary for '+device)
                summary=json.loads(raw)
                counts={key:summary.get(key) for key in ('totalTestCount','passedTests','failedTests','skippedTests')}
                result['xcresultCounts']=counts
                require(all(type(value) is int for value in counts.values()) and counts=={
                    'totalTestCount':count,'passedTests':count,'failedTests':0,'skippedTests':0},
                    'Native xcresult did not prove the exact successful UI test group for '+device)
                if 'expectedFailures' in summary:
                    require(type(summary['expectedFailures']) is int and summary['expectedFailures']==0,
                            'Expected native UI test failures appeared for '+device)
                    counts['expectedFailures']=0
                result['passed']=True
            except Exception as error:
                result.update(passed=False,errorType=type(error).__name__,
                              error=str(error) if isinstance(error,RuntimeError) else 'UI result operation failed for '+device)
                failures.append(device)
            finally:
                if 'boot' in result:
                    print('KADE_DELLA_HOST_UI_BOOT_DIAGNOSTIC '+json.dumps({
                        'device':device,**{name:result['boot'].get(name) for name in
                        ('passed','identifier','alreadyBooted','elapsedSeconds','errorType','error')}},separators=(',',':')),flush=True)
                if 'launch' in result:
                    print('KADE_DELLA_HOST_UI_DIAGNOSTIC '+json.dumps({
                        'device':device,**{name:result['launch'].get(name) for name in
                        ('status','startupStage','timedOut','logLimitExceeded','lastStartedMethod',
                         'exitCode','elapsedSeconds','testElapsedSeconds','testMethods','failureLines','startupMessages','activityMessages')}},
                        separators=(',',':')),flush=True)
        report['checks']=sum(report['phaseChecks'].values())
        require(not failures,'Native UI device groups incomplete or failed: '+','.join(failures))
        require(set(report['phaseChecks'])==UI_PHASES,'Twenty-four targeted native UI phases incomplete')
        require(source(expected)['inputs']==initial['inputs'],'Source changed during UI controls tests')
        aggregate={key:sum(result['xcresultCounts'][key] for result in report['deviceResults'].values())
                   for key in ('totalTestCount','passedTests','failedTests','skippedTests')}
        require(aggregate=={'totalTestCount':24,'passedTests':24,'failedTests':0,'skippedTests':0},
                'Native aggregate result did not prove twenty-four successful UI tests')
        report.update(passed=True,nativeUITreeVerified=True,xcresultCounts=aggregate)
    except Exception as error:
        report.update(passed=False,nativeUITreeVerified=False,errorType=type(error).__name__,
                      error=str(error) if isinstance(error,RuntimeError) else 'UI result operation failed; inspect normal step logs')
        raise
    finally:
        report['finishedAtUtc']=now()
        save('ui-tests.json',report)
    return {key:report[key] for key in ('passed','nativeUITreeVerified','checks','phaseChecks','deviceResults','voiceOverVerified')}


def emit(expected):
    initial=initial_source(expected)
    files={'source.json':(OUT/'source.json').read_bytes()}
    if (OUT/'receipt.json').exists():
        receipt=json.loads((OUT/'receipt.json').read_text())
        require(receipt.get('source')==initial,'Host capture source receipt drift')
        files['receipt.json']=(OUT/'receipt.json').read_bytes()
        for phase,metadata in receipt.get('captures',{}).items():
            require(phase in required_phases() and metadata['file']=='della-host-'+phase+'.png','Unsafe host screenshot name')
            path=OUT/metadata['file']
            require(png(path)==metadata,'Captured host PNG changed before packaging')
            files[path.name]=path.read_bytes()
    if (OUT/'ui-tests.json').exists():
        report=json.loads((OUT/'ui-tests.json').read_text())
        require(report.get('source')==initial,'UI result source receipt drift')
        files['ui-tests.json']=(OUT/'ui-tests.json').read_bytes()
    require(len(files)+1<=MAX_FILES and sum(map(len,files.values()))<=MAX_RAW,'Bounded host evidence exceeds count/raw size')
    manifest={'schema':'kade.della-host-log-evidence.v1','sha':expected,
              'files':{name:{'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()} for name,data in files.items()},
              'artifactStorageUsed':False,'ipaIncluded':False,'physicalPhoneVerified':False,'voiceOverVerified':False}
    files['evidence-manifest.json']=(json.dumps(manifest,indent=2)+'\n').encode()
    require(sum(map(len,files.values()))<=MAX_RAW,'Final host evidence exceeds50MiB raw cap')
    buffer=BytesIO()
    allowed={('della-host-'+phase+'.png') for phase in required_phases()}|{'source.json','receipt.json','ui-tests.json','evidence-manifest.json'}
    with zipfile.ZipFile(buffer,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for name,data in sorted(files.items()):
            require(name in allowed and Path(name).name==name,'Disallowed host evidence member')
            archive.writestr(name,data)
    archive=buffer.getvalue()
    require(len(archive)<=MAX_ARCHIVE,'Host archive exceeds32MiB; refuse transport')
    encoded=base64.b64encode(archive).decode('ascii')
    require(len(encoded)<=MAX_ENCODED,'Host encoding exceeds44MiB; refuse transport')
    digest=hashlib.sha256(archive).hexdigest()
    chunks=[encoded[index:index+16384] for index in range(0,len(encoded),16384)]
    header={'schema':'kade.della-host-log-evidence.v1','sha':expected,'archiveSha256':digest,
            'archiveBytes':len(archive),'encodedBytes':len(encoded),'chunks':len(chunks),'files':len(files),
            'encoding':'base64','artifactStorageUsed':False}
    print('KADE_DELLA_HOST_QA_BEGIN '+json.dumps(header,separators=(',',':')),flush=True)
    for index,chunk in enumerate(chunks,1):
        operation_remaining(1)
        print(f'KADE_DELLA_HOST_QA_CHUNK {index:06d} '+chunk,flush=True)
    print('KADE_DELLA_HOST_QA_END '+digest,flush=True)


def main():
    global _OPERATION_DEADLINE, _DEADLINE_ROLE
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('source','preflight','device','shutdown','selectors','build-tests','compiled-tests','boot-ui','run-ui','capture','ui-tests','clean-review','emit'))
    parser.add_argument('--expected-sha',required=True)
    parser.add_argument('--device',choices=('large','small'),default='large')
    args=parser.parse_args()
    if args.action not in ('source','ui-tests','clean-review','emit','shutdown'):
        recorded=json.loads((OUT/'source.json').read_text())
        _OPERATION_DEADLINE=datetime.fromisoformat(recorded['operationDeadlineUtc']).timestamp()
        if args.action in ('run-ui','build-tests'):
            guard=(720 if args.device=='large' else 600) if args.action=='run-ui' else 960
            action_deadline=time.time()+guard-30
            if action_deadline<_OPERATION_DEADLINE:
                _OPERATION_DEADLINE=action_deadline;_DEADLINE_ROLE='actionGuardDeadline'
    elif args.action in ('ui-tests','clean-review','emit'):
        recorded=json.loads((OUT/'source.json').read_text())
        started=datetime.fromisoformat(recorded['operationStartedAtUtc']).timestamp()
        budget,reserve={'ui-tests':(90,90),'clean-review':(15,75),'emit':(60,15)}[args.action]
        _OPERATION_DEADLINE=min(time.time()+budget,started+JOB_SECONDS-reserve)
    if args.action=='source':
        result=source(args.expected_sha,clean=True)
        started=os.environ.get('KADE_HOST_OPERATION_STARTED_UTC',result['checkedAtUtc'])
        deadline=os.environ.get('KADE_HOST_OPERATION_DEADLINE_UTC',
                                (datetime.fromisoformat(started)+timedelta(seconds=OPERATION_SECONDS)).isoformat())
        require(abs((datetime.fromisoformat(deadline)-datetime.fromisoformat(started)).total_seconds()-OPERATION_SECONDS)<2,
                'Shared operation deadline must be initialized once before checkout')
        result.update(operationStartedAtUtc=started,operationDeadlineUtc=deadline,
                      operationTimeoutSeconds=OPERATION_SECONDS,jobTimeoutSeconds=JOB_SECONDS,
                      finalReceiptReserveSeconds=FINAL_RESERVE_SECONDS)
        validate_operation_source(result)
        save('source.json',result)
    elif args.action=='preflight': result=simulator_preflight(args.expected_sha)
    elif args.action=='build-tests': result=build_tests(args.expected_sha)
    elif args.action=='compiled-tests': result=compiled_tests(args.expected_sha);save('compiled-tests.json',result)
    elif args.action=='boot-ui': result=boot_ui(args.expected_sha,args.device)
    elif args.action=='run-ui': result=run_ui(args.expected_sha,args.device)
    elif args.action=='device':
        print(simulator_record(args.expected_sha)['devices'][args.device]['identifier']); result=None
    elif args.action=='selectors':
        initial_source(args.expected_sha)
        for method in ui_methods(args.device):
            print('-only-testing:KadeAIUITests/DellaHostControlsUITests/'+method)
        result=None
    elif args.action=='shutdown':
        identifier=simulator_record(args.expected_sha)['devices'][args.device]['identifier']
        try:
            sim('shutdown',identifier,timeout=30)
            stopped=True
        except (subprocess.CalledProcessError,subprocess.TimeoutExpired): stopped=False
        result={'shutdownRequested':True,'device':args.device,'ready':stopped}
    elif args.action=='capture': result=capture(args.expected_sha)
    elif args.action=='ui-tests': result=ui_tests(args.expected_sha)
    elif args.action=='clean-review':
        subprocess.check_call([sys.executable,str(ROOT/'dev/prepare-della-articulated-review.py'),'--clean'],
                              timeout=operation_remaining(15));result={'optionalStudyCatalogCleaned':True}
    else: emit(args.expected_sha); result=None
    if result is not None: print(json.dumps(result,indent=2))


if __name__=='__main__':
    try: main()
    except Exception as error:
        print(json.dumps({'ok':False,'errorType':type(error).__name__,
                          'message':str(error) if isinstance(error,RuntimeError) else 'Host audit operation failed'}),file=sys.stderr)
        raise SystemExit(1)

