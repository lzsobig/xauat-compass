import urllib.request
import json
import struct

sample_rate = 16000
samples = [0] * sample_rate # 1 second of silence
data_size = len(samples) * 2
chunk_size = 36 + data_size

header = struct.pack(
    '<4sI4s4sIHHIIHH4sI',
    b'RIFF',
    chunk_size,
    b'WAVE',
    b'fmt ',
    16,
    1, # PCM
    1, # Mono
    sample_rate,
    sample_rate * 2,
    2, # block align
    16, # bits per sample
    b'data',
    data_size
)

raw_samples = struct.pack(f'<{len(samples)}h', *samples)
wav_data = header + raw_samples

key = '1j59BjlpvcB0QdaiN3LrsZu3SVVNOexDPBNwxSs9MB51HjBhzhZGAtTLZ3yXUs6QM'
boundary = 'BoundaryWAVHeaderTest'

parts = []
parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\nstepaudio-2.5-asr\r\n'.encode('utf-8'))
parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode('utf-8'))
parts.append(wav_data)
parts.append(f'\r\n--{boundary}--\r\n'.encode('utf-8'))

req = urllib.request.Request(
    'https://api.stepfun.com/v1/audio/transcriptions',
    data=b''.join(parts),
    headers={'Authorization': f'Bearer {key}', 'Content-Type': f'multipart/form-data; boundary={boundary}'}
)
try:
    with urllib.request.urlopen(req) as resp:
        print('Success:', resp.read())
except urllib.error.HTTPError as e:
    print('HTTP Response:', e.code, e.read().decode())
