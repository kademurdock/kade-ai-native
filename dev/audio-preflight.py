import json, math, pathlib, struct, subprocess, time, wave

out=pathlib.Path('character-audit')
tone=out/'clock-check.wav'
with wave.open(str(tone),'wb') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(48000)
    f.writeframes(b''.join(struct.pack('<h',int(math.sin(i*2*math.pi*230/48000)*6500)) for i in range(48000)))
start=time.monotonic()
try:
    result=subprocess.run(['afplay',str(tone)],timeout=12,capture_output=True,text=True)
    receipt={'passed':result.returncode==0,'seconds':time.monotonic()-start,'exitCode':result.returncode,'stderr':result.stderr}
except subprocess.TimeoutExpired:
    receipt={'passed':False,'error':'Mac host AudioQueue could not play a one-second local WAV within twelve seconds'}
(out/'audio-preflight.json').write_text(json.dumps(receipt,indent=2))
print(json.dumps(receipt),flush=True)
assert receipt['passed'], 'Host audio must work before compiling the simulator'
