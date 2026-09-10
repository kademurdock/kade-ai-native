import json, os, pathlib, subprocess, time, signal

out = pathlib.Path('character-audit')
def run(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True).strip()
runtimes=json.loads(run('list','runtimes','--json'))['runtimes']
runtime=next(r['identifier'] for r in reversed(runtimes) if r.get('isAvailable') and '.iOS-' in r['identifier'])
devices=json.loads(run('list','devicetypes','--json'))['devicetypes']
device=next(d['identifier'] for d in reversed(devices) if 'iPhone' in d['name'] and 'Pro Max' in d['name'])
sim=run('create','Character playback acceptance',device,runtime)
video=None
try:
    run('boot',sim); run('bootstatus',sim,'-b')
    run('ui',sim,'appearance','light')
    app=pathlib.Path('build/character-simulator/Build/Products/Debug-iphonesimulator/KadeAI.app').resolve()
    run('install',sim,str(app))
    env=dict(os.environ,SIMCTL_CHILD_KADE_A11Y_AUDIT='1',SIMCTL_CHILD_KADE_CHARACTER_AUDIT='1')
    video=subprocess.Popen(['xcrun','simctl','io',sim,'recordVideo','--codec=h264',str(out/'playback.mp4')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun','simctl','launch',sim,'com.kademurdock.kadeai'],env=env,check=True)
    documents=pathlib.Path(run('get_app_container',sim,'com.kademurdock.kadeai','data'))/'Documents'
    deadline=time.monotonic()+90; seen=set(); result=None
    while time.monotonic()<deadline:
        phase=documents/'character-phase.txt'
        if phase.exists():
            label=phase.read_text().strip()
            if label not in seen:
                seen.add(label)
                safe=''.join(c if c.isalnum() or c=='-' else '_' for c in label)[:90]
                run('io',sim,'screenshot',str(out/(str(len(seen))+'-'+safe+'.png')))
        report=documents/'character-audit.json'
        if report.exists(): result=json.loads(report.read_text()); break
        time.sleep(0.2)
    if result is None: result={'passed':False,'error':'No completed native runtime receipt within ninety seconds','phases':list(seen)}
    (out/'result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2),flush=True)
    assert result.get('passed'),result.get('error')
finally:
    if video is not None:
        video.send_signal(signal.SIGINT)
        try:video.wait(timeout=10)
        except subprocess.TimeoutExpired: video.terminate()
    subprocess.run(['xcrun','simctl','terminate',sim,'com.kademurdock.kadeai'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun','simctl','shutdown',sim],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
