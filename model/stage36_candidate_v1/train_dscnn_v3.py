"""Train DS-CNN v3 from the v3 cleaned-card manifest.

v3 changes only the data policy: it excludes near-zero cards from non-silence
classes and keeps ESC-50 source IDs in one split. It keeps the v2 model shape.
Run prepare_v3_manifest.py first, then: python train_dscnn_v3.py
"""
import csv
import json
import argparse
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import pandas as pd
import soundfile as sf
import torch
import torch.nn as nn
from scipy.signal import resample_poly
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix

import features as F


ROOT = Path(__file__).resolve().parent
SR = 16000
EPOCHS, BATCH, LR = 30, 32, 0.001
USE_AUG = True
CLASSES = [
    'silence', 'unknown', 'knock', 'alarm_clock',
    'alarm_alert', 'baby_cry', 'glass_break', 'kettle',
]


class DSCNN(nn.Module):
    def __init__(self, n_classes=8, width=28):
        super().__init__()

        def dw_pw(cin, cout):
            return nn.Sequential(
                nn.Conv2d(cin, cin, 3, padding=1, groups=cin),
                nn.BatchNorm2d(cin), nn.ReLU(),
                nn.Conv2d(cin, cout, 1),
                nn.BatchNorm2d(cout), nn.ReLU(),
            )

        self.net = nn.Sequential(
            nn.Conv2d(1, width, 3, padding=1), nn.BatchNorm2d(width), nn.ReLU(),
            dw_pw(width, width * 2), nn.MaxPool2d(2),
            dw_pw(width * 2, width * 2),
            dw_pw(width * 2, width * 4), nn.MaxPool2d(2),
            dw_pw(width * 4, width * 4),
            nn.AdaptiveAvgPool2d(1),
        )
        self.head = nn.Linear(width * 4, n_classes)

    def forward(self, x):
        return self.head(self.net(x.unsqueeze(1)).squeeze(-1).squeeze(-1))


def build_noise_bank():
    meta = pd.read_csv(ROOT / 'ESC-50-master' / 'meta' / 'esc50.csv')
    paths = meta[meta.category.isin(['rain', 'wind'])].filename.tolist()
    bank = []
    for name in paths:
        data, rate = sf.read(ROOT / 'ESC-50-master' / 'audio' / name)
        if data.ndim == 2:
            data = data[:, 0]
        if rate != SR:
            data = resample_poly(data, SR, rate)
        bank.append(data)
    return bank


def augment(data, rng, noise_bank):
    data = data * rng.uniform(0.3, 1.0)
    data = np.roll(data, rng.integers(-1600, 1600))
    source = noise_bank[rng.integers(len(noise_bank))]
    start = rng.integers(0, max(1, len(source) - len(data)))
    noise = source[start:start + len(data)]
    if len(noise) < len(data):
        noise = np.pad(noise, (0, len(data) - len(noise)))
    snr = rng.uniform(5, 15)
    signal_power = np.mean(data ** 2) + 1e-10
    noise_power = signal_power / (10 ** (snr / 10))
    return data + noise * np.sqrt(noise_power / (np.mean(noise ** 2) + 1e-10))


def load_cards(rows, augment_train, rng, noise_bank):
    by_file = defaultdict(list)
    for row in rows:
        by_file[row['path']].append(row)
    cards, labels, metadata = [], [], []
    for path, file_rows in by_file.items():
        data = F.load_wav_16k(ROOT / path)
        peak = np.max(np.abs(data))
        if peak > 0:
            data = data / peak
        if augment_train:
            data = augment(data, rng, noise_bank)
        for row in file_rows:
            start = int(row['start_sample']) if 'start_sample' in row else int(row['second']) * SR
            segment = data[start:start + SR]
            if len(segment) != SR:
                raise ValueError(f'Incomplete card in manifest: {path} start {start}')
            cards.append(F.compute_features(segment)[-1])
            labels.append(int(row['class_id']))
            metadata.append(row)
    return torch.tensor(np.asarray(cards), dtype=torch.float32), torch.tensor(labels), metadata


def write_confusion(path, truth, pred):
    matrix = confusion_matrix(truth, pred, labels=range(len(CLASSES)))
    with path.open('w', newline='', encoding='utf-8-sig') as stream:
        writer = csv.DictWriter(stream, fieldnames=['true_class'] + CLASSES)
        writer.writeheader()
        for i, row in enumerate(matrix):
            writer.writerow({'true_class': CLASSES[i], **dict(zip(CLASSES, map(int, row)))})


class UnknownCategorySampler(torch.utils.data.Sampler):
    """Balance unknown subcategories using training metadata only.

    Every non-unknown card is visited once per epoch.  The total number of
    unknown cards per epoch is unchanged; unknown draws use replacement.
    """
    def __init__(self, metadata):
        table = pd.read_csv(ROOT / 'ESC-50-master/meta/esc50.csv')
        categories = dict(zip(table.filename, table.category))
        self.unknown = [i for i, row in enumerate(metadata) if row['class_name'] == 'unknown']
        self.other = [i for i, row in enumerate(metadata) if row['class_name'] != 'unknown']
        names = [categories[Path(metadata[i]['path']).name] for i in self.unknown]
        counts = Counter(names)
        self.weights = torch.tensor([1.0 / counts[name] for name in names], dtype=torch.double)
        self.generator = torch.Generator().manual_seed(0)
        self.size = len(metadata)
        expected = len(self.unknown) / len(counts)
        for name, count in sorted(counts.items()):
            print(f'Unknown sampler {name}: original={count}, expected/epoch={expected:.1f}', flush=True)

    def __len__(self):
        return self.size

    def __iter__(self):
        draws = torch.multinomial(self.weights, len(self.unknown), replacement=True,
                                 generator=self.generator)
        indices = self.other + [self.unknown[i] for i in draws.tolist()]
        order = torch.randperm(len(indices), generator=self.generator).tolist()
        return iter([indices[i] for i in order])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=ROOT / 'v3_manifest' / 'cards.csv')
    parser.add_argument('--output', type=Path, default=ROOT / 'results_v3')
    parser.add_argument('--checkpoint', type=Path, default=ROOT / 'dscnn_v3_cleaned.pth')
    parser.add_argument('--label', default='v3 label-cleanup result')
    parser.add_argument('--split-note', default='The split groups ESC-50 samples by original source ID, so this score is not directly comparable to v2.')
    parser.add_argument('--balance-unknown-categories', action='store_true')
    parser.add_argument('--report-name', default='report.md')
    args = parser.parse_args()
    if not args.manifest.exists():
        raise FileNotFoundError(f'Manifest not found: {args.manifest}')
    torch.manual_seed(0)
    np.random.seed(0)
    torch.set_num_threads(4)
    rng = np.random.default_rng(0)
    rows = list(csv.DictReader(args.manifest.open(encoding='utf-8-sig')))
    train_rows = [r for r in rows if r['split'] == 'train']
    test_rows = [r for r in rows if r['split'] == 'test']
    print(f'Cards: train={len(train_rows)}, test={len(test_rows)}')
    noise_bank = build_noise_bank() if USE_AUG else []
    x_train, y_train, train_meta = load_cards(train_rows, USE_AUG, rng, noise_bank)
    x_test, y_test, test_meta = load_cards(test_rows, False, rng, noise_bank)
    print(f'Loaded tensors: train={len(y_train)}, test={len(y_test)}')

    model = DSCNN(n_classes=len(CLASSES))
    counts = np.bincount(y_train.numpy(), minlength=len(CLASSES))
    weights = counts.sum() / (len(counts) * counts + 1e-9)
    loss_fn = nn.CrossEntropyLoss(weight=torch.tensor(weights, dtype=torch.float32))
    optimizer = torch.optim.Adam(model.parameters(), lr=LR)
    sampler = UnknownCategorySampler(train_meta) if args.balance_unknown_categories else None
    loader = torch.utils.data.DataLoader(torch.utils.data.TensorDataset(x_train, y_train),
                                        batch_size=BATCH, shuffle=sampler is None, sampler=sampler)
    history = []
    for epoch in range(EPOCHS):
        model.train()
        for xb, yb in loader:
            loss = loss_fn(model(xb), yb)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
        if epoch == 0 or (epoch + 1) % 5 == 0:
            model.eval()
            with torch.inference_mode():
                accuracy = (model(x_test).argmax(1) == y_test).float().mean().item()
            history.append({'epoch': epoch + 1, 'last_batch_loss': float(loss.item()), 'test_accuracy': accuracy})
            print(f'epoch {epoch + 1:2d}: loss={loss.item():.4f}, card_accuracy={accuracy:.2%}')

    model.eval()
    with torch.inference_mode():
        probabilities = model(x_test).softmax(1).numpy()
    pred = probabilities.argmax(1)
    truth = y_test.numpy()
    args.output.mkdir(exist_ok=True)
    torch.save(model.state_dict(), args.checkpoint)
    write_confusion(args.output / 'confusion_cards.csv', truth, pred)
    rows_out = []
    for row, probs, predicted in zip(test_meta, probabilities, pred):
        output = dict(row)
        output.update(pred_id=int(predicted), pred_class=CLASSES[int(predicted)],
                      confidence=float(probs[predicted]), correct=int(predicted == int(row['class_id'])))
        output.update({f'p_{name}': float(probs[i]) for i, name in enumerate(CLASSES)})
        rows_out.append(output)
    fields = list(rows_out[0])
    for filename, subset in [('predictions.csv', rows_out), ('errors.csv', [r for r in rows_out if not r['correct']])]:
        with (args.output / filename).open('w', newline='', encoding='utf-8-sig') as stream:
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            writer.writerows(subset)
    accuracy = accuracy_score(truth, pred)
    report = classification_report(truth, pred, labels=range(len(CLASSES)), target_names=CLASSES, zero_division=0)
    (args.output / args.report_name).write_text(
        f'# DS-CNN {args.label}\n\n'
        'V3 excludes only non-silence cards with raw RMS below 0.0001. '\
        f'{args.split_note}\n\n'
        f'Card accuracy: {accuracy:.4%} ({len(truth)} cards)\n\n```text\n{report}\n```\n', encoding='utf-8')
    (args.output / 'training_history.json').write_text(json.dumps(history, indent=2), encoding='utf-8')
    print(f'Final card accuracy: {accuracy:.2%}')
    print(report)
    print(f'Checkpoint: {args.checkpoint.name}; results: {args.output}')


if __name__ == '__main__':
    main()
