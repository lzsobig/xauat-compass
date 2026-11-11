import os
import subprocess
from pathlib import Path

root = Path.cwd()
out = root / 'audit/result'
out.mkdir()
src = root / 'ios/ClassroomApp'
old = subprocess.check_output(['git','show','a3daa145:ios/ClassroomApp/ClassroomManager.swift'], text=True)
new = (src/'ClassroomManager.swift').read_text()
def capture(text, name):
    body = text.split('private final class AudioCapture {', 1)[1].split('\n// MARK:', 1)[0]
    return 'final class ' + name + ' {' + body

(out.parent/'Capture.swift').write_text('import AVFoundation\nimport Foundation\n'+capture(old,'OldCapture')+'\n'+capture(new,'NewCapture'))
subprocess.run(['python3','tools/prepare-vad-runtime.py','--platform','macos'], check=True)
runtime = root/'output/vad-runtime/sherpa-onnx-1.12.20-macos'
header = next(runtime.rglob('c-api.h'))
library = next(runtime.rglob('libsherpa-onnx-c-api.dylib'))
sources = [src/f for f in ('ClassroomSliceBuffer.swift','SileroVoiceDetector.swift','PCMUtilities.swift')]
subprocess.run(['swiftc','-D','CLASSROOM_SHERPA','-import-objc-header',str(header),*map(str,sources),
    'audit/Capture.swift','audit/Replay.swift','-L',str(library.parent),'-lsherpa-onnx-c-api','-Xlinker','-rpath','-Xlinker',str(library.parent),'-o','audit/replay'], check=True)
model = src/'VADAssets/silero_vad.int8.onnx'
Path('audit/silero_vad.int8.onnx').write_bytes(model.read_bytes())
env = dict(os.environ, DYLD_LIBRARY_PATH=str(library.parent))
subprocess.run(['audit/replay','audit/lecture.wav','audit/result'],check=True,env=env)
