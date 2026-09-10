import json, os, pathlib, subprocess, time, signal

out = pathlib.Path('character-audit').resolve()
out.mkdir(exist_ok=True)
def run(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True).strip()
runtimes=json.loads(run('list','runtimes','--json'))['runtimes']
runtime=next(r['identifier'] for r in reversed(runtimes) if r.get('isAvailable') and '.iOS-' in r['identifier'])
devices=json.loads(run('list','devicetypes','--json'))['devicetypes']
device=next(d['identifier'] for d in reversed(devices) if 'iPhone' in d['name'] and 'Pro Max' in d['name'])
prepared=out/'simulator.json'
sim=json.loads(prepared.read_text())['sim'] if prepared.exists() else run('create','Character playback acceptance',device,runtime)
video=None
try:
    if not prepared.exists():run('boot',sim)
    run('bootstatus',sim,'-b')
    # Simulator.app owns the host-facing audio surface; simctl alone can render
    # screenshots while that surface is absent on a headless build worker.
    subprocess.run(['open','-a','Simulator','--args','-CurrentDeviceUDID',sim],check=True)
    time.sleep(2)
    run('ui',sim,'appearance','light')
    app=pathlib.Path('build/character-simulator/Build/Products/Debug-iphonesimulator/KadeAI.app').resolve()
    run('install',sim,str(app))
    env=dict(os.environ,SIMCTL_CHILD_KADE_A11Y_AUDIT='1',SIMCTL_CHILD_KADE_CHARACTER_AUDIT='1')
    video=subprocess.Popen(['xcrun','simctl','io',sim,'recordVideo','--codec=h264',str(out/'playback.mp4')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    launch=subprocess.check_output(['xcrun','simctl','launch','--stdout='+str((out/'app.stdout').resolve()),'--stderr='+str((out/'app.stderr').resolve()),sim,'com.kademurdock.kadeai'],env=env,text=True)
    pid=launch.strip().split()[-1];print(launch,flush=True)
    documents=pathlib.Path(run('get_app_container',sim,'com.kademurdock.kadeai','data'))/'Documents'
    deadline=time.monotonic()+90; seen=set(); result=None; died=None
    while time.monotonic()<deadline:
        phase=documents/'character-phase.txt'
        if phase.exists():
            label=phase.read_text().strip()
            if label not in seen:
                seen.add(label)
                safe=''.join(c if c.isalnum() or c=='-' else '_' for c in label)[:90]
                run('io',sim,'screenshot',str(out/(str(len(seen))+'-'+safe+'.png')))
                (documents/'character-captured.txt').write_text(label)
        report=documents/'character-audit.json'
        if report.exists(): result=json.loads(report.read_text()); break
        # Sep 10 2026: a CoreAudio HAL deadlock aborts the process outright, and
        # sitting out the rest of the ninety seconds only buys a longer video
        # and a vaguer error. Notice the death, name it, stop.
        try: os.kill(int(pid),0)
        except PermissionError: pass
        except (ProcessLookupError,ValueError,OSError):
            died='The app terminated before writing its receipt - read runtime.log (a CoreAudio HAL deadlock aborts here)'
            break
        time.sleep(0.2)
    if result is None:
        if died is None:
            subprocess.run(['/usr/bin/sample',pid,'2','-file',str(out/'stalled-sample.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
        checkpoint=documents/'character-checkpoint.txt'
        result={'passed':False,'error':died or 'No completed native runtime receipt within ninety seconds','phases':list(seen),'checkpoint':checkpoint.read_text() if checkpoint.exists() else None}
    subprocess.run(['xcrun','simctl','spawn',sim,'log','show','--last','3m','--style','compact','--predicate','process == "KadeAI"'],stdout=(out/'runtime.log').open('w'),stderr=subprocess.STDOUT,timeout=15)
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

