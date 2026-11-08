import urllib.request
import json

key = '1j59BjlpvcB0QdaiN3LrsZu3SVVNOexDPBNwxSs9MB51HjBhzhZGAtTLZ3yXUs6QM'
boundary = 'BoundaryCAFTest'

parts = []
parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\nstepaudio-2.5-asr\r\n'.encode('utf-8'))
parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.caf"\r\nContent-Type: audio/x-caf\r\n\r\n'.encode('utf-8'))
parts.append(b'dummy caf data')
parts.append(f'\r\n--{boundary}--\r\n'.encode('utf-8'))

req = urllib.request.Request(
    'https://api.stepfun.com/v1/audio/transcriptions',
    data=b''.join(parts),
    headers={'Authorization': f'Bearer {key}', 'Content-Type': f'multipart/form-data; boundary={boundary}'}
)
try:
    with urllib.request.urlopen(req) as resp:
        print(resp.read())
except urllib.error.HTTPError as e:
    print('HTTP Error with CAF:', e.code, e.read().decode())
