import subprocess
import urllib.request
import json
import zipfile
import io
import time
import os
import sys

def main():
    print("=== 开始构建并下载最新 IPA 交付包 (v1.4.0) ===")
    
    # 1. Get token from git credential manager
    p = subprocess.Popen(['git', 'credential', 'fill'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, _ = p.communicate(input='protocol=https\nhost=github.com\n\n')
    token = None
    for line in out.strip().splitlines():
        if line.startswith('password='):
            token = line.split('=', 1)[1]
            break

    if not token:
        print('Error: Failed to retrieve GitHub token.')
        sys.exit(1)

    headers = {'Authorization': f'Bearer {token}', 'User-Agent': 'ArtifactDownloader'}

    # 2. Monitor latest workflow run on codex/ios-build-20261107
    runs_url = 'https://api.github.com/repos/lzsobig/xauat-compass/actions/runs?branch=codex/ios-build-20261107&per_page=1'
    req = urllib.request.Request(runs_url, headers=headers)
    with urllib.request.urlopen(req) as r:
        data = json.loads(r.read().decode())
        latest_run = data['workflow_runs'][0]
        run_id = latest_run['id']
        status = latest_run['status']
        conclusion = latest_run['conclusion']
        print(f'Latest Run ID: {run_id}, Status: {status}, Conclusion: {conclusion}')

    # Wait for run to finish if currently running or queued
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
        print(f'Error: GitHub Actions build was not successful (conclusion: {conclusion})!')
        sys.exit(1)

    # 3. Get artifacts
    art_url = f'https://api.github.com/repos/lzsobig/xauat-compass/actions/runs/{run_id}/artifacts'
    req = urllib.request.Request(art_url, headers=headers)
    with urllib.request.urlopen(req) as r:
        data = json.loads(r.read().decode())
        if not data.get('artifacts'):
            print('Error: No artifacts found in workflow run.')
            sys.exit(1)
        art = data['artifacts'][0]
        art_id = art['id']
        print(f"Found artifact: {art['name']}, ID: {art_id}, Size: {art['size_in_bytes']} bytes")

    # Handle Azure Blob 401 redirect
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
        print(f'Downloaded {len(zip_bytes)} bytes.')

    target_ios_dir = r'D:\IOS'
    os.makedirs(target_ios_dir, exist_ok=True)

    dest_files = [
        os.path.join(target_ios_dir, '建大课堂录音.ipa'),
        os.path.join(target_ios_dir, '建大课堂录音-v1.4.0-课表草稿预览与分层安全管理版.ipa')
    ]

    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
        for name in z.namelist():
            if name.endswith('.ipa'):
                ipa_data = z.read(name)
                for dest in dest_files:
                    with open(dest, 'wb') as f:
                        f.write(ipa_data)
                    print(f'Successfully delivered -> {dest} ({len(ipa_data)} bytes)')

    print("\n[SUCCESS] 全部 IPA 交付文件已直接存放至用户的目标目录 D:\\IOS\\ !")

if __name__ == '__main__':
    main()
