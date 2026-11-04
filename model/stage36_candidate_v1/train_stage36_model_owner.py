"""Fine-tune the Stage36 live_v1 model using its synchronized field captures.

The exact live_v1 checkpoint is selected by the checksum in Stage36's INT8
model.json. Paired PCM and PL views share one recording ID; glass is trained
as unknown and output 6 remains reserved and masked.
"""
import csv
import hashlib
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as TF

import features as F
from adapt_live_input import ROOT, load_fixed
from train_dscnn_v3 import CLASSES, DSCNN


STAGE = ROOT.parent / "teammate/stage36_model_owner_handoff_20261101"
FIELD_ROOT = STAGE / "04_field_synchronized"
BASELINE_PACKAGE = STAGE / "02_current_baremetal_int8"
SOURCE_CHECKPOINT = ROOT / "dscnn_live_v1.pth"
TARGET_CHECKPOINT = ROOT / "dscnn_stage36_model_owner_v1.pth"
RESULTS = ROOT / "results_stage36_model_owner_v1"
OUTPUTS = [0, 1, 2, 3, 4, 5, 7]
PL_SCALE = 0.002755681736090
PL_OFFSET = -21.011273721790065


def folder_label(name):
    if "glass_break" in name:
        return 1
    for key, class_id in (
        ("alarm_alert", 4), ("alarm_clock", 3), ("baby_cry", 5),
        ("kettle", 7), ("knock", 2), ("silence", 0),
        ("background", 0), ("unknown", 1),
    ):
        if key in name:
            return class_id
    raise ValueError(f"No approved class mapping for Stage36 sample: {name}")


def read_csv_rows(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def load_field_pairs():
    pairs = []
    for folder in sorted(path for path in FIELD_ROOT.iterdir() if path.is_dir()):
        pcm_files = list(folder.glob("*_ch0_pcm.csv"))
        pl_files = list(folder.glob("*_pl_matrix.csv"))
        if len(pcm_files) != 1 or len(pl_files) != 1:
            raise ValueError(f"Expected exactly one paired PCM and PL file: {folder}")

        manifest_path = folder / "analysis/capture_manifest.json"
        metadata = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
        pcm_rows = read_csv_rows(pcm_files[0])
        indices = np.asarray([int(row["sample_index"]) for row in pcm_rows])
        pcm_i16 = np.asarray([int(row["pcm_i16"]) for row in pcm_rows], dtype=np.int16)
        if len(pcm_i16) != 15872 or not np.array_equal(indices, np.arange(len(indices))):
            raise ValueError(f"Invalid PCM length or index sequence: {folder.name}")
        if hashlib.sha256(pcm_files[0].read_bytes()).hexdigest() != metadata["pcm_sha256"]:
            raise ValueError(f"PCM checksum mismatch: {folder.name}")

        matrix_rows = read_csv_rows(pl_files[0])
        matrix_rows.sort(key=lambda row: int(row["address"]))
        addresses = np.asarray([int(row["address"]) for row in matrix_rows])
        q8_8 = np.asarray([int(row["log2_q8_8"]) for row in matrix_rows], dtype=np.float64)
        if len(q8_8) != 1960 or not np.array_equal(addresses, np.arange(1960)):
            raise ValueError(f"Invalid PL matrix order or size: {folder.name}")
        if hashlib.sha256(pl_files[0].read_bytes()).hexdigest() != metadata["matrix_sha256"]:
            raise ValueError(f"PL matrix checksum mismatch: {folder.name}")

        pcm_feature = F.compute_features(pcm_i16.astype(np.float64) / 32767.0)[-1]
        pl_feature = (q8_8.reshape(49, 40) * PL_SCALE + PL_OFFSET)
        pairs.append({
            "recording_id": folder.name,
            "label": folder_label(folder.name),
            "pcm": torch.tensor(pcm_feature, dtype=torch.float32),
            "pl": torch.tensor(pl_feature, dtype=torch.float32),
            "pcm_sha256": metadata["pcm_sha256"],
            "matrix_sha256": metadata["matrix_sha256"],
        })
    if len(pairs) != 22:
        raise ValueError(f"Expected the 22 Stage36 paired captures, found {len(pairs)}")
    return pairs


def masked_logits(model, x):
    logits = model(x).clone()
    logits[:, 6] = -100.0
    return logits


def summarize(model, x):
    model.eval()
    with torch.inference_mode():
        probabilities = masked_logits(model, x[None]).softmax(1)[0].numpy()
    predicted = int(probabilities.argmax())
    return {
        "class_id": predicted,
        "class_name": CLASSES[predicted],
        "confidence": float(probabilities[predicted]),
    }


def main():
    if not STAGE.is_dir():
        raise FileNotFoundError(f"Extracted Stage36 package not found: {STAGE}")
    if not SOURCE_CHECKPOINT.is_file():
        raise FileNotFoundError(SOURCE_CHECKPOINT)
    if TARGET_CHECKPOINT.exists() or RESULTS.exists():
        raise FileExistsError("Preserving completed Stage36 experiment outputs")

    expected_hash = json.loads((BASELINE_PACKAGE / "model.json").read_text(encoding="utf-8-sig"))["checkpoint_sha256"]
    actual_hash = hashlib.sha256(SOURCE_CHECKPOINT.read_bytes()).hexdigest()
    if actual_hash != expected_hash:
        raise ValueError("dscnn_live_v1.pth does not match the Stage36 live_v1 INT8 source checkpoint")

    torch.set_num_threads(4)
    torch.manual_seed(20261102)
    pairs = load_field_pairs()

    with (ROOT / "v3c_manifest/cards.csv").open(encoding="utf-8-sig", newline="") as stream:
        manifest = list(csv.DictReader(stream))
    train_rows = [row for row in manifest if row["split"] == "train"]
    dev_rows = [row for row in manifest if row["split"] == "test"]
    train_x = load_fixed(train_rows)
    train_y = torch.tensor([
        1 if int(row["class_id"]) == 6 else int(row["class_id"])
        for row in train_rows
    ], dtype=torch.long)
    dev_x = load_fixed(dev_rows)
    dev_y = torch.tensor([
        1 if int(row["class_id"]) == 6 else int(row["class_id"])
        for row in dev_rows
    ], dtype=torch.long)
    field_x = torch.stack([view for pair in pairs for view in (pair["pcm"], pair["pl"])])
    field_y = torch.tensor([pair["label"] for pair in pairs for _ in range(2)], dtype=torch.long)

    teacher = DSCNN().eval()
    teacher.load_state_dict(torch.load(SOURCE_CHECKPOINT, map_location="cpu", weights_only=True))
    model = DSCNN().eval()
    model.load_state_dict(teacher.state_dict())

    baseline_field = []
    for pair in pairs:
        baseline_field.append({
            "recording_id": pair["recording_id"],
            "true_class_id": pair["label"],
            "pcm": summarize(teacher, pair["pcm"]),
            "pl": summarize(teacher, pair["pl"]),
        })

    class_counts = torch.bincount(train_y, minlength=8).float().clamp_min(1)
    base_weights = (len(train_y) / (7 * class_counts)).sqrt()
    base_weights[4] *= 1.5
    base_weights[5] *= 1.5
    field_counts = torch.bincount(field_y, minlength=8).float().clamp_min(1)
    field_weights = (len(field_y) / (7 * field_counts)).sqrt()
    field_weights[4] *= 1.5
    field_weights[5] *= 1.5
    optimizer = torch.optim.Adam(model.parameters(), lr=0.000025)
    mel = torch.clamp(torch.exp(train_x.double()) - 1e-8, min=0)
    history = []
    batch_size = 32

    for epoch in range(10):
        model.eval()  # Keep pretrained batch-normalization statistics fixed.
        losses = []
        order = torch.randperm(len(train_y))
        for step, ids in enumerate(order.split(batch_size)):
            gains = torch.pow(10.0, torch.empty(len(ids), 1, 1).uniform_(-1.5, 0.3)).double()
            inputs = torch.log(mel[ids] * gains.square() + 1e-8).float()
            with torch.no_grad():
                teacher_prob = TF.softmax(teacher(inputs)[:, OUTPUTS] / 2.0, dim=1)
            logits = masked_logits(model, inputs)
            base_loss = TF.cross_entropy(logits, train_y[ids], weight=base_weights)
            preserve = TF.kl_div(
                TF.log_softmax(logits[:, OUTPUTS] / 2.0, dim=1),
                teacher_prob,
                reduction="batchmean",
            ) * 4.0

            field_ids = torch.randint(len(field_y), (32,))
            selected = field_x[field_ids]
            # Gain perturbation approximates recording-level volume changes.
            field_gain = torch.pow(10.0, torch.empty(32, 1, 1).uniform_(-0.6, 0.2)).float()
            selected = selected + 2.0 * torch.log(field_gain)
            field_loss = TF.cross_entropy(
                masked_logits(model, selected), field_y[field_ids], weight=field_weights
            )
            loss = 0.65 * base_loss + 0.25 * preserve + 0.75 * field_loss
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            losses.append(float(loss.detach()))

        with torch.inference_mode():
            dev_pred = torch.cat([
                masked_logits(model, batch).argmax(1) for batch in dev_x.split(64)
            ])
        history.append({
            "epoch": epoch + 1,
            "mean_loss": float(np.mean(losses)),
            "source_dev_accuracy_glass_mapped_to_unknown": float((dev_pred == dev_y).float().mean()),
        })
        print(f"epoch={epoch + 1}/10 loss={history[-1]['mean_loss']:.5f} "
              f"dev_accuracy={history[-1]['source_dev_accuracy_glass_mapped_to_unknown']:.4f}", flush=True)

    # Keep an ordinary quantizable row, but make its logit permanently uncompetitive.
    with torch.no_grad():
        model.head.bias[6] = -100.0
    after_field = []
    for pair in pairs:
        after_field.append({
            "recording_id": pair["recording_id"],
            "true_class_id": pair["label"],
            "recording_used_for_fitting": True,
            "pcm": summarize(model, pair["pcm"]),
            "pl": summarize(model, pair["pl"]),
        })

    dev_pred = torch.cat([masked_logits(model, batch).argmax(1) for batch in dev_x.split(64)])
    torch.save(model.state_dict(), TARGET_CHECKPOINT)
    RESULTS.mkdir()
    result = {
        "experiment": "stage36_model_owner_v1",
        "source_checkpoint": SOURCE_CHECKPOINT.name,
        "source_checkpoint_sha256": actual_hash,
        "source_package_checkpoint_match": True,
        "source_manifest": "v3c_manifest/cards.csv",
        "field_root": str(FIELD_ROOT.relative_to(ROOT.parent)),
        "field_recordings": len(pairs),
        "paired_views_per_recording": ["PCM-derived 49x40 log-mel", "Stage36 calibrated PL 49x40 matrix"],
        "field_recordings_used_for_fitting": [pair["recording_id"] for pair in pairs],
        "glass_policy": "map glass_break training data to unknown ID 1; preserve 8 output logits; force output 6 below active classes",
        "class_ids": {str(i): name for i, name in enumerate(CLASSES)},
        "training": {"epochs": 10, "seed": 20261102, "learning_rate": 0.000025,
                     "loss": "0.65 source CE + 0.25 teacher KL + 0.75 balanced field CE"},
        "history": history,
        "source_dev_accuracy": float((dev_pred == dev_y).float().mean()),
        "source_dev_cards": len(dev_rows),
        "source_dev_split_note": "Reused development split; not independent field performance.",
        "field_baseline": baseline_field,
        "field_candidate": after_field,
        "candidate_checkpoint": TARGET_CHECKPOINT.name,
        "limitations": [
            "All Stage36 field recordings are fitting data; their predictions are not independent validation.",
            "Paired PCM and PL matrices share recording IDs and are not counted as separate recordings.",
            "Only two distinct board baby_cry recordings are available; collect new board captures for holdout validation.",
        ],
    }
    (RESULTS / "comparison.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"candidate_checkpoint": str(TARGET_CHECKPOINT),
                      "field_candidate": after_field,
                      "source_dev_accuracy": result["source_dev_accuracy"]},
                     ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
