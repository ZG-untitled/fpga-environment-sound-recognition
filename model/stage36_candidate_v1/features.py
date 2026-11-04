"""
黄金特征程序（全队标准答案）
任何人想验证 PL/HLS 的特征对不对，都用这个模块算基准。
口径（全队合同，不许改）：16kHz / 帧长512 / 帧移320 / FFT512 / Mel40 / Log
"""
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

SR, N_FFT, HOP, N_MEL = 16000, 512, 320, 40
FB = None   # Mel 滤波器组缓存

def hz_to_mel(f):  return 2595 * np.log10(1 + f / 700)
def mel_to_hz(m):  return 700 * (10 ** (m / 2595) - 1)

def get_fb():
    global FB
    if FB is None:
        mel_pts = np.linspace(hz_to_mel(40), hz_to_mel(8000), N_MEL + 2)
        hz_pts  = mel_to_hz(mel_pts)
        bins    = np.floor(N_FFT * hz_pts / SR).astype(int)
        fb = np.zeros((N_MEL, N_FFT // 2 + 1))
        for i in range(N_MEL):
            l, c, r = bins[i], bins[i+1], bins[i+2]
            for k in range(l, c):
                if c > l: fb[i, k] = (k - l) / (c - l)
            for k in range(c, r):
                if r > c: fb[i, k] = (r - k) / (r - c)
        FB = fb
    return FB

def load_wav_16k(path):
    """读任意 wav -> 16kHz 单声道，返回 float 数组"""
    data, sr = sf.read(path)
    if data.ndim == 2:
        data = data[:, 0]
    if sr != SR:
        data = resample_poly(data, SR, sr)
    return data

def frame_signal(data):
    """分帧 + 加窗，返回 (帧数, 512) 的矩阵"""
    n_frames = 1 + (len(data) - N_FFT) // HOP
    hamming = np.hamming(N_FFT)
    frames = np.zeros((n_frames, N_FFT))
    for i in range(n_frames):
        frames[i] = data[i*HOP : i*HOP+N_FFT] * hamming
    return frames

def compute_features(data):
    """完整流水线：输入 16kHz 数组，输出每一步中间结果（供逐级比对）"""
    frames = frame_signal(data)                    # 步骤1：分帧加窗
    spectrum = np.fft.rfft(frames, axis=1)         # 步骤2：FFT
    power = np.abs(spectrum) ** 2                  # 步骤3：功率谱
    fb = get_fb()
    mel = power @ fb.T                             # 步骤4：Mel 滤波
    logmel = np.log(mel + 1e-8)                    # 步骤5：Log
    return frames, spectrum, power, mel, logmel

def extract_card_1s(path):
    """一个 wav -> 若干张 49x40 特征卡片（训练/推理用）"""
    data = load_wav_16k(path)
    cards = []
    for s in range(len(data) // SR):
        seg = data[s*SR : (s+1)*SR]
        frames, _, _, _, logmel = compute_features(seg)
        cards.append(logmel)
    return cards