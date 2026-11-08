import shutil
import os
import subprocess

repo_dir = r"D:\antigrity\建大课堂录音-iOS"

# 1. Copy tools/package-ios-app.py
os.makedirs(os.path.join(repo_dir, "tools"), exist_ok=True)
shutil.copy2(r"d:\antigrity\竞赛罗盘\tools\package-ios-app.py", os.path.join(repo_dir, "tools", "package-ios-app.py"))

# 2. Update workflow to trigger on main
wf_path = os.path.join(repo_dir, ".github", "workflows", "build-ios.yml")
with open(wf_path, "r", encoding="utf-8") as f:
    text = f.read()

old_branch = "- 'codex/ios-build-*'"
new_branch = "- 'main'\n      - 'codex/ios-build-*'"
text = text.replace(old_branch, new_branch)

with open(wf_path, "w", encoding="utf-8", newline="\n") as f:
    f.write(text)

# 3. Commit and push
subprocess.run(["git", "add", "-A"], cwd=repo_dir, check=True)
subprocess.run(["git", "commit", "-m", "ci: include tools/package-ios-app.py and add main branch trigger"], cwd=repo_dir, check=True)
res = subprocess.run(["git", "push", "origin", "main"], cwd=repo_dir, capture_output=True, text=True)
print("Push stdout:", res.stdout)
print("Push stderr:", res.stderr)
