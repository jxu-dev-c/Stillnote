#!/usr/bin/env python3
"""Compare fresh local workers. Accepts 16 kHz mono float32 PCM; writes local JSON."""
import argparse, hashlib, json, os, pathlib, platform, signal, statistics, subprocess, time
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('pcm'); p.add_argument('--model', required=True)
p.add_argument('--baseline', default='.build/moss-baseline/StillnoteSpeechWorker')
p.add_argument('--worker', default='.build/release/StillnoteSpeechWorker')
p.add_argument('--runs', type=int, default=3)
p.add_argument('--modes', nargs='+', choices=['baseline','quality','balanced','low-memory'], default=['baseline','quality','balanced','low-memory'])
p.add_argument('--output', default='.build/moss-bench/results.json')
a=p.parse_args(); results=[]
if a.runs < 1: p.error('--runs must be positive')
def checksum(path):
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()
pcm_hash=checksum(a.pcm)

for run in range(a.runs):
    for mode in a.modes:
        worker = a.baseline if mode == 'baseline' else a.worker
        args = [worker, a.pcm, a.model, 'auto', '0']
        if mode not in ('baseline', 'quality'): args += ['[]', mode]
        worker_hash=checksum(worker)
        started=time.monotonic()
        proc=subprocess.Popen(['/usr/bin/time', '-l', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True,
            env={**os.environ, 'STILLNOTE_METRICS':'1', 'HF_HUB_OFFLINE':'1', 'HF_HUB_DISABLE_TELEMETRY':'1'})
        try:
            stdout, stderr=proc.communicate()
        except BaseException:
            os.killpg(proc.pid, signal.SIGTERM)
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            raise
        events=[json.loads(s[len('STILLNOTE_EVENT '):]) for s in stdout.splitlines() if s.startswith('STILLNOTE_EVENT ')]
        rss=next((int(s.split()[0]) for s in stderr.splitlines() if 'maximum resident set size' in s), None)
        entry=dict(run=run, mode=mode, pcm_sha256=pcm_hash, worker_sha256=worker_hash,
            machine=platform.machine(), macos=platform.mac_ver()[0], seconds=time.monotonic()-started, peak_rss_bytes=rss,
            exit_code=proc.returncode, events=[e for e in events if e['type'] != 'progress'])
        entry['usable_transcript'] = proc.returncode == 0 and any(e.get('type') == 'result' and e.get('text', '').strip() for e in events)
        results.append(entry)
        pathlib.Path(a.output).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(a.output).write_text(json.dumps(results, indent=2, ensure_ascii=False))
        print(mode, run+1, round(entry['seconds'],2), 'seconds', rss, 'bytes RSS', 'exit', proc.returncode, flush=True)
for mode in a.modes:
    rows=[r for r in results if r['mode']==mode and r['usable_transcript']]
    if rows: print(mode, 'median seconds:', statistics.median(r['seconds'] for r in rows))
