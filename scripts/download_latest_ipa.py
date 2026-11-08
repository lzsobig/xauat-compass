import subprocess
import urllib.request
import json
import zipfile
import io
import time
import os

# 1. Get token from git credential manager
p = subprocess.Popen(['git', 'credential', 'fill'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
out, _ = p.communicate(input='protocol=https\nhost=github.com\n\n')
token = None
for line in out.strip().splitlines():
    if line.startswith('password='):
        token = line.split('=', 1)[1]
        break

if not token:
    print('Failed to get GitHub token.')
    exit(1)

headers = {'Authorization': f'Bearer {token}', 'User-Agent': 'ArtifactDownloader'}

# 2. Get latest workflow run on codex/ios-build-20261107
runs_url = 'https://api.github.com/repos/lzsobig/xauat-compass/actions/runs?branch=codex/ios-build-20261107&per_page=1'
req = urllib.request.Request(runs_url, headers=headers)
with urllib.request.urlopen(req) as r:
    data = json.loads(r.read().decode())
    latest_run = data['workflow_runs'][0]
    run_id = latest_run['id']
    status = latest_run['status']
    conclusion = latest_run['conclusion']
    print(f'Latest Run ID: {run_id}, Status: {status}, Conclusion: {conclusion}')

# Wait for run to finish if in progress
while status in ['queued', 'in_progress', 'waiting']:
    print(f'Run {run_id} is {status}... waiting 15s')
    time.sleep(15)
    req = urllib.request.Request(f'https://api.github.com/repos/lzsobig/xauat-compass/actions/runs/{run_id}', headers=headers)
    with urllib.request.urlopen(req) as r:
        run_data = json.loads(r.read().decode())
        status = run_data['status']
        conclusion = run_data['conclusion']

print(f'Run finished: Status: {status}, Conclusion: {conclusion}')
if conclusion != 'success':
    print('Build was not successful!')
    exit(1)

# 3. Get artifacts
art_url = f'https://api.github.com/repos/lzsobig/xauat-compass/actions/runs/{run_id}/artifacts'
req = urllib.request.Request(art_url, headers=headers)
with urllib.request.urlopen(req) as r:
    data = json.loads(r.read().decode())
    art = data['artifacts'][0]
    art_id = art['id']
    print(f"Found artifact: {art['name']}, ID: {art_id}, Size: {art['size_in_bytes']}")

class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req and 'blob.core.windows.net' in newurl:
            new_req.headers.pop('Authorization', None)
            new_req.headers.pop('authorization', None)
        return new_req

opener = urllib.request.build_opener(NoAuthRedirect)
dl_url = f'https://api.github.com/repos/lzsobig/xauat-compass/actions/artifacts/{art_id}/zip'
dl_req = urllib.request.Request(dl_url, headers=headers)

print('Downloading artifact zip...')
with opener.open(dl_req) as dl_resp:
    zip_bytes = dl_resp.read()
    print('Downloaded', len(zip_bytes), 'bytes.')

with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
    for name in z.namelist():
        if name.endswith('.ipa'):
            ipa_data = z.read(name)
            p1 = r'd:\antigrity\竞赛罗盘\ClassroomApp.ipa'
            with open(p1, 'wb') as f:
                f.write(ipa_data)
            print('Saved to:', p1, f'({len(ipa_data)} bytes)')
            
            p2 = r'D:\antigrity\ClassroomApp.ipa'
            with open(p2, 'wb') as f:
                f.write(ipa_data)
            print('Saved to:', p2, f'({len(ipa_data)} bytes)')

            p3 = r'D:\IOS\建大课堂录音-v1.3.2-TXT导出与全选复制版.ipa'
            with open(p3, 'wb') as f:
                f.write(ipa_data)
            print('Saved to:', p3, f'({len(ipa_data)} bytes)')

            p4 = r'D:\IOS\建大课堂录音.ipa'
            with open(p4, 'wb') as f:
                f.write(ipa_data)
            print('Saved to:', p4, f'({len(ipa_data)} bytes)')
print('Done!')
