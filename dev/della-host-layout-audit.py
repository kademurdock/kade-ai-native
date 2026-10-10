"""Exact-source silent actual-host simulator QA; bounded evidence uses logs only.

This separate lane preserves the accepted puppet and previous art audit. Only
synthetic host readiness, PNGs and receipts enter the bounded evidence archive.
No server, signing, app package, account transcript, artifact storage or release.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
from io import BytesIO
import json
import math
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
    'chat-roomy-light','chat-packed-dark','chat-keyboard-dark','chat-a11y-dark',
    'chat-off-dark','chat-small-light','call-roomy-light','call-captions-dark',
    'call-captions-scrolled-dark','call-camera-light','call-camera-scrolled-dark',
    'call-a11y-dark','call-a11y-scrolled-dark','call-off-camera-dark','call-small-light',
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
    'chat-roomy-light','chat-packed-dark','chat-keyboard-dark','chat-a11y-dark',
    'call-roomy-light','call-captions-dark','call-captions-scrolled-dark',
    'call-camera-light','call-camera-scrolled-dark','call-a11y-dark','call-a11y-scrolled-dark',
}
GEOMETRY_KEYS={
    'window','stage','transcript','composer','chatControls','attachment','invite',
    'viewport','callViewport','primaryControls','camera','secondaryControls','keyboard',
    'cameraButton','spotterButton','deepThinkButton','stopTalkingButton','muteButton','hangUpButton',
    'attach','composerField','send',
}
AGENT_ID='agent_BSOLa3eNEZyjs-7abCjMt'
AVATAR_PATH='/images/agent-agent_BSOLa3eNEZyjs-7abCjMt-avatar-1788941611099.png'
NATIVE_CHECKS={
    'Requested actual host and original Della ownership match',
    'Real portrait phone dimensions and settled stage frame agree',
    'Camera, audio, microphone and network fixtures stayed silent',
    'Candidate, keyboard, accessibility and scroll policies match the case',
    'Measured stage paint respects the viewport and fixed call controls',
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
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True, stderr=subprocess.PIPE).strip()


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


def required_phases():
    require(len(PHASES)==len(set(PHASES))==15 and bool(HOST_MODEL_INPUTS) and bool(NATIVE_CHECKS),
            'Host fixture phase/source/readiness contract drift')
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
    return {'schema':'kade.della-host-native-source.v1','sha':expected,'repository':REPOSITORY,
            'branch':BRANCH,'inputs':inputs,'checkedAtUtc':now(),'unsignedSimulatorOnly':True,
            'releasePublished':False,'physicalPhoneVerified':False,'batteryPerformanceVerified':False,
            'physicalVoiceOverVerified':False,'audioStarted':False,'microphoneStarted':False,
            'cameraStarted':False,'networkStarted':False}


def case_device(phase):
    require(phase in required_phases(),'Unknown host case')
    return 'small' if phase.endswith('-small-light') else 'large'


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
    if isinstance(stage,dict):
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
        require(isinstance(stage,dict) and set(stage)<={'side','portraitHeight','frameHeight','articulated'}
                and all(type(value) is bool if key=='articulated' else number(value) and abs(value)<=10000
                        for key,value in stage.items()),'Unbounded failed native stage diagnostic')
    if 'geometry' in diagnostic:
        geometry=diagnostic['geometry']
        require(isinstance(geometry,dict) and set(geometry)<=GEOMETRY_KEYS
                and all(rectangle(value) for value in geometry.values()),'Unbounded failed native CGRect diagnostic')
    return diagnostic


def validate_ready(data,phase,device):
    fields={'schema','phase','host','windowPoints','orientation','appearance','stage','geometry','viewportIntersectsStage',
            'actualHost','hostFrameMatchesPortrait','motionPausedForLayoutAudit',
            'keyboardVisible','composerEditing','candidateEnabled','dynamicTypeAccessibility','scrolled',
            'sourceAvatarPath','agentID','resourceComplete','audioStarted','microphoneStarted','cameraStarted',
            'networkStarted','networkRequestsBlocked','blockedRequestCount',
            'physicalPhoneVerified','voiceOverVerified','batteryMeasured'}
    require(isinstance(data,dict) and set(data)==fields,'Native host readiness schema fields drift')
    host=phase.split('-',1)[0]
    require(data['schema']=='kade.della-host-ready.v1' and data['phase']==phase and data['host']==host
            and data['actualHost']==('ConversationDetailView' if host=='chat' else 'CallView')
            and data['orientation']=='portrait'
            and data['appearance']==('dark' if phase.endswith('-dark') else 'light'),
            'Native requested actual host/case/orientation/appearance mismatch')
    require(data['hostFrameMatchesPortrait'] is True and data['motionPausedForLayoutAudit'] is True,
            'Native parent/child frame or paused fixture mismatch')
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
    keyboard=phase=='chat-keyboard-dark'
    require(data['keyboardVisible'] is keyboard and data['composerEditing'] is keyboard,
            'Requested actual keyboard/composer state mismatch')
    stage=data['stage']
    require(isinstance(stage,dict) and set(stage)=={'side','portraitHeight','frameHeight','articulated'}
            and all(number(stage[key]) and 0<stage[key]<1000 for key in ('side','portraitHeight','frameHeight'))
            and type(stage['articulated']) is bool,'Settled stage schema invalid')
    portrait=stage['side']*620/414 if stage['articulated'] else stage['side']
    require(abs(stage['portraitHeight']-portrait)<=1
            and abs(stage['frameHeight']-(stage['portraitHeight']+40))<=1,'Natural parent/child stage height drift')
    if phase=='chat-roomy-light':
        sides={208}; tall=True
    elif phase=='chat-keyboard-dark':
        sides={84}; tall=False
    elif phase.endswith('-small-light'):
        sides={132}; tall=False
    elif phase in ('chat-packed-dark','chat-a11y-dark') or '-camera-' in phase and '-off-' not in phase \
            or '-a11y-' in phase:
        sides={104}; tall=False
    elif '-off-' in phase:
        sides={208} if host=='chat' else {160,208}; tall=False
    else:
        sides={160,208}; tall=True
    require(any(abs(stage['side']-side)<=1 for side in sides) and stage['articulated'] is tall,
            'Requested host stage policy mismatch')
    geometry=data['geometry']
    require(isinstance(geometry,dict) and set(geometry)<=GEOMETRY_KEYS
            and all(rectangle(value) for value in geometry.values()),'Invalid/unbounded native CGRect observations')
    required={'window','stage','transcript','composer','chatControls'} if host=='chat' \
        else {'window','stage','primaryControls','secondaryControls'}
    require(required<=set(geometry),'Required actual host geometry missing')
    require(all(geometry[key][2]>0 and geometry[key][3]>0 for key in required),
            'Required actual host geometry has an empty frame')
    require(all(abs(actual-wanted)<=1 for actual,wanted in zip(geometry['window'],[0,0,*points])),
            'Measured native window and real phone dimensions disagree')
    require(abs(geometry['stage'][3]-stage['frameHeight'])<=1,'Measured stage and resolved child frame differ')
    viewport=geometry['window'] if host=='chat' else geometry.get('viewport',geometry.get('callViewport'))
    require(rectangle(viewport),'Actual call viewport geometry missing')
    require(viewport[2]>0 and viewport[3]>0,'Actual host viewport is empty')
    visible=intersection(geometry['stage'],viewport)
    require(data['viewportIntersectsStage'] is (visible[2]>0 and visible[3]>0),
            'Observed viewport/stage intersection mismatch')
    if host=='call':
        overlap=intersection(visible,geometry['primaryControls'])
        require(overlap[2]<=1 or overlap[3]<=1,'Visible portrait paints into fixed call controls')
        if '-camera-' in phase:
            require('camera' in geometry,'Requested synthetic camera geometry missing')
    else:
        if keyboard:
            require('keyboard' in geometry and geometry['keyboard'][2]>0 and geometry['keyboard'][3]>0,
                    'Requested software keyboard has no measured system frame')
            require(abs(geometry['keyboard'][0])<=1 and abs(geometry['keyboard'][2]-points[0])<=1,
                    'Requested portrait keyboard does not span the native window')
        for key in ('composer','chatControls','attachment','invite','attach','composerField','send'):
            if key in geometry:
                rect=geometry[key]
                require(rect[0]>=-1 and rect[1]>=-1 and rect[0]+rect[2]<=points[0]+1
                        and rect[1]+rect[3]<=points[1]+1,'Required chat control outside real screen: '+key)
                if keyboard:
                    require(rect[1]+rect[3]<=geometry['keyboard'][1]+1,
                            'Required chat control is covered by the actual keyboard: '+key)
    return data


def capture(expected):
    initial=initial_source(expected)
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
                sim('boot',identifier,timeout=global_remaining(45))
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
            aggregate_deadline=aggregate_started+AGGREGATE_CAPTURE_SECONDS
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
        require(set(receipt['captures'])==set(receipt['nativeReady'])==required_phases(),'Fifteen actual host cases incomplete')
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
            'physicalPhoneVerified':False,'startedAtUtc':now()}
    try:
        require((OUT/'ui-test-exit-code.txt').read_text().strip()=='0','Targeted native UI test process did not succeed')
        log_path=OUT/'ui-tests.log'
        require(log_path.stat().st_size<=8*1024*1024,'Oversized synthetic UI test log')
        log=log_path.read_text(errors='replace')
        require('KADE_DELLA_HOST_CONTROLS_FAILED' not in log,'Native UI controls failure marker present')
        matches=re.findall(r'KADE_DELLA_HOST_CONTROLS_PASSED (\d+) ([a-z0-9-]+)',log)
        require(len(matches)==len(UI_PHASES)==11 and {phase for _,phase in matches}==UI_PHASES
                and all(0<int(count)<=1000 for count,_ in matches),'Exact eleven UI controls markers incomplete')
        bundle=OUT/'ui-tests.xcresult'
        require(bundle.is_dir(),'Native UI result bundle missing')
        raw=subprocess.check_output(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle)],
                                    text=True,stderr=subprocess.PIPE,timeout=60)
        require(len(raw)<=1024*1024,'Oversized UI test summary')
        summary=json.loads(raw)
        counts={key:summary.get(key) for key in ('totalTestCount','passedTests','failedTests','skippedTests')}
        require(all(type(value) is int for value in counts.values()) and counts=={
            'totalTestCount':11,'passedTests':11,'failedTests':0,'skippedTests':0},
            'Native xcresult did not prove eleven successful UI tests')
        if 'expectedFailures' in summary:
            require(type(summary['expectedFailures']) is int and summary['expectedFailures']==0,
                    'Expected native UI test failures appeared')
            counts['expectedFailures']=0
        require(source(expected)['inputs']==initial['inputs'],'Source changed during UI controls tests')
        report.update(passed=True,nativeUITreeVerified=True,xcresultCounts=counts,
                      phaseChecks={phase:int(count) for count,phase in matches},
                      checks=sum(int(count) for count,_ in matches),logSha256=sha(log_path))
    except Exception as error:
        report.update(passed=False,nativeUITreeVerified=False,errorType=type(error).__name__,
                      error=str(error) if isinstance(error,RuntimeError) else 'UI result operation failed; inspect normal step logs')
        raise
    finally:
        report['finishedAtUtc']=now()
        save('ui-tests.json',report)
    return {key:report[key] for key in ('passed','nativeUITreeVerified','checks','phaseChecks','voiceOverVerified')}


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
        print(f'KADE_DELLA_HOST_QA_CHUNK {index:06d} '+chunk,flush=True)
    print('KADE_DELLA_HOST_QA_END '+digest,flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('source','preflight','device','capture','ui-tests','emit'))
    parser.add_argument('--expected-sha',required=True)
    args=parser.parse_args()
    if args.action=='source':
        result=source(args.expected_sha,clean=True); save('source.json',result)
    elif args.action=='preflight': result=simulator_preflight(args.expected_sha)
    elif args.action=='device':
        print(simulator_record(args.expected_sha)['devices']['large']['identifier']); result=None
    elif args.action=='capture': result=capture(args.expected_sha)
    elif args.action=='ui-tests': result=ui_tests(args.expected_sha)
    else: emit(args.expected_sha); result=None
    if result is not None: print(json.dumps(result,indent=2))


if __name__=='__main__':
    try: main()
    except Exception as error:
        print(json.dumps({'ok':False,'errorType':type(error).__name__,
                          'message':str(error) if isinstance(error,RuntimeError) else 'Host audit operation failed'}),file=sys.stderr)
        raise SystemExit(1)

