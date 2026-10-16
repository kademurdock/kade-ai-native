"""Bounded all-cast native samples, sharing the proved unsigned host build.

No audio, credentials, account connection, second build or cloud artifact.
Local joint coordinates are renderer inputs; native screen rectangles are
measured separately. Actual phone energy and audio performance are unclaimed.
"""
import argparse
import base64
from datetime import datetime
import hashlib
import importlib.util
from io import BytesIO
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('completion_host', ROOT/'dev/della-host-layout-audit.py')
host = importlib.util.module_from_spec(spec); spec.loader.exec_module(host)
OUT = host.OUT/'completion'
PEOPLE = ('harley','kiana','lilly','della','witherspoon','lilly-private','angel')
POSES = ('neutral','gesturePeak','settled')
PHASES = tuple(person+'-'+pose for person in PEOPLE for pose in POSES)
POLICIES = ('compact','reduceMotion','offscreen','resume')
EVENTS = tuple(person+'-'+policy for person in PEOPLE for policy in POLICIES)
UI_METHODS = {'testAllCastKeyposes':'allCastKeyposes','testCompactAndMotionPolicies':'compactAndMotionPolicies',
              'testRoomySendingKeepsBodyAndComposer':'roomySendingLight'}
CAPTURE_SECONDS = 300
UI_SECONDS = 600
MAX_FILES = 25
IDS = {
 'harley':('agent_d26Mtu8mgOzkVGQECqO1a','agent-agent_d26Mtu8mgOzkVGQECqO1a-avatar-1789921519491.png'),
 'kiana':('agent_6llV0eMu4fmIaj8f2x1Sb','agent-agent_6llV0eMu4fmIaj8f2x1Sb-avatar-1789863013865.png'),
 'lilly':('agent_TOdYS8v-bRxeNw0dia_Md','agent-agent_TOdYS8v-bRxeNw0dia_Md-avatar-1790323412634.png'),
 'della':('agent_BSOLa3eNEZyjs-7abCjMt','agent-agent_BSOLa3eNEZyjs-7abCjMt-avatar-1788941611099.png'),
 'witherspoon':('agent_o7TKU3lK0Euo0MKgpNpvZ','agent-agent_o7TKU3lK0Euo0MKgpNpvZ-avatar-1790252530815.png'),
 'lilly-private':('agent_JhouuajXMYsfhCTVMQCv_','agent-agent_JhouuajXMYsfhCTVMQCv_-avatar-1783012583668.png'),
 'angel':('agent_NkG_Fb8_xLz8HFJyx4gNv','agent-agent_NkG_Fb8_xLz8HFJyx4gNv-avatar-1791586815115.png'),
}
RENDERERS = {person:('conversation-upper-body-'+('lilly' if person=='lilly-private' else person)+'-v1')
             for person in PEOPLE if person not in ('della','angel')}
RENDERERS.update(della='della-articulated',angel='angel-vector')
ASSETS = {
 'harley':['CharacterHarleyFaces','CharacterHarleyMouths','CharacterHarleyNuance','CharacterHarleyBustBody','CharacterHarleyBustMask'],
 'kiana':['CharacterKianaFaces','CharacterKianaMouths','CharacterKianaNuance'],
 'lilly':['CharacterLillyFaces','CharacterLillyMouths','CharacterLillyNuance','CharacterLillyBustBody'],
 'della':['CharacterDellaArticulatedReview','CharacterDellaBustBody','CharacterDellaBustMask'],
 'witherspoon':['CharacterWitherspoonFaces','CharacterWitherspoonMouths','CharacterWitherspoonBustBody'],
 'angel':['CharacterAngelVectorArt'],
}
ASSETS['lilly-private'] = ASSETS['lilly']
COMMON = {'headAngle','bodyAngle','headOffsetY','bodyOffsetY','nearArmAngle','farArmAngle'}
JOINTS = {'leftShoulderX','leftShoulderY','leftElbowX','leftElbowY','leftWristX','leftWristY',
 'rightShoulderX','rightShoulderY','rightElbowX','rightElbowY','rightWristX','rightWristY',
 'leftShoulderDegrees','leftElbowDegrees','leftWristDegrees','rightShoulderDegrees','rightElbowDegrees','rightWristDegrees',
 'leftHandDegrees','rightHandDegrees','leftOpenness','rightOpenness','bodyDegrees','bodyLift','headDegrees','headLift'}
REGISTRATION = {
 'kiana':((.12,.84),(.13,1.09),(.29,1.26),(.88,.90),(.87,1.12),(.71,1.26)),
 'harley':((.20,.86),(.17,1.09),(.30,1.25),(.80,.86),(.83,1.09),(.70,1.25)),
 'lilly':((.23,.87),(.19,1.09),(.31,1.26),(.77,.87),(.81,1.09),(.69,1.26)),
 'witherspoon':((.22,.85),(.18,1.09),(.31,1.25),(.78,.85),(.82,1.09),(.69,1.25)),
}
READY_FIELDS = {'schema','source','phase','character','avatarPath','appearance','windowPoints','geometry','render',
 'samples','policy','captureFrozen','completedInputs','jointCoordinateSpace','syntheticOutput','networkRequestsBlocked',
 'blockedRequestCount','audioStarted','microphoneStarted','cameraStarted','physicalPhoneVerified','batteryMeasured','voiceOverVerified'}


def require(value, message): host.require(value, message)
def integer(value, lower=0, upper=256): return type(value) is int and lower<=value<=upper
def require_boot_order(regression,boot,launch):
    moments=[datetime.fromisoformat(record[key]) for record,key in
             ((regression,'finishedAtUtc'),(boot,'startedAtUtc'),(boot,'finishedAtUtc'),(launch,'startedAtUtc'))]
    require(all(moment.tzinfo is not None for moment in moments)
            and all(first<second for first,second in zip(moments,moments[1:])),
            'Completion boot/launch must follow the completed regression suite in order')

def save(name, data):
    OUT.mkdir(parents=True,exist_ok=True)
    packed=(json.dumps(data,indent=2)+'\n').encode()
    require(len(packed)<=256*1024,'Completion receipt exceeds256KiB')
    (OUT/name).write_bytes(packed)


def validate_joints(values, person):
    kind='lilly' if person=='lilly-private' else person
    registration=REGISTRATION[kind]
    for offset,side in ((0,'left'),(3,'right')):
        shoulder,elbow,wrist=registration[offset:offset+3]
        def point(joint): return (values[side+joint+'X'],values[side+joint+'Y'])
        def rotate(vector,degrees):
            angle=math.radians(degrees)
            return (vector[0]*math.cos(angle)-vector[1]*math.sin(angle),vector[0]*math.sin(angle)+vector[1]*math.cos(angle))
        require(all(abs(a-b)<1e-6 for a,b in zip(point('Shoulder'),shoulder)),'Native shoulder registration drift')
        upper=rotate((elbow[0]-shoulder[0],elbow[1]-shoulder[1]),values[side+'ShoulderDegrees'])
        lower=rotate((wrist[0]-elbow[0],wrist[1]-elbow[1]),values[side+'ShoulderDegrees']+values[side+'ElbowDegrees'])
        actual_elbow=point('Elbow');actual_wrist=point('Wrist')
        require(all(abs(a-b)<1e-6 for a,b in zip(actual_elbow,(shoulder[0]+upper[0],shoulder[1]+upper[1])))
                and all(abs(a-b)<1e-6 for a,b in zip(actual_wrist,(actual_elbow[0]+lower[0],actual_elbow[1]+lower[1]))),
                'Native arm chain detached or changed bone lengths')
        hand=math.degrees(math.atan2(lower[1],lower[0]))-90+values[side+'WristDegrees']
        require(abs(values[side+'HandDegrees']-hand)<1e-6,'Native hand rotation differs from its attached wrist')
        require(abs(values[side+'ShoulderDegrees'])<=4 and abs(values[side+'ElbowDegrees'])<=28
                and abs(values[side+'WristDegrees'])<=10 and 0<=values[side+'Openness']<=1,
                'Native joint limits exceeded')


def validate_ready(data, phase, source):
    require(isinstance(data,dict) and set(data)==READY_FIELDS and data['schema']=='kade.puppet-completion-ready.v1'
            and data['source']==source and phase in PHASES and data['phase']==phase,'Completion native schema/source/phase mismatch')
    person,pose=phase.rsplit('-',1)
    require(data['character']==person and data['avatarPath']=='/images/'+IDS[person][1]
            and data['appearance']=='light' and data['windowPoints']==[440,956]
            and data['policy']=='normal' and data['captureFrozen'] is True
            and data['completedInputs']==9 and type(data['completedInputs']) is int
            and data['jointCoordinateSpace']=='rendererLocalBeforeParentTransform','Completion fixture ownership/framing mismatch')
    require(data['syntheticOutput'] is True and data['networkRequestsBlocked'] is True
            and type(data['blockedRequestCount']) is int and data['blockedRequestCount']==0
            and all(data[name] is False for name in ('audioStarted','microphoneStarted','cameraStarted',
                 'physicalPhoneVerified','batteryMeasured','voiceOverVerified')),'Completion fixture invoked external activity or inflated claims')
    geometry=data['geometry']
    require(isinstance(geometry,dict) and set(geometry)=={'window','stage','portrait'}
            and all(host.rectangle(rect) and rect[2]>0 and rect[3]>0 for rect in geometry.values()),'Invalid native completion rectangles')
    window=geometry['window']
    require(abs(window[0])<1 and abs(window[1])<1 and window[2:]==[440,956]
            and all(host.contains(window,rect) for key,rect in geometry.items() if key!='window'),
            'Completion artwork frame falls outside the actual phone window')
    stage,portrait=geometry['stage'],geometry['portrait']
    require(host.contains(stage,portrait) and abs(stage[0]-portrait[0])<1
            and abs(stage[1]-(portrait[1]-4))<1 and abs(stage[2]-portrait[2])<1
            and abs(stage[3]-(portrait[3]+8))<1,
            'Measured native stage does not contain its actual portrait')
    render=data['render'];samples=data['samples']
    require(isinstance(render,dict) and set(render)=={'agentID','renderer','assets','side','height','time','active',
                'framesPerSecond','paused','face','viseme','values'}
            and render['agentID']==IDS[person][0] and render['renderer']==RENDERERS[person]
            and render['assets']==ASSETS[person] and render['side']==208 and type(render['side']) in (int,float)
            and render['active'] is True and render['paused'] is False,'Actual completion renderer/asset ownership mismatch')
    height=208 if person=='angel' else 208*620/414
    expected_time=1000+PEOPLE.index(person)*100+(-.05 if pose=='neutral' else .65 if pose=='gesturePeak' else 14.25)
    require(host.number(render['height']) and abs(render['height']-height)<1e-6
            and host.number(render['time']) and abs(render['time']-expected_time)<1e-6
            and abs(geometry['portrait'][2]-248)<1 and abs(geometry['portrait'][3]-(height+40))<1,
            'Native renderer and measured portrait dimensions disagree')
    # Oct 16 2026: the resting stage samples its breathing and drift at 12 fps.
    expected_fps=12 if pose=='neutral' else 24
    require(render['framesPerSecond']==expected_fps and type(render['framesPerSecond']) in (int,float)
            and type(render['face']) is int and render['face']==(0 if pose=='neutral' else 1)
            and integer(render['viseme'],0,8) and ((render['viseme']>0) if pose=='gesturePeak' else render['viseme']==0),
            'Native face, output ownership or clock activity mismatch')
    require(isinstance(samples,dict) and set(samples)=={'count','active','paused','distinctTimes','distinctVectors','maximumFPS','invalid'}
            and integer(samples['count'],3) and integer(samples['active'],3,samples['count'])
            and integer(samples['paused'],0,samples['count']) and samples['active']+samples['paused']==samples['count']
            and integer(samples['distinctTimes'],3,samples['count']) and integer(samples['distinctVectors'],2,samples['count'])
            and samples['maximumFPS']==expected_fps and samples['invalid'] is False,
            'No genuine bounded native motion observations before capture')
    values=render['values']
    keys=COMMON|(JOINTS if person in REGISTRATION or person=='lilly-private' else
                {'leftShoulderDegrees','rightShoulderDegrees'} if person=='della' else
                {'claspDegrees','claspOffsetX','claspOffsetY','gazeX','gazeY'})
    require(isinstance(values,dict) and set(values)==keys
            and all(host.number(value) and abs(value)<=10_000 for value in values.values()),'Unknown or nonfinite native motion outputs')
    if person in REGISTRATION or person=='lilly-private':
        validate_joints(values,person)
        kind='lilly' if person=='lilly-private' else person
        # Oct 16 2026: Kiana's crop allows 1.1 degrees and 0.9 px of nod;
        # Witherspoon turns up to 1.3 degrees the crown-safe way (0.35 clockwise).
        head_limit,body_limit,crop,head_offset={'harley':(2,.75,540,3),'kiana':(1.1,.55,620,.9),
                                  'lilly':(1.95,.65,700,1.7),'witherspoon':(1.3,.42,620,.6)}[kind]
        require(abs(values['headDegrees'])<=head_limit and abs(values['bodyDegrees'])<=body_limit
                and (kind!='witherspoon' or values['headDegrees']<=.35+1e-9)
                and abs(values['bodyLift'])<=.0024 and abs(values['headLift']*crop)<=head_offset
                and abs(values['headAngle']-values['headDegrees'])<1e-6
                and abs(values['bodyAngle']-values['bodyDegrees'])<1e-6
                and abs(values['headOffsetY']-values['headLift']*crop)<1e-6
                and abs(values['bodyOffsetY']+values['bodyLift']*crop)<1e-6
                and abs(values['nearArmAngle']-values['rightShoulderDegrees'])<1e-6
                and abs(values['farArmAngle']-values['leftShoulderDegrees'])<1e-6,
                'Recorded common transforms differ from the actual rendered body pose')
    elif person=='della':
        require(abs(values['leftShoulderDegrees'])<=3 and abs(values['rightShoulderDegrees'])<=3,
                'Della native shoulder rotation exceeds its registered overlap')
        require(abs(values['headAngle'])<=1.55 and abs(values['bodyAngle'])<=.16
                and abs(values['headOffsetY'])<=.65 and abs(values['bodyOffsetY'])<1e-6
                and abs(values['nearArmAngle']-values['rightShoulderDegrees'])<1e-6
                and abs(values['farArmAngle']-values['leftShoulderDegrees'])<1e-6,
                'Della common output does not match its actual sleeve rotation')
    else:
        require(abs(values['claspDegrees'])<=1.5 and abs(values['claspOffsetX'])<=.004
                and abs(values['claspOffsetY'])<=.008 and abs(values['gazeX'])<=.4 and abs(values['gazeY'])<=.4,
                'Angel native clasp/gaze exceeds existing geometry limits')
        require(abs(values['headAngle'])<=1.8 and abs(values['bodyAngle'])<=.4
                and abs(values['headOffsetY'])<=2 and abs(values['bodyOffsetY'])<=1.5
                and abs(values['nearArmAngle']-values['claspDegrees'])<1e-6
                and abs(values['farArmAngle']-values['claspDegrees'])<1e-6,
                'Angel common output differs from its actual joined clasp')
    if pose=='gesturePeak':
        require(abs(values['nearArmAngle'])+abs(values['farArmAngle'])>.01,'The active native gesture did not move an attached arm')
    else:
        require(abs(values['nearArmAngle'])<1e-6 and abs(values['farArmAngle'])<1e-6,
                'Resting or settled output retained a speech arm gesture')
        if person in REGISTRATION or person=='lilly-private':
            require(all(abs(values[side+joint+'Degrees'])<1e-6 for side in ('left','right')
                        for joint in ('Shoulder','Elbow','Wrist')),
                    'Resting output retained a bent elbow or wrist gesture')
        elif person=='angel':
            require(abs(values['claspOffsetX'])<1e-6 and abs(values['claspOffsetY'])<1e-6,
                    'Resting Angel retained a translated clasp')
    return data


def ui(expected):
    initial=host.initial_source(expected)
    report={'schema':'kade.puppet-completion-ui.v1','source':initial,'passed':False,
            'nativeUITreeVerified':False,'physicalPhoneVerified':False,'voiceOverVerified':False}
    try:
        regression=json.loads((host.OUT/'ui-tests.json').read_text())
        require(regression.get('source')==initial and regression.get('passed') is True
                and regression.get('nativeUITreeVerified') is True,'Completion UI requires all24 real host regressions first')
        boot=json.loads((host.OUT/'ui-boot-completion.json').read_bytes())
        host.validate_ui_boot(boot,'large',initial)
        require(boot.get('passed') is True,'Completion UI requires its own successful fresh Pro Max boot')
        launch=host.run_ui(expected,'large',completion=True);report['launch']=launch
        require(launch.get('boot')==boot,'Completion UI differs from its distinct native boot record')
        require_boot_order(regression,boot,launch)
        require(launch['passed'] is True and launch['exitCode']==0 and not launch['timedOut'] and not launch['logLimitExceeded'],
                'Completion native UI launch did not complete')
        log=(host.OUT/'ui-tests-completion.log').read_text(encoding='utf-8',errors='replace')
        phases=re.findall(r'KADE_PUPPET_COMPLETION_UI_PHASE_PASS ([A-Za-z0-9-]+)',log)
        require(len(phases)==len(set(phases))==50 and set(phases)==set(PHASES)|set(EVENTS)|{'roomy-sending-light'},
                'Native all-cast/compact/policy phase markers are incomplete or duplicated')
        raw=subprocess.check_output(['xcrun','xcresulttool','get','test-results','summary','--path',str(host.OUT/'ui-tests-completion.xcresult')],
                stderr=subprocess.PIPE,timeout=host.operation_remaining(30))
        require(len(raw)<=1024*1024,'Completion xcresult summary exceeds1MiB')
        summary=json.loads(raw);counts={name:summary.get(name) for name in ('totalTestCount','passedTests','failedTests','skippedTests')}
        require(all(type(value) is int for value in counts.values()) and counts=={
            'totalTestCount':3,'passedTests':3,'failedTests':0,'skippedTests':0}
            and type(summary.get('expectedFailures',0)) is int and summary.get('expectedFailures',0)==0,
            'All three complete zero-failure native completion tests are required')
        require(set(launch['testMethods'])==set(UI_METHODS)
                and all(value['status']=='passed' for value in launch['testMethods'].values()),'Native completion test methods incomplete')
        report.update(passed=True,nativeUITreeVerified=True,phaseChecks=sorted(phases),xcresultCounts=counts,
                      logSha256=host.sha(host.OUT/'ui-tests-completion.log'),
                      regressionReceiptSha256=host.sha(host.OUT/'ui-tests.json'))
    finally:
        # run_ui saves its native process/last-method record even when it raises.
        launch_path=host.OUT/'ui-run-completion.json'
        if launch_path.is_file():
            require(0<launch_path.stat().st_size<=256*1024,'Completion launch diagnostic exceeds256KiB')
            retained=json.loads(launch_path.read_bytes())
            require(retained.get('schema')=='kade.puppet-completion-ui-launch.v1'
                    and retained.get('source')==initial and retained.get('device')=='large',
                    'Completion launch diagnostic source/class drift')
            if 'launch' in report:require(report['launch']==retained,'Saved completion launch differs from native return')
            report['launch']=retained
        report['finishedAtUtc']=host.now();save('ui-tests.json',report)
    return {'passed':True,'nativeUITreeVerified':True,'methods':3,'phaseChecks':50}


def capture(expected):
    initial=host.initial_source(expected)
    proof=json.loads((OUT/'ui-tests.json').read_text())
    require(proof.get('source')==initial and proof.get('passed') is True,'Completion capture requires both complete native UI tests')
    compiled=host.compiled_tests(expected)
    require(compiled==proof['launch']['compiledRunner'],'Completion screenshot app differs from tested compiled runner')
    device=host.simulator_record(expected)['devices']['large'];identifier=device['identifier']
    report={'schema':'kade.puppet-completion-capture.v2','source':initial,'passed':False,'captures':{},'captureEncodings':{},'nativeReady':{},
        'ownedProcess':None,'ownedTermination':None,'compiledAfterVerified':False,
        'compiledRunner':compiled,'device':device,'syntheticOutput':True,'audioStarted':False,'microphoneStarted':False,
        'cameraStarted':False,'networkStarted':False,'physicalPhoneVerified':False,'batteryMeasured':False,'voiceOverVerified':False,
        'captureTimeoutSeconds':CAPTURE_SECONDS,'startedAtUtc':host.now()}
    started=time.monotonic();deadline=started+host.operation_remaining(CAPTURE_SECONDS)
    def remaining(bound):
        work_deadline=deadline-15
        require(time.monotonic()<work_deadline,'Finite completion capture work deadline expired')
        return min(bound,work_deadline-time.monotonic(),host.operation_remaining(bound))
    try:
        OUT.mkdir(parents=True,exist_ok=True)
        documents=Path(host.sim('get_app_container',identifier,host.BUNDLE_ID,'data',timeout=remaining(45)))/'Documents'
        ready=documents/'puppet-completion-ready.json';ack=documents/'puppet-completion-captured.txt'
        ready.unlink(missing_ok=True);ack.unlink(missing_ok=True)
        host.sim('ui',identifier,'appearance','light',timeout=remaining(30))
        environment=dict(os.environ,SIMCTL_CHILD_KADE_CHARACTER_AUDIT='1',SIMCTL_CHILD_KADE_A11Y_AUDIT='1',
            SIMCTL_CHILD_KADE_PUPPET_COMPLETION_AUDIT='1',SIMCTL_CHILD_KADE_PUPPET_COMPLETION_UI='0',
            SIMCTL_CHILD_KADE_PUPPET_COMPLETION_SOURCE=expected)
        launch_started=host.now()
        launched=host.sim('launch',identifier,host.BUNDLE_ID,env=environment,timeout=remaining(45))
        launch_finished=host.now()
        report['ownedProcess']=host.owned_process_identity(host.launch_pid(launched),identifier,compiled,
                                                          deadline-15,launch_started,launch_finished)
        for phase in PHASES:
            ready_deadline=time.monotonic()+remaining(30);data=None
            while time.monotonic()<ready_deadline:
                if ready.is_file():
                    require(0<ready.stat().st_size<=64*1024,'Completion native readiness exceeds64KiB')
                    candidate=json.loads(ready.read_bytes())
                    if candidate.get('phase')==phase:data=validate_ready(candidate,phase,expected);break
                time.sleep(min(.1,remaining(.1)))
            require(data is not None,'Native completion readiness missing: '+phase)
            name='puppet-completion-'+phase+'.png';path=OUT/name
            require(not path.exists(),'Refusing to overwrite native completion media')
            original=host.original_capture_path(path)
            host.sim('io',identifier,'screenshot',str(original),timeout=remaining(75))
            metadata,encoding=host.publish_capture_copy(path,original)
            require(metadata['pixels']==[1320,2868],'Completion PNG differs from actual Pro Max portrait pixels')
            report['nativeReady'][phase]=data;report['captures'][phase]=metadata
            report['captureEncodings'][phase]=encoding
            save('receipt.json',report)
            ack.write_text(phase,encoding='utf-8')
        require(host.source(expected)['inputs']==initial['inputs'],'Completion source drifted during native capture')
        report['passed']=True
    except Exception as error:
        report.update(errorType=type(error).__name__,error=str(error) if isinstance(error,RuntimeError) else 'Bounded completion capture failed')
        raise
    finally:
        cleanup_deadline=None;report['terminationVerified']=False
        try:
            cleanup_deadline=min(deadline,time.monotonic()+host.operation_remaining(15))
            report['ownedTermination']={}
            host.terminate_owned_process(report['ownedProcess'],identifier,compiled,cleanup_deadline,
                                         report['ownedTermination'],bound=15)
            report['terminationVerified']=report['ownedTermination']['passed']
        except Exception as error:
            report.update(terminationErrorType=type(error).__name__,terminationError=host.sanitize_ui_line(str(error))
                          if isinstance(error,RuntimeError) else 'Completion owned process exit failed')
        try:
            require(cleanup_deadline is not None,'Completion cleanup has no remaining compiled-after deadline')
            host.compiled_unchanged(expected,compiled,cleanup_deadline);report['compiledAfterVerified']=True
        except Exception as error:
            report.update(compiledAfterErrorType=type(error).__name__,compiledAfterError=host.sanitize_ui_line(str(error))
                          if isinstance(error,RuntimeError) else 'Completion compiled-after rehash failed')
        report['elapsedSeconds']=round(time.monotonic()-started,3);report['finishedAtUtc']=host.now()
        if not report['terminationVerified'] or not report['compiledAfterVerified']:report['passed']=False
        validate_capture_ownership(report)
        save('receipt.json',report)
    require(report['passed'],'Completion native app termination did not complete')
    return {'passed':True,'captures':21,'syntheticOutput':True,'physicalPhoneVerified':False}


def validate_capture_ownership(report):
    require(report.get('schema')=='kade.puppet-completion-capture.v2'
            and type(report.get('compiledAfterVerified')) is bool,'Completion capture owned-process schema mismatch')
    owned=report.get('ownedProcess');termination=report.get('ownedTermination')
    host.validate_compiled_record(report['compiledRunner'],report['source'])
    if owned is not None:
        host.validate_owned_process(owned,report['device']['identifier'],report['compiledRunner'])
        require(datetime.fromisoformat(report['startedAtUtc'])<=datetime.fromisoformat(owned['launchStartedAtUtc']),
                'Owned completion launch precedes its native capture receipt')
    if termination is not None:
        host.validate_owned_termination(termination,owned)
        require(termination['timeoutSeconds']<=15 and report['terminationVerified']==termination['passed'],
                'Completion exit exceeded its original15-second cap or contradicted observed exit')
        if 'finishedAtUtc' in report:require(datetime.fromisoformat(termination['finishedAtUtc'])<=datetime.fromisoformat(report['finishedAtUtc']),
                                            'Owned completion exit follows the final native capture receipt')
    if report.get('passed'):
        require(owned is not None and termination is not None and termination['passed'] is True
                and report['terminationVerified'] is True and report['compiledAfterVerified'] is True
                and host.number(report.get('elapsedSeconds')) and 0<=report['elapsedSeconds']<=CAPTURE_SECONDS+1,
                'Successful completion capture lacks an observed native exit or unchanged compiled artifacts')
    return report


def emit(expected):
    initial=host.initial_source(expected)
    files={'source.json':(host.OUT/'source.json').read_bytes()}
    for name in ('ui-tests.json','receipt.json'):
        path=OUT/name
        if path.is_file():
            require(path.stat().st_size<=256*1024,'Completion JSON exceeds256KiB')
            record=json.loads(path.read_bytes());require(record.get('source')==initial,'Completion evidence source drift')
            if name=='ui-tests.json' and record.get('passed') is True:
                boot_path=host.OUT/'ui-boot-completion.json'
                require(boot_path.is_file() and 0<boot_path.stat().st_size<=256*1024,'Distinct completion boot record missing/oversized')
                boot=json.loads(boot_path.read_bytes());host.validate_ui_boot(boot,'large',initial)
                require(boot.get('passed') is True and record.get('launch',{}).get('boot')==boot,
                        'Completion evidence boot differs from the distinct native preflight')
                regression=json.loads((host.OUT/'ui-tests.json').read_bytes())
                require(regression.get('source')==initial and regression.get('passed') is True,
                        'Completion evidence lost the successful regression source')
                require_boot_order(regression,boot,record['launch'])
            files[name]=path.read_bytes()
            if name=='receipt.json':
                validate_capture_ownership(record)
                host.validate_capture_encoding_inventory(record,PHASES,'puppet-completion-')
                for phase,metadata in record.get('captures',{}).items():
                    require(phase in PHASES and metadata['file']=='puppet-completion-'+phase+'.png','Unsafe completion image name')
                    path=OUT/metadata['file']
                    files[path.name]=host.verified_capture_bytes(path,metadata,record['captureEncodings'][phase])
    require(len(files)+1<=MAX_FILES and sum(map(len,files.values()))<=host.MAX_RAW,'Completion evidence exceeds fixed bounds')
    manifest={'schema':'kade.puppet-completion-log-evidence.v1','sha':expected,
        'files':{name:{'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()} for name,data in files.items()},
        'artifactStorageUsed':False,'ipaIncluded':False,'physicalPhoneVerified':False,'batteryMeasured':False,'voiceOverVerified':False}
    files['evidence-manifest.json']=(json.dumps(manifest,indent=2)+'\n').encode()
    require(sum(map(len,files.values()))<=host.MAX_RAW,'Final completion raw payload exceeds50MiB')
    buffer=BytesIO()
    with zipfile.ZipFile(buffer,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for name,data in sorted(files.items()):archive.writestr(name,data)
    archive=buffer.getvalue();require(len(archive)<=host.MAX_ARCHIVE,'Completion archive exceeds32MiB')
    encoded=base64.b64encode(archive).decode();require(len(encoded)<=host.MAX_ENCODED,'Completion transport exceeds44MiB')
    digest=hashlib.sha256(archive).hexdigest();chunks=[encoded[index:index+65536] for index in range(0,len(encoded),65536)]
    header={'schema':'kade.puppet-completion-log-evidence.v1','sha':expected,'archiveSha256':digest,
        'archiveBytes':len(archive),'encodedBytes':len(encoded),'chunks':len(chunks),'files':len(files),
        'encoding':'base64','artifactStorageUsed':False}
    print('KADE_PUPPET_COMPLETION_QA_BEGIN '+json.dumps(header,separators=(',',':')),flush=True)
    for index,chunk in enumerate(chunks,1):
        host.operation_remaining(1);print(f'KADE_PUPPET_COMPLETION_QA_CHUNK {index:06d} '+chunk,flush=True)
    print('KADE_PUPPET_COMPLETION_QA_END '+digest,flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('boot','ui','capture','emit-all'));parser.add_argument('--expected-sha',required=True)
    args=parser.parse_args()
    source_path=host.OUT/'source.json'
    require(source_path.is_file() and 0<source_path.stat().st_size<=256*1024,'Original completion source record missing or oversized')
    recorded=json.loads(source_path.read_bytes());host.validate_operation_source(recorded)
    started=datetime.fromisoformat(recorded['operationStartedAtUtc']).timestamp()
    # Two base64 evidence archives through logs took 34-66 s; keep a 240 s bound.
    if args.action=='emit-all':host._OPERATION_DEADLINE=min(time.time()+240,started+host.JOB_SECONDS-15)
    else:
        shared=datetime.fromisoformat(recorded['operationDeadlineUtc']).timestamp()
        action=time.time()+(host.BOOT_SECONDS+30 if args.action=='boot' else host.UI_GUARD_SECONDS['large'] if args.action=='ui' else CAPTURE_SECONDS+15)
        host._OPERATION_DEADLINE=min(shared,action)
        host._DEADLINE_ROLE='actionGuardDeadline' if action<shared else 'sharedOperationDeadline'
    host.initial_source(args.expected_sha)
    if args.action=='boot':print(json.dumps(host.boot_ui(args.expected_sha,'large',completion=True)))
    elif args.action=='ui':print(json.dumps(ui(args.expected_sha)))
    elif args.action=='capture':print(json.dumps(capture(args.expected_sha)))
    else:host.emit(args.expected_sha);emit(args.expected_sha)


if __name__=='__main__':
    try:main()
    except Exception as error:
        print(json.dumps({'ok':False,'errorType':type(error).__name__,
            'message':str(error) if isinstance(error,RuntimeError) else 'Bounded completion operation failed'}),file=sys.stderr)
        raise SystemExit(1)
