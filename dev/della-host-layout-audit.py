"""Exact-source silent actual-host simulator QA; bounded evidence uses logs only.

This separate lane verifies the registered puppet and preserves the prior art audit. Only
synthetic host readiness, PNGs and receipts enter the bounded evidence archive.
No server, signing, app package, account transcript, artifact storage or release.
"""
import argparse
import base64
import ctypes
from datetime import datetime, timedelta, timezone
import errno
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
BRANCH='codex/puppet-completion-host-20261011'
BUNDLE_ID='com.kademurdock.kadeai'
APP=ROOT/'build/della-host-layout-simulator/Build/Products/Debug-iphonesimulator/KadeAI.app'
MASTER_SHA='285b6e1f176b79ba08cfc7a4252a3d8864901eabbdcbc1e58f304299164206d2'
PINS={
    'Sources/Assets.xcassets/CharacterDellaFaces.imageset/della-expressions.jpg':'b8d2c80015f81c59909e4a61615ce0815ed5c763d63eec0d6e22d2b4a801c4de',
    'dev/puppet-review-assets/della-head-alpha.png':'036d2ce6292fec1cb0226fe69f584789d46eadf4625e925e293ed717fecc1b1a',
    'dev/puppet-review-assets/della-body-plate.png':'e0709e31501d6b3e2b59a18c7cff93e1012b411e489b9ba9f956e8b72281018e',
    'dev/della-articulated-review/della-body-gesture-master-v1.png':MASTER_SHA,
    'Sources/Assets.xcassets/CharacterDellaArticulatedReview.imageset/della-body-gesture-master-v1.png':MASTER_SHA,
    'Sources/CharacterPortraitView.swift':'ec73a0cc03a2ae6034dacae43c348228fb9ff6bf891efcd85301b229cd1aaaaa',
    'Sources/CharacterDellaArticulatedGeometry.swift':'c893524c79bb7226bf0498bcfb42cd08331ab60983b3233689e58b106c085d7f',
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
    'Sources/Assets.xcassets/CharacterDellaArticulatedReview.imageset/Contents.json',
    'Sources/CharacterConversationBodyArtwork.swift','Sources/CharacterConversationBodyGeometry.swift',
    'Sources/CharacterConversationBodyView.swift','Sources/CharacterConversationHostReview.swift',
    'Sources/CharacterPuppetCompletionAudit.swift','Sources/CharacterPuppetCompletionAuditView.swift',
    'UITests/PuppetCompletionUITests.swift','dev/puppet-completion-audit.py',
    'Sources/CharacterPerformance.swift','Sources/CharacterFigureMotion.swift',
    'Sources/CharacterAnimationBudget.swift','Sources/KadeMotionPolicy.swift',
    'Sources/CharacterAngelVectorMotion.swift','Sources/CharacterAngelVectorView.swift',
    'Sources/CharacterAngelVectorArt.swift','Sources/VoiceService.swift','Sources/StreamingCallService.swift',
    'CharacterMotionTests/CharacterBodyPerformanceTests.swift',
    'CharacterMotionTests/CharacterAnimationBudgetTests.swift',
    'CharacterMotionTests/CharacterConversationBodyTests.swift',
    'CharacterMotionTests/CharacterOutputEpisodeTests.swift',
    'CharacterMotionTests/AngelVectorMotionTests.swift',
    'dev/puppet-completion/protocol-tests.py',
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
PREFLIGHT_CONTAINER_SECONDS=90
PREFLIGHT_LAUNCH_SECONDS=120
PREFLIGHT_STOP_SECONDS=5
PREFLIGHT_DRAIN_SECONDS=2
PREFLIGHT_OUTPUT_BYTES=64*1024
UI_SECONDS={'large':600,'small':480}
UI_LOG_BYTES=8*1024*1024
UI_STOP_SECONDS=10
EXPECTED_MODEL_CHECKS=169760
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


def png_framebuffer(idat,width,height,header):
    depth,color,compression,filter_method,interlace=header
    require(depth==8 and color in (2,6) and compression==filter_method==interlace==0,
            'Unsupported simulator PNG framebuffer format')
    channels=3 if color==2 else 4
    row_bytes=width*channels;stride=row_bytes+1;expected=stride*height
    require(expected<=72_006_000,'Oversized decoded PNG framebuffer')
    try:
        stream=zlib.decompressobj()
        raw=stream.decompress(idat,expected+1)
    except zlib.error:
        raise RuntimeError('Invalid PNG framebuffer compression') from None
    require(len(raw)==expected and stream.eof and not stream.unused_data and not stream.unconsumed_tail,
            'Incomplete, extra or oversized decoded PNG framebuffer')
    require(all(raw[offset]<=4 for offset in range(0,expected,stride)),
            'Invalid PNG framebuffer row filter')
    # A uniform framebuffer has a known filtered encoding. Compare in native
    # bytes operations so an entirely black image never needs a pixel loop.
    pixel=raw[1:1+channels];zeros=b'\0'*row_bytes
    repeat=pixel*width;sub=pixel+zeros[channels:]
    half=bytes((value+1)//2 for value in pixel)
    first=(repeat,sub,repeat,pixel+half*(width-1),sub)
    later=(repeat,sub,zeros,half+zeros[channels:],zeros)
    uniform=True
    for y,offset in enumerate(range(0,expected,stride)):
        patterns=first if y==0 else later
        if raw[offset+1:offset+stride]!=patterns[raw[offset]]:
            uniform=False;break
    require(not uniform,'Uniform PNG framebuffer contains no visible app content')
    previous=bytearray(row_bytes);first_visible=None
    for offset in range(0,expected,stride):
        kind=raw[offset];row=bytearray(raw[offset+1:offset+stride])
        if kind:
            for index in range(row_bytes):
                left=row[index-channels] if index>=channels else 0
                up=previous[index];upper_left=previous[index-channels] if index>=channels else 0
                if kind==1:predictor=left
                elif kind==2:predictor=up
                elif kind==3:predictor=(left+up)//2
                else:
                    estimate=left+up-upper_left
                    distances=(abs(estimate-left),abs(estimate-up),abs(estimate-upper_left))
                    predictor=(left if distances[0]<=distances[1] and distances[0]<=distances[2]
                               else up if distances[1]<=distances[2] else upper_left)
                row[index]=(row[index]+predictor)&255
        for index in range(0,row_bytes,channels):
            if channels==4 and row[index+3]==0:continue
            visible=bytes(row[index:index+3])
            if first_visible is None:first_visible=visible
            elif visible!=first_visible:return
        previous=row
    require(False,'PNG framebuffer contains no varying visible app content')


def png(path):
    data=path.read_bytes()
    require(33<=len(data)<=MAX_SCREENSHOT and data[:8]==b'\x89PNG\r\n\x1a\n'
            and data[8:16]==b'\x00\x00\x00\x0dIHDR','Missing/oversized/invalid PNG capture')
    width,height,*header=struct.unpack('>IIBBBBB',data[16:29])
    require(320<=width<=3000 and 600<=height<=6000,'Unexpected simulator PNG dimensions')
    cursor=8
    kinds=[];idat=[];idat_closed=False
    while cursor<len(data):
        require(cursor+12<=len(data),'Truncated PNG chunk')
        length=struct.unpack('>I',data[cursor:cursor+4])[0]
        kind=data[cursor+4:cursor+8]
        require(all(65<=value<=90 or 97<=value<=122 for value in kind) and not kind[2]&32,
                'Invalid PNG chunk type')
        require(kind[0]&32 or kind in (b'IHDR',b'PLTE',b'IDAT',b'IEND'),
                'Unsupported critical PNG framebuffer chunk')
        require(kind!=b'tRNS','Unsupported PNG framebuffer transparency chunk')
        end=cursor+12+length
        require(end<=len(data),'Truncated PNG payload')
        payload=data[cursor+8:cursor+8+length]
        expected_crc=struct.unpack('>I',data[cursor+8+length:end])[0]
        require(zlib.crc32(kind+payload)&0xffffffff==expected_crc,'Corrupt PNG chunk CRC')
        if kind==b'PLTE':require(3<=length<=768 and length%3==0 and not idat and kind not in kinds,
                                 'Invalid PNG palette chunk')
        if kind==b'IDAT':
            require(not idat_closed,'Noncontiguous PNG framebuffer data')
            idat.append(payload)
        elif idat:idat_closed=True
        if kind==b'IEND':require(length==0,'Invalid PNG end chunk')
        kinds.append(kind)
        cursor=end
        if kind==b'IEND':
            break
    require(kinds and kinds[0]==b'IHDR' and kinds.count(b'IHDR')==1 and kinds[-1]==b'IEND' and b'IDAT' in kinds
            and cursor==len(data),'Incomplete PNG image stream')
    png_framebuffer(b''.join(idat),width,height,header)
    return {'file':path.name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),
            'pixels':[width,height]}


def required_phases():
    require(len(PHASES)==len(set(PHASES))==28 and bool(HOST_MODEL_INPUTS) and bool(NATIVE_CHECKS),
            'Host fixture phase/source/readiness contract drift')
    require(len(UI_METHODS)==len(UI_PHASES)==24 and set(UI_METHODS.values())==UI_PHASES,
            'Targeted two-device UI method/phase contract drift')
    require(all(re.fullmatch(r'(chat|call)-[a-z0-9-]+',phase) for phase in PHASES),
            'Invalid frozen host case label')
    require(len(set(PINS)|set(SOURCE_INPUTS)|set(HOST_MODEL_INPUTS))==59 and len(PINS)==7
            and PINS.get('Sources/Assets.xcassets/CharacterDellaArticulatedReview.imageset/della-body-gesture-master-v1.png')==MASTER_SHA
            and 'Sources/Assets.xcassets/CharacterDellaArticulatedReview.imageset/Contents.json' in SOURCE_INPUTS,
            'Exact registered production source/catalog pin contract drift')
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
    # The legacy staged check now always verifies the committed production catalog.
    validate_registered_catalog(data)
    for name in SOURCE_INPUTS+HOST_MODEL_INPUTS:
        inputs[name]=sha(ROOT/name)
    declared=set(re.findall(r'\bfunc (test[A-Za-z]+)\(',
                            (ROOT/'UITests/DellaHostControlsUITests.swift').read_text(encoding='utf-8')))
    require(declared==set(UI_METHODS),'Exact native UI method/device selector source drift')
    return {'schema':'kade.della-host-native-source.v2','sha':expected,'repository':REPOSITORY,
            'branch':BRANCH,'inputs':inputs,'checkedAtUtc':now(),'unsignedSimulatorOnly':True,
            'releasePublished':False,'physicalPhoneVerified':False,'batteryPerformanceVerified':False,
            'physicalVoiceOverVerified':False,'audioStarted':False,'microphoneStarted':False,
            'cameraStarted':False,'networkStarted':False}


def validate_registered_catalog(data):
    catalog=ROOT/'Sources/Assets.xcassets/CharacterDellaArticulatedReview.imageset'
    require(catalog.is_dir(),'Registered production Della catalog is missing')
    require({path.name for path in catalog.iterdir()}=={'della-body-gesture-master-v1.png','Contents.json'},
            'Registered production Della catalog file set drift')
    contents=catalog/'Contents.json';image=catalog/'della-body-gesture-master-v1.png'
    require(contents.is_file() and 0<contents.stat().st_size<=64*1024,
            'Registered production Della catalog metadata missing or oversized')
    require(json.loads(contents.read_text())=={'images':[{'filename':image.name,'idiom':'universal'}],
                                              'info':{'author':'xcode','version':1}},
            'Registered production Della catalog metadata drift')
    require(image.is_file() and image.stat().st_size==len(data) and image.read_bytes()==data
            and hashlib.sha256(data).hexdigest()==MASTER_SHA,'Registered production Della master byte drift')
    return True


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


def compiled_tests(expected,emit_inventory=True):
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
    if emit_inventory:
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
            require(all(not (path/name).exists() and not (path/name).is_symlink()
                        for name in ('KadeAI.debug.dylib','__preview.dylib')),
                    'Compiled app code is split from the fingerprinted main executable')
            require(info.get('CFBundleShortVersionString')=='2.2.13' and str(info.get('CFBundleVersion'))=='100'
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
    if 'appPreflight' in report:
        require(key=='large','Only the Pro Max performs the offline app preflight')
        validate_app_preflight(report['appPreflight'],report.get('identifier'),initial)
        require(report['appPreflight']['elapsedSeconds']<=report.get('elapsedSeconds',-1)+.01,
                'Offline app preflight exceeds the shared UI boot envelope')
    require(number(report.get('elapsedSeconds')) and 0<=report['elapsedSeconds']<=BOOT_SECONDS+5,
            'Unbounded explicit UI boot elapsed time')
    if report['passed']:
        require('identifier' in report and 'alreadyBooted' in report and 'errorType' not in report
                and report['elapsedSeconds']<=BOOT_SECONDS+1,'Failed explicit UI boot retained success')
        if key=='large':require(report.get('appPreflight',{}).get('passed') is True,
                                'Successful Pro Max boot requires the actual offline app preflight')
    return report


def validate_app_preflight(report,identifier,initial):
    required={'schema','source','device','identifier','phase','timeoutSeconds','noScreenshot','passed',
              'compiledBeforeVerified','compiledAfterVerified','freshReadiness','readyValidated','terminated',
              'operationSeconds','status','startedAtUtc','finishedAtUtc','elapsedSeconds'}
    optional={'compiledRunner','readySha256','errorType','error','cleanupErrorType','cleanupError','commandOperations',
              'ownedProcess','ownedTermination','compiledAfterErrorType','compiledAfterError'}
    require(isinstance(report,dict) and report.get('schema')=='kade.della-host-app-preflight.v2'
            and required<=set(report)<=required|optional
            and report.get('source')==initial and report.get('device')=='large'
            and isinstance(identifier,str) and re.fullmatch(
                r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}',identifier)
            and report.get('identifier')==identifier and report.get('phase')=='call-a11y-dark'
            and report.get('timeoutSeconds')==BOOT_SECONDS and report.get('noScreenshot') is True,
            'Offline app preflight source/device/phase contract mismatch')
    flags=('passed','compiledBeforeVerified','compiledAfterVerified','freshReadiness','readyValidated','terminated')
    require(all(type(report.get(field)) is bool for field in flags),'Invalid offline app preflight status')
    require(number(report.get('elapsedSeconds')) and 0<=report['elapsedSeconds']<=BOOT_SECONDS+1,
            'Unbounded offline app preflight elapsed time')
    require(report.get('status') in ('preparing','installing','launching','waitingForReadiness','failed','completed')
            and all(isinstance(report[field],str) and 0<len(report[field])<=320
                    for field in ('errorType','error','cleanupErrorType','cleanupError','compiledAfterErrorType','compiledAfterError') if field in report),
            'Invalid offline app preflight bounded diagnostic')
    started=datetime.fromisoformat(report['startedAtUtc']);finished=datetime.fromisoformat(report['finishedAtUtc'])
    require(started.tzinfo is not None and finished.tzinfo is not None and started<=finished
            and (finished-started).total_seconds()<=BOOT_SECONDS+1,'Invalid offline app preflight timestamp order')
    durations=report.get('operationSeconds')
    bounds={'compiledBefore':BOOT_SECONDS,'install':INSTALL_SECONDS,'appearance':30,'container':PREFLIGHT_CONTAINER_SECONDS,
            'launch':PREFLIGHT_LAUNCH_SECONDS,'readiness':READY_SECONDS,'ownedProcess':BOOT_SECONDS,
            'ownedTermination':30,'compiledAfter':BOOT_SECONDS}
    grace=2*PREFLIGHT_STOP_SECONDS+PREFLIGHT_DRAIN_SECONDS
    require(isinstance(durations,dict) and set(durations)<=set(bounds)
            and all(number(value) and 0<=value<=bounds[key]+(grace if key in
                    ('install','appearance','container','launch') else 0)+1
                    for key,value in durations.items()),
            'Unbounded offline app preflight operation timing')
    require(sum(durations.values())<=report['elapsedSeconds']+1,
            'Offline app preflight operations exceed its elapsed time')
    if 'compiledRunner' in report:validate_compiled_record(report['compiledRunner'],initial)
    if 'readySha256' in report:require(re.fullmatch(r'[a-f0-9]{64}',report['readySha256']),
                                     'Invalid offline app preflight readiness hash')
    commands=report.get('commandOperations',{})
    expected={'install':'install','appearance':'ui','container':'get_app_container','launch':'launch'}
    require(isinstance(commands,dict) and set(commands)<=set(expected),'Unknown offline app preflight command')
    for key,command in commands.items():
        validate_preflight_command(command,expected[key],bounds[key])
    owned=report.get('ownedProcess')
    if owned is not None:
        validate_owned_process(owned,identifier,report.get('compiledRunner'))
        require(started<=datetime.fromisoformat(owned['launchStartedAtUtc'])<=
                datetime.fromisoformat(owned['capturedAtUtc'])<=finished,
                'Owned process observation is outside this exact preflight launch')
    if 'ownedTermination' in report:
        validate_owned_termination(report['ownedTermination'],owned)
        require(report['terminated']==report['ownedTermination']['passed'],
                'Preflight termination flag contradicts the observed owned process exit')
    if report['passed']:
        require(all(report[field] for field in flags) and set(durations)==set(bounds)
                and 'compiledRunner' in report and 'readySha256' in report
                and set(commands)==set(expected) and all(command['passed'] for command in commands.values())
                and owned is not None and report.get('ownedTermination',{}).get('passed') is True
                and report.get('status')=='completed' and not any(key in report for key in
                    ('errorType','cleanupErrorType','compiledAfterErrorType')),
                'Incomplete offline app preflight retained success')
    return report


def validate_preflight_command(report,operation,bound):
    required={'operation','timeoutSeconds','stopTimeoutSeconds','killTimeoutSeconds','drainTimeoutSeconds',
              'outputLimitBytes','capturedOutputBytes','passed','timedOut','outputLimitExceeded',
              'stopRequested','killRequested','drainTimedOut','exitCode','elapsedSeconds'}
    require(isinstance(report,dict) and required<=set(report)<=required|{'failureLines'}
            and report.get('operation')==operation and number(report.get('timeoutSeconds'))
            and 0<=report['timeoutSeconds']<=bound and report.get('stopTimeoutSeconds')==PREFLIGHT_STOP_SECONDS
            and report.get('killTimeoutSeconds')==PREFLIGHT_STOP_SECONDS
            and report.get('drainTimeoutSeconds')==PREFLIGHT_DRAIN_SECONDS
            and report.get('outputLimitBytes')==PREFLIGHT_OUTPUT_BYTES,
            'Invalid bounded offline app preflight transport record')
    require(all(type(report.get(key)) is bool for key in
                ('passed','timedOut','outputLimitExceeded','stopRequested','killRequested','drainTimedOut'))
            and type(report.get('capturedOutputBytes')) is int and 0<=report['capturedOutputBytes']<=PREFLIGHT_OUTPUT_BYTES
            and (report.get('exitCode') is None or type(report['exitCode']) is int)
            and number(report.get('elapsedSeconds')) and 0<=report['elapsedSeconds']<=report['timeoutSeconds']+
                2*PREFLIGHT_STOP_SECONDS+PREFLIGHT_DRAIN_SECONDS+1,'Unbounded offline app preflight transport timing/status')
    lines=report.get('failureLines',[])
    require(isinstance(lines,list) and len(lines)<=6 and all(isinstance(line,str) and sanitize_ui_line(line)==line
            for line in lines),'Unsafe offline app preflight transport diagnostics')
    if report['passed']:require(report['exitCode']==0 and report['timeoutSeconds']>0
        and not any(report[key] for key in ('timedOut','outputLimitExceeded','stopRequested','killRequested','drainTimedOut'))
        and report['elapsedSeconds']<=report['timeoutSeconds']+1,'Failed offline preflight command retained success')
    return report


def preflight_sim(*args,timeout,deadline,record,env=None):
    """Preflight-only simctl with finite process-group stop and bounded pipes."""
    started=time.monotonic();process=None;buffers={'stdout':bytearray(),'stderr':bytearray()}
    hard_deadline=deadline;budget=0
    grace=2*PREFLIGHT_STOP_SECONDS+PREFLIGHT_DRAIN_SECONDS
    record.update(operation=args[0],timeoutSeconds=budget,stopTimeoutSeconds=PREFLIGHT_STOP_SECONDS,
                  killTimeoutSeconds=PREFLIGHT_STOP_SECONDS,drainTimeoutSeconds=PREFLIGHT_DRAIN_SECONDS,
                  outputLimitBytes=PREFLIGHT_OUTPUT_BYTES,capturedOutputBytes=0,passed=False,timedOut=False,
                  outputLimitExceeded=False,stopRequested=False,killRequested=False,drainTimedOut=False,exitCode=None)
    def stop(force=False):
        record['stopRequested']=True
        try:os.killpg(process.pid,signal.SIGTERM)
        except ProcessLookupError:pass
        allowance=min(PREFLIGHT_STOP_SECONDS,max(0,hard_deadline-time.monotonic()))
        try:
            if allowance<=0:raise subprocess.TimeoutExpired(['simctl',args[0]],0)
            process.wait(timeout=allowance)
            if force:raise subprocess.TimeoutExpired(['simctl',args[0]],allowance)
        except subprocess.TimeoutExpired:
            record['killRequested']=True
            try:os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            allowance=min(PREFLIGHT_STOP_SECONDS,max(0,hard_deadline-time.monotonic()))
            if allowance>0:process.wait(timeout=allowance)
    try:
        hard_deadline=min(deadline,started+operation_remaining(max(.001,deadline-started)))
        budget=max(0,min(timeout,hard_deadline-started-grace))
        hard_deadline=min(hard_deadline,started+budget+grace)
        record['timeoutSeconds']=budget
        require(budget>0,'Offline app preflight transport has no remaining bounded stop allowance')
        process=subprocess.Popen(['xcrun','simctl',*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                 start_new_session=True,bufsize=0,env=env)
        operation_deadline=started+budget;drain_deadline=None
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout,selectors.EVENT_READ,'stdout')
            selector.register(process.stderr,selectors.EVENT_READ,'stderr')
            while selector.get_map():
                tick=time.monotonic()
                if tick>=operation_deadline and process.poll() is None and not record['stopRequested']:
                    record['timedOut']=True;stop()
                if process.poll() is not None and drain_deadline is None:
                    drain_deadline=min(hard_deadline,time.monotonic()+PREFLIGHT_DRAIN_SECONDS)
                if tick>=hard_deadline or drain_deadline is not None and tick>=drain_deadline:
                    record['drainTimedOut']=True
                    stop(force=True)
                    break
                for selected,_ in selector.select(.05):
                    chunk=os.read(selected.fileobj.fileno(),8192)
                    if not chunk:selector.unregister(selected.fileobj);continue
                    room=PREFLIGHT_OUTPUT_BYTES-record['capturedOutputBytes']
                    buffers[selected.data].extend(chunk[:room]);record['capturedOutputBytes']+=min(room,len(chunk))
                    if len(chunk)>room:
                        record['outputLimitExceeded']=True
                        if not record['stopRequested']:stop()
        # Pipes may close just before the child becomes waitable. Reap within
        # the active command budget instead of treating that exit race as failure.
        if process.poll() is None and not record['stopRequested']:
            allowance=min(operation_deadline,hard_deadline)-time.monotonic()
            try:
                if allowance<=0:raise subprocess.TimeoutExpired(['simctl',args[0]],0)
                process.wait(timeout=allowance)
            except subprocess.TimeoutExpired:
                record['timedOut']=True;stop()
        record['exitCode']=process.poll()
        record['passed']=record['exitCode']==0 and not any(record[key] for key in
            ('timedOut','outputLimitExceeded','stopRequested','killRequested','drainTimedOut'))
        require(record['passed'],'Bounded offline app preflight simctl failed: '+args[0])
        return buffers['stdout'].decode('utf-8',errors='replace').strip()
    finally:
        if process is not None:
            if process.poll() is None:
                try:stop()
                except Exception:record['passed']=False
            record['exitCode']=process.poll()
            for stream in (process.stdout,process.stderr):stream.close()
        record['elapsedSeconds']=round(time.monotonic()-started,3)
        record['passed']=record['passed'] and record['elapsedSeconds']<=budget+1
        if not record['passed']:
            record['failureLines']=[sanitize_ui_line(line) for name in ('stderr','stdout')
                for line in buffers[name].decode('utf-8',errors='replace').splitlines() if line][-6:]


class DarwinBSDInfo(ctypes.Structure):
    # Apple proc_info.h: PROC_PIDTBSDINFO, including kernel birth microseconds.
    _fields_=[(name,ctypes.c_uint32) for name in
        ('flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','reserved')]+[
        ('comm',ctypes.c_char*16),('name',ctypes.c_char*32)]+[
        (name,ctypes.c_uint32) for name in ('nfiles','pgid','pjobc','tdev','tpgid')]+[
        ('nice',ctypes.c_int32),('birthSeconds',ctypes.c_uint64),('birthMicroseconds',ctypes.c_uint64)]


def launch_pid(output):
    require(isinstance(output,str) and re.fullmatch(re.escape(BUNDLE_ID)+r': [1-9][0-9]{0,9}',output),
            'Offline launch did not return exactly one owned positive PID')
    pid=int(output.split(': ')[1])
    require(1<pid<2**31,'Offline launch PID is outside the positive native process range')
    return pid


def native_bsd_identity(pid,include_zombies=False,status_sink=None):
    require(sys.platform=='darwin' and type(pid) is int and 1<pid<2**31,'Owned process inspection requires Darwin and one positive PID')
    require(ctypes.sizeof(DarwinBSDInfo)==136 and DarwinBSDInfo.birthSeconds.offset==120,
            'Darwin process identity ABI differs from the inspected Apple contract')
    library=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
    library.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
    library.proc_pidinfo.restype=ctypes.c_int
    info=DarwinBSDInfo();ctypes.set_errno(0)
    count=library.proc_pidinfo(pid,3,1 if include_zombies else 0,ctypes.byref(info),ctypes.sizeof(info))
    if count==0 and ctypes.get_errno()==errno.ESRCH:return None,library
    require(count==ctypes.sizeof(info) and info.pid==pid,'Native process identity is unavailable or incomplete')
    if status_sink is not None:status_sink['status']=info.status
    return {key:getattr(info,key) for key in ('pid','uid','birthSeconds','birthMicroseconds')},library


def native_process_birth(pid):
    # Post-signal BSD lookup includes zombies; absent BSD data is not exit proof.
    return native_bsd_identity(pid,include_zombies=True)[0]


def native_process_snapshot(pid,status_sink=None):
    info,library=native_bsd_identity(pid,status_sink=status_sink)
    if info is None:return None
    library.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
    library.proc_pidpath.restype=ctypes.c_int
    buffer=ctypes.create_string_buffer(4096);ctypes.set_errno(0)
    length=library.proc_pidpath(pid,buffer,len(buffer))
    if length==0 and ctypes.get_errno()==errno.ESRCH:return None
    require(0<length<len(buffer) and length==len(buffer.value) and buffer.value.startswith(b'/'),
            'Native executable identity is unavailable or incomplete')
    return {**info,'path':buffer.value.decode('utf-8',errors='strict')}


def validate_owned_process(data,identifier,compiled):
    fields={'schema','pid','uid','birthSeconds','birthMicroseconds','identifier','bundleInstance','bundleId',
            'executable','executablePathSha256','infoPlistSha256','executableSha256',
            'launchStartedAtUtc','launchFinishedAtUtc','capturedAtUtc'}
    require(isinstance(data,dict) and set(data)==fields and data['schema']=='kade.della-host-owned-process.v1'
            and data['identifier']==identifier and data['bundleId']==BUNDLE_ID and data['executable']=='KadeAI'
            and type(data['pid']) is int and 1<data['pid']<2**31
            and type(data['uid']) is int and 0<=data['uid']<2**32
            and type(data['birthSeconds']) is int and 0<data['birthSeconds']<10**11
            and type(data['birthMicroseconds']) is int and 0<=data['birthMicroseconds']<10**6
            and isinstance(data['bundleInstance'],str) and re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}',data['bundleInstance'])
            and all(isinstance(data[key],str) and re.fullmatch(r'[a-f0-9]{64}',data[key]) for key in
                    ('executablePathSha256','infoPlistSha256','executableSha256')),
            'Owned process identity schema, PID, birth or installed simulator scope mismatch')
    require(isinstance(compiled,dict) and data['infoPlistSha256']==compiled['artifacts']['app']['infoPlistSha256']
            and data['executableSha256']==compiled['artifacts']['app']['executableSha256'],
            'Owned process differs from the exact compiled app artifact')
    captured=datetime.fromisoformat(data['capturedAtUtc'])
    launched=datetime.fromisoformat(data['launchStartedAtUtc'])
    launch_finished=datetime.fromisoformat(data['launchFinishedAtUtc'])
    birth=data['birthSeconds']+data['birthMicroseconds']/10**6
    require(captured.tzinfo is not None and launched.tzinfo is not None and launch_finished.tzinfo is not None
            and launched.timestamp()<=birth<=launch_finished.timestamp()<=captured.timestamp(),
            'Owned process was not born during this fresh native launch')
    return data


def owned_process_identity(pid,identifier,compiled,deadline,launch_started,launch_finished,
                           revalidation_record=None,original_owned=None):
    require(time.monotonic()<deadline,'Owned process inspection exhausted the existing deadline')
    status_sink={} if revalidation_record is not None else None
    first=(native_process_snapshot(pid,status_sink=status_sink) if status_sink is not None
           else native_process_snapshot(pid))
    require(first is not None and first['pid']==pid and first['uid']==os.getuid(),
            'Launched process is absent or belongs to a different native UID/PID')
    base=Path.home()/'Library/Developer/CoreSimulator/Devices'/identifier/'data/Containers/Bundle/Application'
    match=re.fullmatch(re.escape(str(base))+r'/([A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12})/KadeAI\.app/KadeAI',first['path'])
    if revalidation_record is not None:
        revalidation_record['revalidationDiagnostic']=owned_revalidation_diagnostic(
            first,status_sink['status'],base,identifier,match,original_owned)
    require(match is not None,'Launched executable is outside the exact simulator installed app')
    executable=Path(first['path']);plist=executable.parent/'Info.plist'
    for item in (executable,plist):
        require(item.resolve(strict=True)==item and not item.is_symlink(),'Owned app leaf or parent uses an unexpected alias')
    def read_owned(path,maximum):
        require(path.is_file() and 0<path.stat().st_size<=maximum,'Owned installed artifact is missing or oversized')
        chunks=[];total=0
        with path.open('rb') as stream:
            while chunk:=stream.read(1024*1024):
                require(time.monotonic()<deadline,'Owned installed-artifact hashing exhausted the existing deadline')
                total+=len(chunk);require(total<=maximum,'Owned installed artifact exceeded its fixed byte bound')
                chunks.append(chunk)
        return b''.join(chunks)
    plist_bytes=read_owned(plist,1024*1024);info=plistlib.loads(plist_bytes)
    require(info.get('CFBundleIdentifier')==BUNDLE_ID and info.get('CFBundleExecutable')=='KadeAI',
            'Owned installed app plist has a different bundle or executable')
    executable_bytes=read_owned(executable,256*1024*1024)
    plist_hash=hashlib.sha256(plist_bytes).hexdigest();executable_hash=hashlib.sha256(executable_bytes).hexdigest()
    require(time.monotonic()<deadline and native_process_snapshot(pid)==first,
            'Native PID identity changed while checking installed artifact bytes')
    record={'schema':'kade.della-host-owned-process.v1',**{key:first[key] for key in
            ('pid','uid','birthSeconds','birthMicroseconds')},'identifier':identifier,'bundleInstance':match[1],
            'bundleId':BUNDLE_ID,'executable':'KadeAI','executablePathSha256':hashlib.sha256(first['path'].encode()).hexdigest(),
            'infoPlistSha256':plist_hash,'executableSha256':executable_hash,
            'launchStartedAtUtc':launch_started,'launchFinishedAtUtc':launch_finished,'capturedAtUtc':now()}
    return validate_owned_process(record,identifier,compiled)


def owned_revalidation_diagnostic(first,status,base,identifier,match,owned):
    # Classify only the already-observed kernel path. No alias resolution,
    # installed-artifact read or further native lookup enters this diagnostic.
    path=first['path'];device_root=str(base).removesuffix('/data/Containers/Bundle/Application')
    family=device_root.rsplit('/',1)[0]
    uuid=r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}'
    family_device=re.match(re.escape(family)+r'/('+uuid+r')/',path)
    same_device=(path.startswith(device_root+'/') or family_device is not None
                 and family_device[1].casefold()==identifier.casefold())
    other=re.fullmatch(re.escape(family)+r'/('+uuid+r')/data/Containers/Bundle/Application/'+uuid+r'/KadeAI\.app/KadeAI',path)
    category=('expectedSimulatorApp' if match is not None else 'sameSimulatorOtherPath'
              if same_device else 'anotherSimulatorApp'
              if other is not None and other[1].casefold()!=identifier.casefold() else 'sameAppSuffixElsewhere'
              if path.endswith('/KadeAI.app/KadeAI') else 'otherAbsolutePath')
    digest=hashlib.sha256(path.encode()).hexdigest()
    return {'schema':'kade.della-host-revalidation-diagnostic.v1',
            **{key:first[key] for key in ('pid','uid','birthSeconds','birthMicroseconds')},
            'status':status,'executablePathSha256':digest,'exactSimulatorAppScope':match is not None,
            'pathCategory':category,'matchesOriginal':{
                'pid':first['pid']==owned['pid'],'uid':first['uid']==owned['uid'],
                'birth':all(first[key]==owned[key] for key in ('birthSeconds','birthMicroseconds')),
                'path':digest==owned['executablePathSha256']}}


def validate_owned_revalidation_diagnostic(data,owned):
    fields={'schema','pid','uid','birthSeconds','birthMicroseconds','status',
            'executablePathSha256','exactSimulatorAppScope','pathCategory','matchesOriginal'}
    require(isinstance(data,dict) and set(data)==fields and owned is not None
            and data['schema']=='kade.della-host-revalidation-diagnostic.v1'
            and type(data['pid']) is int and data['pid']==owned['pid'] and 1<data['pid']<2**31
            and type(data['uid']) is int and 0<=data['uid']<2**32
            and type(data['birthSeconds']) is int and 0<data['birthSeconds']<10**11
            and type(data['birthMicroseconds']) is int and 0<=data['birthMicroseconds']<10**6
            and type(data['status']) is int and 0<=data['status']<2**32
            and isinstance(data['executablePathSha256'],str) and re.fullmatch(r'[a-f0-9]{64}',data['executablePathSha256'])
            and type(data['exactSimulatorAppScope']) is bool
            and isinstance(data['pathCategory'],str)
            and data['pathCategory'] in ('expectedSimulatorApp','sameSimulatorOtherPath','anotherSimulatorApp',
                                         'sameAppSuffixElsewhere','otherAbsolutePath')
            and data['exactSimulatorAppScope']==(data['pathCategory']=='expectedSimulatorApp'),
            'Owned revalidation diagnostic schema, kernel fields or path category is invalid')
    matches=data['matchesOriginal']
    require(isinstance(matches,dict) and set(matches)=={'pid','uid','birth','path'}
            and all(type(value) is bool for value in matches.values())
            and matches=={'pid':data['pid']==owned['pid'],'uid':data['uid']==owned['uid'],
                          'birth':all(data[key]==owned[key] for key in ('birthSeconds','birthMicroseconds')),
                          'path':data['executablePathSha256']==owned['executablePathSha256']},
            'Owned revalidation diagnostic contradicts the original identity')
    return data


def owned_identity_digest(owned):
    return hashlib.sha256(json.dumps(owned,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def validate_owned_termination(data,owned):
    fields={'schema','pid','identitySha256','timeoutSeconds','signal','signalSubmitted','identityVerified',
            'observedExit','passed','timedOut','exitCode','pollCount','startedAtUtc','finishedAtUtc','elapsedSeconds'}
    require(isinstance(data,dict) and fields<=set(data)<=fields|{'errorType','error','revalidationDiagnostic'}
            and data['schema']=='kade.della-host-owned-exit.v1' and data['signal']=='SIGTERM' and data['exitCode'] is None
            and number(data['timeoutSeconds']) and 0<=data['timeoutSeconds']<=30
            and number(data['elapsedSeconds']) and 0<=data['elapsedSeconds']<=data['timeoutSeconds']+1
            and all(type(data[key]) is bool for key in ('signalSubmitted','identityVerified','observedExit','passed','timedOut'))
            and type(data['pollCount']) is int and 0<=data['pollCount']<=301,
            'Owned exit diagnostic fabricated a child status or exceeded its strict bounds')
    require(data['pid'] is None and owned is None and data['identitySha256'] is None
            or owned is not None and type(data['pid']) is int and data['pid']==owned['pid']
                and data['identitySha256']==owned_identity_digest(owned),
            'Owned exit is not tied to the exact launch identity')
    require(all(isinstance(data[key],str) and 0<len(data[key])<=320 and sanitize_ui_line(data[key])==data[key]
                for key in ('errorType','error') if key in data)
            and (not data['signalSubmitted'] or data['identityVerified'])
            and (not data['observedExit'] or data['signalSubmitted']),
            'Owned process exit diagnostics contradict the verified signal or contain unsafe text')
    if 'revalidationDiagnostic' in data:
        diagnostic=validate_owned_revalidation_diagnostic(data['revalidationDiagnostic'],owned)
        require(not data['identityVerified'] or diagnostic['exactSimulatorAppScope']
                and all(diagnostic['matchesOriginal'].values()),
                'Owned revalidation diagnostic contradicts verified native ownership')
    start=datetime.fromisoformat(data['startedAtUtc']);finish=datetime.fromisoformat(data['finishedAtUtc'])
    require(start.tzinfo is not None and finish.tzinfo is not None and start<=finish
            and (finish-start).total_seconds()<=31,'Owned exit timestamp envelope is invalid')
    if owned is not None:require(datetime.fromisoformat(owned['capturedAtUtc'])<=start,
                                'Owned process exit precedes the actual launch identity observation')
    if data['passed']:require(owned is not None and all(data[key] for key in ('identityVerified','signalSubmitted','observedExit'))
            and data['timeoutSeconds']>0 and data['pollCount']>0 and not data['timedOut'] and 'errorType' not in data,
            'Unobserved or failed owned process exit retained native success')
    return data


def terminate_owned_process(owned,identifier,compiled,deadline,record,bound=30):
    require(number(bound) and 0<bound<=30,'Owned exit requires the unchanged finite cleanup bound')
    started=time.monotonic();limit=min(deadline,started+bound)
    record.update(schema='kade.della-host-owned-exit.v1',pid=owned['pid'] if owned else None,
                  identitySha256=owned_identity_digest(owned) if owned else None,timeoutSeconds=max(0,limit-started),
                  signal='SIGTERM',signalSubmitted=False,identityVerified=False,observedExit=False,passed=False,
                  timedOut=False,exitCode=None,pollCount=0,startedAtUtc=now())
    try:
        require(owned is not None,'Offline launch has no verified native PID; no signal was sent')
        fresh=owned_process_identity(owned['pid'],identifier,compiled,limit,
                                     owned['launchStartedAtUtc'],owned['launchFinishedAtUtc'],
                                     revalidation_record=record,original_owned=owned)
        require({key:value for key,value in fresh.items() if key!='capturedAtUtc'}==
                {key:value for key,value in owned.items() if key!='capturedAtUtc'},
                'Owned launch PID was reused or its installed identity changed; no signal was sent')
        require(time.monotonic()<limit,'Owned process signal has no remaining cleanup deadline')
        immediate=native_process_snapshot(owned['pid'])
        require(immediate is not None and all(immediate[key]==owned[key] for key in
                ('pid','uid','birthSeconds','birthMicroseconds'))
                and hashlib.sha256(immediate['path'].encode()).hexdigest()==owned['executablePathSha256'],
                'Native ownership changed immediately before the one signal; no signal was sent')
        record['identityVerified']=True
        require(time.monotonic()<limit,'Native ownership verification exhausted the existing signal deadline')
        os.kill(owned['pid'],signal.SIGTERM);record['signalSubmitted']=True
        while time.monotonic()<limit:
            record['pollCount']+=1
            try:os.kill(owned['pid'],0)
            except ProcessLookupError:
                require(time.monotonic()<=limit,'Owned process absence arrived after the strict cleanup deadline')
                record['observedExit']=True;record['passed']=True
                return record
            current=native_process_birth(owned['pid'])
            if current is not None:
                require(all(current[key]==owned[key] for key in ('pid','uid','birthSeconds','birthMicroseconds')),
                        'Owned PID changed before actual exit; no second signal was sent')
            time.sleep(min(.1,max(0,limit-time.monotonic())))
        record['timedOut']=True
        raise RuntimeError('Owned app process did not exit within its existing cleanup bound')
    except Exception as error:
        record.update(passed=False,errorType=type(error).__name__,error=sanitize_ui_line(str(error))
                      if isinstance(error,RuntimeError) else 'Owned process signal or native observation failed')
        raise
    finally:
        record['elapsedSeconds']=round(time.monotonic()-started,3);record['finishedAtUtc']=now()
        record['passed']=record['passed'] and record['elapsedSeconds']<=record['timeoutSeconds']+1


def compiled_unchanged(expected,saved,deadline):
    global _OPERATION_DEADLINE
    require(time.monotonic()<deadline,'Compiled rehash has no remaining native operation deadline')
    previous=_OPERATION_DEADLINE
    _OPERATION_DEADLINE=min(previous or float('inf'),time.time()+deadline-time.monotonic())
    try:
        require(compiled_tests(expected,emit_inventory=False)==saved,'Compiled app/runner/test bundle changed during native operation')
        require(time.monotonic()<deadline,'Compiled rehash exhausted the native operation deadline')
        return saved
    finally:_OPERATION_DEADLINE=previous


def validate_capture_ownership(report):
    require(report.get('schema')=='kade.della-host-capture.v2' and type(report.get('compiledAfterVerified')) is bool,
            'Host capture owned-process schema or compiled-after status mismatch')
    processes=report.get('ownedProcesses');terminations=report.get('ownedTerminations')
    require(isinstance(processes,dict) and isinstance(terminations,dict)
            and set(processes)<=required_phases() and set(terminations)<=required_phases(),
            'Host capture contains unknown owned-process phases')
    compiled=report.get('compiledRunner')
    if compiled is not None:validate_compiled_record(compiled,report['source'])
    for phase,owned in processes.items():
        identifier=report['simulators'][case_device(phase)]['identifier']
        validate_owned_process(owned,identifier,compiled)
        require(datetime.fromisoformat(report['captureTimings'][phase]['startedAtUtc'])<=
                datetime.fromisoformat(owned['launchStartedAtUtc']), 'Owned host launch precedes its actual phase')
    for phase,termination in terminations.items():
        validate_owned_termination(termination,processes.get(phase))
        if 'finishedAtUtc' in report:
            require(datetime.fromisoformat(termination['finishedAtUtc'])<=datetime.fromisoformat(report['finishedAtUtc']),
                    'Owned host exit follows the final native capture receipt')
        timing=report['captureTimings'][phase]
        if 'elapsedSeconds' in timing:
            require(datetime.fromisoformat(termination['finishedAtUtc']).timestamp()<=
                    datetime.fromisoformat(timing['startedAtUtc']).timestamp()+timing['elapsedSeconds']+1,
                    'Owned host exit falls outside its bounded native phase')
    if report.get('passed'):
        require(report['compiledAfterVerified'] and set(processes)==set(terminations)==required_phases()
                and all(record['passed'] for record in terminations.values())
                and len({(record['identifier'],record['pid'],record['birthSeconds'],record['birthMicroseconds'])
                         for record in processes.values()})==len(processes),
                'Successful host capture lacks all verified native exits or unchanged compiled artifacts')
    return report


def app_preflight(expected,identifier,initial,device,deadline,report):
    """Verify a cold offline app launch inside the existing UI boot envelope."""
    started=time.monotonic()
    report.update(schema='kade.della-host-app-preflight.v2',source=initial,device='large',identifier=identifier,
                  phase='call-a11y-dark',timeoutSeconds=BOOT_SECONDS,noScreenshot=True,passed=False,
                  compiledBeforeVerified=False,compiledAfterVerified=False,freshReadiness=False,
                  readyValidated=False,terminated=False,operationSeconds={},commandOperations={},status='preparing',startedAtUtc=now())
    # Work leaves30 seconds of the same boot/shared/action deadline for termination.
    work_deadline=deadline-30
    attempted=False
    def remaining(bound,cleanup=False):
        seconds=(deadline if cleanup else work_deadline)-time.monotonic()
        require(seconds>0,'Offline app preflight exhausted the existing UI boot deadline')
        return min(bound,seconds)
    def timed(name,action):
        tick=time.monotonic()
        try:return action()
        finally:report['operationSeconds'][name]=round(time.monotonic()-tick,3)
    def command(name,*args,bound,cleanup=False,env=None):
        allowance=remaining(bound,cleanup=cleanup)
        record={};report['commandOperations'][name]=record
        return timed(name,lambda:preflight_sim(*args,timeout=allowance,
                     deadline=deadline if cleanup else work_deadline,record=record,env=env))
    def unchanged(cleanup=False):
        allowance=remaining(BOOT_SECONDS,cleanup=cleanup)
        path=OUT/'compiled-tests.json'
        require(path.is_file() and 0<path.stat().st_size<=64*1024,'Saved exact compiled test record missing or oversized')
        saved=validate_compiled_record(json.loads(path.read_text()),initial)
        compiled_unchanged(expected,saved,time.monotonic()+allowance)
        remaining(1,cleanup=cleanup)
        return saved
    try:
        report['compiledRunner']=timed('compiledBefore',unchanged);report['compiledBeforeVerified']=True
        report['status']='installing'
        command('install','install',identifier,str(APP),bound=INSTALL_SECONDS)
        command('appearance','ui',identifier,'appearance','dark',bound=30)
        container=command('container','get_app_container',identifier,BUNDLE_ID,'data',bound=PREFLIGHT_CONTAINER_SECONDS)
        require(isinstance(container,str) and 0<len(container)<=2048 and re.fullmatch(
            r'/.+/CoreSimulator/Devices/'+re.escape(identifier)+
            r'/data/Containers/Data/Application/[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}',container),
            'Offline app preflight container differs from the actual simulator UUID')
        documents=Path(container)/'Documents';documents.mkdir(exist_ok=True)
        ready=documents/'della-host-ready.json';ready.unlink(missing_ok=True)
        require(not ready.exists(),'Offline app preflight retained a stale readiness file')
        report['freshReadiness']=True;report['status']='launching'
        env=dict(os.environ,SIMCTL_CHILD_KADE_CHARACTER_AUDIT='1',SIMCTL_CHILD_KADE_A11Y_AUDIT='1',
                 SIMCTL_CHILD_KADE_DELLA_HOST_AUDIT='1',SIMCTL_CHILD_KADE_DELLA_HOST_CASE='call-a11y-dark',
                 SIMCTL_CHILD_KADE_DELLA_HOST_UI_DRAG='0',SIMCTL_CHILD_KADE_PUPPET_LAB='0',
                 SIMCTL_CHILD_KADE_DELLA_ARTICULATED_AUDIT='0',SIMCTL_CHILD_KADE_CHAT_LAYOUT_AUDIT='0',
                 SIMCTL_CHILD_KADE_CALL_LAYOUT_AUDIT='0',SIMCTL_CHILD_KADE_TOUR='0')
        remaining(1);attempted=True
        launch_started=now()
        launched=command('launch','launch',identifier,BUNDLE_ID,env=env,bound=PREFLIGHT_LAUNCH_SECONDS)
        launch_finished=now()
        report['ownedProcess']=timed('ownedProcess',lambda:owned_process_identity(
            launch_pid(launched),identifier,report['compiledRunner'],work_deadline,launch_started,launch_finished))
        report['status']='waitingForReadiness'
        def readiness():
            ready_deadline=time.monotonic()+remaining(READY_SECONDS)
            while not ready.exists() and time.monotonic()<ready_deadline:
                time.sleep(min(.15,max(0,ready_deadline-time.monotonic())))
            require(ready.is_file() and time.monotonic()<=ready_deadline,
                    'Offline app preflight native readiness timed out')
            require(0<ready.stat().st_size<=64*1024,'Offline app preflight readiness missing or oversized')
            raw=ready.read_bytes();validate_ready(json.loads(raw),'call-a11y-dark',device)
            report['readySha256']=hashlib.sha256(raw).hexdigest();report['readyValidated']=True
        timed('readiness',readiness)
    except Exception as error:
        report.update(status='failed',errorType=type(error).__name__,error=sanitize_ui_line(str(error))
                      if isinstance(error,RuntimeError) else 'Offline app preflight operation failed')
        raise
    finally:
        cleanup_failure=None
        try:
            if attempted:
                report['ownedTermination']={}
                timed('ownedTermination',lambda:terminate_owned_process(report.get('ownedProcess'),identifier,
                    report['compiledRunner'],deadline,report['ownedTermination']))
                report['terminated']=report['ownedTermination']['passed']
        except Exception as error:
            cleanup_failure=error
        try:
            if report['compiledBeforeVerified']:
                # Always attempt the quiet rehash under the remaining cleanup
                # deadline, even when the owned process did not exit successfully.
                require(timed('compiledAfter',lambda:unchanged(cleanup=True))==report['compiledRunner'],
                        'Compiled app/runner/test bundle changed during offline app preflight')
                report['compiledAfterVerified']=True
        except Exception as error:
            report.update(compiledAfterErrorType=type(error).__name__,compiledAfterError=sanitize_ui_line(str(error))
                          if isinstance(error,RuntimeError) else 'Offline app preflight compiled-after verification failed')
            if cleanup_failure is None:cleanup_failure=error
        try:
            if cleanup_failure is not None:raise cleanup_failure
        except Exception as error:
            diagnostic=sanitize_ui_line(str(error)) if isinstance(error,RuntimeError) else 'Offline app preflight cleanup failed'
            if 'errorType' in report:
                report.update(cleanupErrorType=type(error).__name__,cleanupError=diagnostic)
            else:
                report.update(status='failed',errorType=type(error).__name__,error=diagnostic)
                raise
        finally:
            report['passed']=all(report[field] for field in ('compiledBeforeVerified','compiledAfterVerified',
                                  'freshReadiness','readyValidated','terminated')) and 'errorType' not in report \
                                  and all(command.get('passed') is True for command in report['commandOperations'].values())
            if report['passed']:report['status']='completed'
            report['elapsedSeconds']=round(time.monotonic()-started,3);report['finishedAtUtc']=now()
    validate_app_preflight(report,identifier,initial)
    require(report['passed'],'Offline app preflight did not complete successfully')
    return report


def boot_ui(expected,key,completion=False):
    require(not completion or key=='large','Completion boot requires the same Pro Max')
    started=time.monotonic()
    initial=initial_source(expected)
    report={'source':initial,'device':key,'passed':False,'timeoutSeconds':BOOT_SECONDS,'startedAtUtc':now()}
    try:
        require(sys.platform=='darwin','Explicit UI simulator boot requires standard macOS')
        records=simulator_record(expected)['devices']
        identifier=records[key]['identifier'];report['identifier']=identifier
        tick=time.monotonic()
        deadline=min(started+BOOT_SECONDS,tick+operation_remaining(BOOT_SECONDS))
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
        if key=='large':
            report['appPreflight']={}
            app_preflight(expected,identifier,initial,records[key],deadline,report['appPreflight'])
        report['passed']=True
    except Exception as error:
        report.update(passed=False,errorType=type(error).__name__,
                      error=str(error) if isinstance(error,RuntimeError) else 'Explicit UI simulator boot failed')
        raise
    finally:
        report['elapsedSeconds']=round(time.monotonic()-started,3);report['finishedAtUtc']=now()
        save('ui-boot-completion.json' if completion else 'ui-boot-'+key+'.json',report)
        if 'appPreflight' in report:
            compact={field:value for field,value in report['appPreflight'].items()
                     if field not in ('source','compiledRunner')}
            compact['source']=initial['sha']
            encoded=json.dumps(compact,separators=(',',':'))
            require(len(encoded.encode())<=64*1024,'Oversized bounded early preflight diagnostic')
            print(('KADE_PUPPET_COMPLETION_APP_PREFLIGHT ' if completion else 'KADE_DELLA_HOST_APP_PREFLIGHT ')+encoded,flush=True)
    return report


def sanitize_ui_line(line):
    line=re.sub(r'https?://\S+','[URL omitted]',line)
    line=re.sub(r'(?:github_pat_|ghp_)[A-Za-z0-9_]+','[credential omitted]',line)
    line=re.sub(r'(authorization|api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+',
                r'\1=[redacted]',line,flags=re.I)
    return ''.join(character for character in line if character=='\t' or ord(character)>=32)[:320]


def observe_ui_line(report,line,key,completion=False):
    methods=({'testAllCastKeyposes':'allCastKeyposes',
              'testCompactAndMotionPolicies':'compactAndMotionPolicies',
              'testRoomySendingKeepsBodyAndComposer':'roomySendingLight'} if completion else ui_methods(key))
    if re.search(r'Command line invocation:|xcodebuild |Build settings from command line:|Testing started|Test Suite .* started|Selected tests|Preparing|Writing result bundle|[Ss]imulator|destination',line):
        report['startupMessages']=(report['startupMessages']+[sanitize_ui_line(line)])[-6:]
    if re.search(r'\bt\s*=\s*[0-9.]+s?\s+(Launch|Wait for|Find|Get number|Checking|Query|Tap|Scroll|Swipe)\b',line):
        report['activityMessages']=(report['activityMessages']+[sanitize_ui_line(line)])[-12:]
    if 'Testing started' in line or re.search(r'Test Suite .* started',line): report['startupStage']='testingStarted'
    test_class='PuppetCompletionUITests' if completion else 'DellaHostControlsUITests'
    match=re.search(r'Test Case [^\r\n]{0,180}'+test_class+r'[ .]+(test[A-Za-z]+)'
                    r'[^\r\n]{0,8} (started|passed|failed)(?: \(([0-9.]+) seconds\))?',line)
    if match and match[1] in methods:
        method,state,duration=match.groups();entry=report['testMethods'].setdefault(method,{'phase':methods[method]})
        entry['status']=state;report['startupStage']='testCaseStarted'
        if state=='started': report['lastStartedMethod']=method
        if duration is not None and number(float(duration)) and 0<=float(duration)<=3600:
            entry['durationSeconds']=float(duration)
        print(('KADE_PUPPET_COMPLETION_UI_TEST ' if completion else 'KADE_DELLA_HOST_UI_TEST ')
              +json.dumps({'device':key,'method':method,**entry},separators=(',',':')),flush=True)
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


def run_ui(expected,key,completion=False):
    initial=initial_source(expected)
    report=ui_launch_record(initial,key)
    if completion:
        require(key=='large','Completion UI uses the proved Pro Max runner')
        report['schema']='kade.puppet-completion-ui-launch.v1'
    prefix='completion' if completion else key
    started=time.monotonic();process=None
    try:
        require(sys.platform=='darwin','Bounded native UI launch requires standard macOS')
        boot=json.loads((OUT/('ui-boot-completion.json' if completion else 'ui-boot-'+key+'.json')).read_text())
        validate_ui_boot(boot,key,initial)
        require(boot.get('source')==initial and boot.get('device')==key and boot.get('passed') is True,
                'UI launch requires the exact successful explicit device boot')
        report['boot']=boot
        compiled=compiled_tests(expected);report['compiledRunner']=compiled
        if key=='large':require(compiled==boot['appPreflight']['compiledRunner'],
                                'UI launch app/runner differs from the actual offline app preflight')
        identifier=simulator_record(expected)['devices'][key]['identifier']
        require(identifier==boot['identifier'],'UI launch device differs from explicit boot')
        bundle=OUT/('ui-tests-'+prefix+'.xcresult')
        require(not bundle.exists(),'Refusing to overwrite a native UI result bundle')
        command=['xcodebuild','-jobs','2','test-without-building','-xctestrun',str(ROOT/compiled['xctestrun']),
                 '-destination','platform=iOS Simulator,id='+identifier,'-resultBundlePath',str(bundle),
                 '-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1',
                 *['-only-testing:KadeAIUITests/'+('PuppetCompletionUITests' if completion else 'DellaHostControlsUITests')+'/'+method
                   for method in (('testAllCastKeyposes','testCompactAndMotionPolicies','testRoomySendingKeepsBodyAndComposer') if completion else ui_methods(key))],
                 'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=','DEVELOPMENT_TEAM=']
        effective=operation_remaining(UI_SECONDS[key]);report['effectiveTimeoutSeconds']=effective
        process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                                 start_new_session=True,bufsize=0,cwd=ROOT)
        report['startupStage']='processStarted';report['status']='running';launched=time.monotonic()
        deadline=launched+effective;raw_bytes=0;pending=b'';drain_deadline=None
        with (OUT/('ui-tests-'+prefix+'.log')).open('wb') as log, selectors.DefaultSelector() as selector:
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
                        line,pending=pending.split(b'\n',1);observe_ui_line(report,line[:4096].decode('utf-8','replace'),key,completion)
                    if len(pending)>4096: pending=pending[-4096:]
                if process.poll() is not None and not selector.get_map(): break
            if pending: observe_ui_line(report,pending.decode('utf-8','replace'),key,completion)
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
        save('ui-run-'+prefix+'.json',report)
        for line in report['failureLines']: print('KADE_DELLA_HOST_UI_FAILURE '+line,flush=True)
        print(('KADE_PUPPET_COMPLETION_UI_LAUNCH ' if completion else 'KADE_DELLA_HOST_UI_LAUNCH ')+json.dumps({name:report[name] for name in
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
    if report['passed'] and key=='large':
        require(report['compiledRunner']==report['boot']['appPreflight']['compiledRunner'],
                'Successful Pro Max UI launch differs from the actual offline app preflight')
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
    receipt={'schema':'kade.della-host-capture.v2','source':initial,'simulators':records,'captures':{},'captureTimings':{},'nativeReady':{},
             'ownedProcesses':{},'ownedTerminations':{},'compiledAfterVerified':False,
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
    compiled=None
    aggregate_deadline=None
    try:
        compiled=compiled_tests(expected,emit_inventory=False);receipt['compiledRunner']=compiled
        require(all(group['launch']['compiledRunner']==compiled for group in ui['deviceResults'].values()),
                'Host capture app differs from both exact tested compiled runners')
        require(APP.is_dir(),'Unsigned Debug host app missing')
        info=plistlib.loads((APP/'Info.plist').read_bytes())
        require(info.get('CFBundleIdentifier')==BUNDLE_ID and info.get('CFBundleShortVersionString')=='2.2.13'
                and str(info.get('CFBundleVersion'))=='100','Built app identity/version drift')
        require(info.get('DTPlatformName')=='iphonesimulator'
                or 'iPhoneSimulator' in info.get('CFBundleSupportedPlatforms',[]),'App is not the simulator target')
        require(info.get('UISupportedInterfaceOrientations')==['UIInterfaceOrientationPortrait'],
                'Host review must retain the actual phone portrait-only app declaration')
        require(not (APP/'_CodeSignature').exists(),'Signed app appeared in unsigned host review')
        receipt['builtApp']={'bundleId':BUNDLE_ID,'marketingVersion':'2.2.13','buildVersion':'100',
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
                owned=None;phase_failure=None
                def remaining(bound,cleanup=False):
                    seconds=(deadline if cleanup else deadline-30)-time.monotonic()
                    require(seconds>0,'Host capture watchdog expired during '+phase)
                    return min(bound,seconds)
                try:
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
                    launch_at=now()
                    launched=sim('launch','--stdout='+str(OUT/(phase+'.stdout')),'--stderr='+str(OUT/(phase+'.stderr')),
                        identifier,BUNDLE_ID,env=env,timeout=remaining(45))
                    launch_finished=now()
                    timing['launchSeconds']=round(time.monotonic()-launch_started,3)
                    owned=owned_process_identity(launch_pid(launched),identifier,compiled,deadline-30,launch_at,launch_finished)
                    receipt['ownedProcesses'][phase]=owned
                    ready_started=time.monotonic()
                    ready_deadline=min(deadline-30,ready_started+READY_SECONDS)
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
                except Exception as error:
                    phase_failure=error
                    raise
                finally:
                    termination={};receipt['ownedTerminations'][phase]=termination
                    try:terminate_owned_process(owned,identifier,compiled,deadline,termination,bound=30)
                    except Exception as error:
                        if phase_failure is None:raise
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
        require(set(receipt['ownedProcesses'])==set(receipt['ownedTerminations'])==required_phases()
                and all(record['passed'] for record in receipt['ownedTerminations'].values()),
                'Every host phase requires its own verified native process exit')
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
        if compiled is not None:
            try:
                limit=aggregate_deadline or time.monotonic()+operation_remaining(30)
                compiled_unchanged(expected,compiled,limit);receipt['compiledAfterVerified']=True
            except Exception as error:
                receipt.update(passed=False,nativeRenderingVerified=False,nativeHostLayoutVerified=False,
                               compiledAfterErrorType=type(error).__name__,compiledAfterError=sanitize_ui_line(str(error))
                               if isinstance(error,RuntimeError) else 'Host capture compiled-after rehash failed')
        if aggregate_started is not None:
            receipt['aggregateCaptureElapsedSeconds']=round((aggregate_finished or time.monotonic())-aggregate_started,3)
        receipt['finishedAtUtc']=now()
        validate_capture_ownership(receipt)
        save('receipt.json',receipt)
        for device in records.values():
            try: sim('shutdown',device['identifier'],timeout=30)
            except Exception: pass
    require(receipt['passed'] and receipt['compiledAfterVerified'],'Host capture did not retain exact compiled artifacts and owned exits')
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
        validate_capture_ownership(receipt)
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
        if args.action in ('run-ui','build-tests','boot-ui'):
            guard=(720 if args.device=='large' else 600) if args.action=='run-ui' else BOOT_SECONDS+30 if args.action=='boot-ui' else 960
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
                              timeout=operation_remaining(15));result={'registeredProductionCatalogVerified':True}
    else: emit(args.expected_sha); result=None
    if result is not None: print(json.dumps(result,indent=2))


if __name__=='__main__':
    try: main()
    except Exception as error:
        print(json.dumps({'ok':False,'errorType':type(error).__name__,
                          'message':str(error) if isinstance(error,RuntimeError) else 'Host audit operation failed'}),file=sys.stderr)
        raise SystemExit(1)

