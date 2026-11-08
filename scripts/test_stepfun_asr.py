import urllib.request
import json
import wave
import io

buf = io.BytesIO()
with wave.open(buf, 'wb') as wf:
    wf.setnchannels(1)
    wf.setsampwidth(2)
    wf.setframerate(16000)
    wf.writeframes(b'\x00\x00' * 16000)
wav_data = buf.getvalue()

import os

key = os.environ.get('STEPFUN_API_KEY', '')
boundary = 'Boundary1234567890'

parts = []
parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\nstepaudio-2.5-asr\r\n'.encode('utf-8'))
parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode('utf-8'))
parts.append(wav_data)
parts.append(f'\r\n--{boundary}--\r\n'.encode('utf-8'))

body = b''.join(parts)

req = urllib.request.Request(
    'https://api.stepfun.com/v1/audio/transcriptions',
    data=body,
    headers={
        'Authorization': f'Bearer {key}',
        'Content-Type': f'multipart/form-data; boundary={boundary}',
        'User-Agent': 'ClassroomApp/1.2'
    }
)
try:
    with urllib.request.urlopen(req) as resp:
        res = json.loads(resp.read().decode())
        print('StepFun ASR success! Response:', res)
except urllib.error.HTTPError as e:
    print('HTTP Error:', e.code, e.read().decode())
except Exception as e:
    print('Other error:', e)
