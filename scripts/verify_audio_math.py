import struct

def test_downsample_and_wav():
    # simulate 44100Hz audio downsampled to 16000Hz
    src_rate = 44100.0
    dst_rate = 16000.0
    step = src_rate / dst_rate
    
    # generate 1 second of 44100 samples
    samples_in = [0.1 * ((i % 100) - 50) / 50.0 for i in range(44100)]
    
    out_samples = []
    idx = 0.0
    while idx < len(samples_in):
        s_idx = int(idx)
        clamped = max(-1.0, min(1.0, samples_in[s_idx]))
        out_samples.append(int(clamped * 32767.0))
        idx += step
        
    print(f'Input frames: {len(samples_in)}, Output 16kHz frames: {len(out_samples)}')
    assert 15990 <= len(out_samples) <= 16010, 'Expected approx 16000 samples'
    print('Downsampling verification passed!')

test_downsample_and_wav()
