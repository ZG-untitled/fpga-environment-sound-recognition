"""Fixed eight-epoch v3c adaptation to fixed-scale PCM, not a final delivery.

No recording/window peak normalization or DC removal. Only the accepted board
background ch0 enters training. Knock PCM and both PL snapshots are diagnostic
regressions, not independent test data. Existing development split is reused;
its scores must not be called independent generalization performance.
"""
import csv
import io
import json
from pathlib import Path
import zipfile

import numpy as np
import torch
from sklearn.metrics import confusion_matrix

import features as F
from train_dscnn_v3 import ROOT, CLASSES, DSCNN

OUT = ROOT / 'results_live_v1'
TARGET = ROOT / 'dscnn_live_v1.pth'


def load_fixed(rows):
    cache = {}
    features = []
    for row in rows:
        path = row['path']
        if path not in cache:
            cache[path] = F.load_wav_16k(ROOT / path)
        # soundfile int16 float conversion uses /32768. Match the board contract
        # /32767 for these dataset_16k PCM16 files; fail on other encodings.
        import soundfile as sf
        if sf.info(ROOT / path).subtype != 'PCM_16':
            raise ValueError(f'Expected PCM16: {path}')
        start = int(row.get('start_sample', int(row.get('second', 0))*F.SR))
        x = cache[path][start:start+F.SR] * (32768.0/32767.0)
        if len(x) != F.SR:
            raise ValueError(f'Incomplete window {path}')
        features.append(F.compute_features(x)[-1])
    return torch.tensor(np.asarray(features), dtype=torch.float32)


def board_data():
    train_bg, regressions = [], []
    with zipfile.ZipFile(ROOT.parent / 'teammate/stage24_model_handoff.zip') as z:
        for name in z.namelist():
            if not name.endswith('_metadata.json'):
                continue
            meta = json.loads(z.read(name).decode('utf-8-sig'))
            if meta.get('quality_status', '').startswith('rejected'):
                continue
            rows = list(csv.DictReader(io.StringIO(z.read(name.replace('_metadata.json', '_four_channel_pcm.csv')).decode('utf-8-sig'))))
            pcm = np.asarray([int(r['ch0']) for r in rows], dtype=float)[:16000]/32767
            feature = F.compute_features(pcm)[-1]
            label = 0 if 'background' in meta['label'] else 2
            regressions.append((meta['label'], feature, label))
            if label == 0:
                train_bg.append(feature)
        for name in z.namelist():
            if not name.endswith('_feature_snapshot.csv'):
                continue
            rows = list(csv.DictReader(io.StringIO(z.read(name).decode('utf-8-sig'))))
            feature = np.array([int(r['log2_q8_8']) for r in rows]).reshape(49,40)/256*np.log(2)-2*np.log(32767)
            regressions.append((Path(name).name, feature, 0 if 'background' in name else 2))
    return torch.tensor(np.asarray(train_bg), dtype=torch.float32), regressions


def assess(model, x, y, regression, fitted_samples=None):
    if fitted_samples is None:
        fitted_samples=['room_background_01']
    model.eval()
    with torch.inference_mode():
        pred = torch.cat([model(batch).argmax(1) for batch in x.split(32)]).numpy()
        p = model(torch.tensor(np.asarray([r[1] for r in regression]), dtype=torch.float32)).softmax(1).numpy()
    matrix = confusion_matrix(y, pred, labels=range(8))
    result = dict(accuracy=float((pred==y).mean()), confusion=matrix.tolist(),
                  recall={name: float(matrix[i,i]/matrix[i].sum()) if matrix[i].sum() else None for i,name in enumerate(CLASSES)},
                  board_regressions=[dict(sample=r[0], expected_id=r[2], predicted=CLASSES[int(prob.argmax())],
                                          confidence=float(prob.max()), used_in_training=(r[0] in fitted_samples)) for r,prob in zip(regression,p)])
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return result


def main():
    if TARGET.exists() or OUT.exists():
        raise FileExistsError('Keep existing experiment; choose a new version explicitly.')
    torch.set_num_threads(4)
    torch.manual_seed(42)
    with (ROOT / 'v3c_manifest/cards.csv').open(encoding='utf-8-sig') as f:
        rows = list(csv.DictReader(f))
    train = [r for r in rows if r['split']=='train']
    test = [r for r in rows if r['split']=='test']
    print(f'Loading fixed-scale PCM features: train={len(train)}, dev={len(test)}', flush=True)
    x = load_fixed(train)
    test_x = load_fixed(test)
    y = torch.tensor([int(r['class_id']) for r in train])
    truth = np.asarray([int(r['class_id']) for r in test])
    bg, regression = board_data()
    # Repetitions weight one background acquisition; they are not new examples.
    x = torch.cat([x, bg.repeat(32,1,1)])
    y = torch.cat([y, torch.zeros(32*len(bg), dtype=torch.long)])
    model = DSCNN()
    model.load_state_dict(torch.load(ROOT / 'dscnn_v3c_reviewed_baby.pth', weights_only=True, map_location='cpu'))
    print('Baseline on fixed-scale development input:', flush=True)
    baseline = assess(model, test_x, truth, regression)
    counts = torch.bincount(y, minlength=8).float()
    loss_fn = torch.nn.CrossEntropyLoss(weight=len(y)/(8*counts))
    optimizer = torch.optim.Adam(model.parameters(), lr=0.0002)
    history = []
    # Gain augmentation exactly updates floating Mel energy (including log epsilon).
    # This is training augmentation only; deployment has no AGC or peak statistic.
    mel = torch.clamp(torch.exp(x.double())-1e-8, min=0)
    for epoch in range(8):
        model.train()
        total = 0.0
        for ids in torch.randperm(len(y)).split(32):
            gains = torch.pow(10., torch.empty(len(ids),1,1).uniform_(-1.5, 0.3)).double()
            inputs = torch.log(mel[ids]*gains.square()+1e-8).float()
            optimizer.zero_grad()
            loss = loss_fn(model(inputs), y[ids])
            loss.backward()
            optimizer.step()
            total += float(loss.detach())*len(ids)
        history.append(dict(epoch=epoch+1, training_loss=total/len(y)))
        print(f'Epoch {epoch+1}/8 training loss={total/len(y):.4f}', flush=True)
    model.eval()
    OUT.mkdir()
    torch.save(model.state_dict(), TARGET)
    print('Candidate FP32 on same fixed-scale development input:', flush=True)
    candidate = assess(model, test_x, truth, regression)
    result = dict(input_policy='PCM16 / 32767; no peak normalization, no DC removal; Python ln(mel + 1e-8)',
                  augmentation='per-training-card random gain 10**uniform(-1.5,0.3); no deployment gain',
                  epochs=8, seed=42, history=history, baseline=baseline, candidate=candidate,
                  note='FP32 experiment only, not INT8 or board validated. Reused development split, not independent. One board background acquisition used for training; PCM and PL snapshots unpaired. PL zero-floor equivalence unresolved.')
    (OUT/'comparison.json').write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')


if __name__ == '__main__':
    main()
