# LLM → SLM distillation on AWS (credit-card fraud)

A large "teacher" LLM (Bedrock Claude Opus 5.5) labels credit-card transactions. Those labels train a small "student" classifier (DistilBERT on SageMaker), which is deployed to a real-time endpoint and evaluated against the human-gold `is_fraud` column. The goal is to show that a small, cheap, fast model can reproduce the teacher's triage decisions.

- **Data:** `../data/fraudTrain.csv`, `../data/fraudTest.csv` (Sparkov synthetic dataset).
- **Teacher:** `us.anthropic.claude-opus-5-5` via the Bedrock Converse API.
- **Student:** `distilbert-base-uncased`, a 2-class encoder (`legit` / `fraud`), fine-tuned on `ml.g5.xlarge`.
- **Serving:** SageMaker real-time endpoint `slm-fraud-distilbert` on `ml.m5.xlarge` (CPU).

## Pipeline

```
CSV ─▶ 01 prepare ─▶ 02 teacher labels ─▶ 03 consensus + train ─▶ 04 deploy + shadow eval ─▶ 05 cleanup
        (S3)          (Bedrock Opus)        (SageMaker, Registry)    (endpoint, eval.json)     (delete endpoint)
```

| Step | Script | What it does |
|------|--------|--------------|
| 1 | `01_prepare_data.py` | Samples a fraud-enriched set (default 3000 train / 500 val / 1000 test, 25% fraud) with a time-based split: before 2020-04-01 → train, after → validation, `fraudTest.csv` → test. Converts each row to text with `features.to_text` and uploads to S3. Flags: `--train`, `--val`, `--test`, `--fraud-frac`. |
| 2 | `02_label_teacher.py` | Asks each teacher model for `{"label", "confidence", "reason"}` JSON per event. Resumable (keyed on event + model + prompt version), bounded concurrency (`--workers`), backoff on throttling, and unparseable replies are kept as `parse_error` rows and excluded downstream. Flags: `--splits`, `--limit`. |
| 3 | `03_train_sagemaker.py` | Builds consensus labels (unanimous, majority, or dropped for review), prints teacher-vs-gold agreement, runs the SageMaker training job, and registers the model in the Model Registry as `PendingManualApproval`. |
| 4 | `04_deploy_eval.py` | Deploys the endpoint, replays the test set one event at a time ("shadow" mode: the student never drives a decision), and writes metrics and gates to `artifacts/eval.json`. `--skip-deploy` reuses a running endpoint. |
| 5 | `05_cleanup.py` | Deletes the endpoint, endpoint config, and model. S3 data and Registry entries are kept. |

## Prerequisites

- Python 3.11+, AWS credentials for the target account, `us-east-1` by default.
- Bedrock model access enabled for the teacher model.
- A SageMaker execution role. `config.py` looks up `AmazonSageMaker-ExecutionRole-20260326T124200` unless `SM_ROLE` is set.
- Quota for one `ml.g5.xlarge` training instance and one `ml.m5.xlarge` endpoint instance.
- The Kaggle fraud CSVs in `../data/`.

`config.py` calls STS and IAM at import time, so every step needs working AWS credentials.

## Run

```bash
# from the repo root (the .venv lives there)
.venv/bin/pip install -r aws_demo/requirements.txt
cd aws_demo

../.venv/bin/python 01_prepare_data.py
../.venv/bin/python 02_label_teacher.py
../.venv/bin/python 03_train_sagemaker.py
../.venv/bin/python 04_deploy_eval.py
../.venv/bin/python 05_cleanup.py     # always run when done: the endpoint bills while it is up
```

## Configuration

Set these environment variables rather than editing the step scripts.

| Variable | Default | Purpose |
|----------|---------|---------|
| `AWS_REGION` | `us-east-1` | Region for all services |
| `DEMO_BUCKET` | `sagemaker-slm-distill-<account>-<region>` | S3 bucket. Keep "sagemaker" in the name so the default execution-role S3 grant applies. |
| `SM_ROLE` | looked up by name | SageMaker execution role ARN |
| `TEACHER_MODELS` | `us.anthropic.claude-opus-5-5` | Comma-separated list. Multiple teachers enable consensus voting. |
| `STUDENT_BASE` | `distilbert-base-uncased` | Hugging Face base model |
| `TRAIN_INSTANCE` | `ml.g5.xlarge` | Training instance type |
| `ENDPOINT_INSTANCE` | `ml.m5.xlarge` | Inference instance type |

## Layout

```
aws_demo/
├── 01_…05_*.py        step scripts
├── config.py          shared settings (region, bucket, role, models, instances, container versions)
├── features.py        to_text(): the single row → text serialization
├── code/train.py      SageMaker training entrypoint (class-weighted loss, early stopping on F1)
├── model/             trained model, model.tar.gz, and deploy.py (standalone deploy / --delete)
└── artifacts/         events, teacher labels, train/validation sets, predictions, eval.json, logs
```

`features.to_text` produces text such as:

```
amount $1128.26; category shopping_net; merchant Kuhic LLC; time Sun 23:21; customer M age 26 job Herbalist; home Denham Springs LA pop 71335; distance to merchant 26 km
```

The teacher, training, and inference all use this one function. It drops PII (name, street, card number, transaction number), so those fields never reach Bedrock or the model.

## Serving contract

```
POST invoke_endpoint  ContentType: application/json
{"inputs": "<event text>"}
→ [{"label": "fraud", "score": 0.97}]
```

To deploy the packaged model without running the whole pipeline, use `model/deploy.py`. It accepts `--instance-type`, `--endpoint-name`, `--bucket`, and `--role`, and `--delete` tears the endpoint down.

## Results (latest run, `artifacts/eval.json`)

Test set: 1000 events, 25% fraud.

| | Accuracy | Precision | Recall | F1 |
|---|---|---|---|---|
| Teacher vs gold | 0.929 | 0.924 | 0.780 | 0.846 |
| Student vs gold | 0.915 | 0.895 | 0.748 | 0.815 |

- Student/teacher agreement: **97%**.
- Client-side latency: p50 98 ms, p95 110 ms, p99 136 ms.
- Confidence routing (low-confidence student calls fall back to the teacher), as in the table below. At 0.95, 12.4% of calls go to the teacher and F1 rises to 0.825.

| Threshold | Teacher share | F1 |
|---|---|---|
| 0.6 | 0.7% | 0.813 |
| 0.9 | 7.6% | 0.820 |
| 0.95 | 12.4% | 0.825 |
| 0.99 | 83.8% | 0.843 |

Promotion gates:

| Gate | Result |
|---|---|
| Student F1 within 5 pp of teacher | pass |
| Student/teacher agreement > 95% | pass |
| p99 latency < 50 ms (client-side, includes network) | **fail**: 136 ms |

The latency gate fails because it is measured from the client over the network against a CPU instance. A GPU or a smaller/optimized instance, or measuring server-side latency, would be the next thing to try.

## Caveats

- The sample is enriched to 25% fraud (the real rate is about 0.4%), so precision and F1 are not production-rate numbers.
- Evaluation is against the human-gold `is_fraud` label, not teacher agreement alone.
- The test set is replayed sequentially from one client, so the latency numbers are not a load test.
- `model/README.md` and `model/deploy.py` still refer to `demo/` paths (now `aws_demo/`). `deploy.py` itself works, but its docstring examples need the venv path changed to `../../.venv/bin/python`.
