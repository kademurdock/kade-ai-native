import json, pathlib, plistlib, shutil, subprocess, time
out=pathlib.Path('character-audit').resolve()
app=out/'AudioProbe.app';app.mkdir(exist_ok=True)
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
subprocess.run(['xcrun','swiftc','-parse-as-library','-sdk',sdk,'-target','arm64-apple-ios17.0-simulator','dev/AudioProbe.swift','-o',str(app/'AudioProbe')],check=True)
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.kademurdock.audioprobe','CFBundleExecutable':'AudioProbe','CFBundleName':'AudioProbe','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'17.0','UILaunchScreen':{},'UIDeviceFamily':[1]}))
shutil.copyfile(out/'clock-check.wav',app/'tone.wav')
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
def simctl(*args):return subprocess.check_output(['xcrun','simctl',*args],text=True).strip()
runtimes=json.loads(simctl('list','runtimes','--json'))['runtimes']
(out/'runtimes.json').write_text(json.dumps(runtimes,indent=2))
runtimes=[r for r in reversed(runtimes) if r.get('isAvailable') and '.iOS-' in r['identifier']][:2]
types=json.loads(simctl('list','devicetypes','--json'))['devicetypes']
device=next(d['identifier'] for d in reversed(types) if 'iPhone' in d['name'] and 'Pro Max' in d['name'])
results=[];chosen=None
for runtime in runtimes:
    sim=simctl('create','Audio acceptance '+runtime['version'],device,runtime['identifier'])
    simctl('boot',sim);simctl('bootstatus',sim,'-b')
    subprocess.run(['open','-a','Simulator','--args','-CurrentDeviceUDID',sim],check=True)
    simctl('install',sim,str(app));simctl('launch',sim,'com.kademurdock.audioprobe')
    folder=pathlib.Path(simctl('get_app_container',sim,'com.kademurdock.audioprobe','data'))/'Documents'
    deadline=time.monotonic()+15;result=None
    while time.monotonic()<deadline:
        if (folder/'audio-probe.json').exists():result=json.loads((folder/'audio-probe.json').read_text());break
        time.sleep(0.2)
    result=result or {'passed':False,'error':'Minimal simulator AudioQueue did not complete within fifteen seconds'}
    result['runtime']=runtime['identifier'];results.append(result);print(json.dumps(result),flush=True)
    simctl('terminate',sim,'com.kademurdock.audioprobe')
    if result['passed']:
        chosen={'sim':sim,'runtime':runtime['identifier']};break
    simctl('shutdown',sim)
(out/'ios-audio-preflight.json').write_text(json.dumps(results,indent=2))
assert chosen,'No usable simulator audio runtime; full app compilation was not started'
(out/'simulator.json').write_text(json.dumps(chosen))
