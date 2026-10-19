# LoRA Fine-Tuning Guide

This guide demonstrates how to fine-tune an instruction-tuned large language model using **LoRA (Low-Rank Adaptation)** with Hugging Face and PyTorch.

The example uses [`Qwen/Qwen2.5-1.5B-Instruct`](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct), a relatively small model suitable for experimentation.

## What LoRA does

LoRA keeps the original model weights frozen and trains a small set of adapter weights instead. Conceptually, a model weight matrix is updated as:

```text
W' = W + BA
```

`W` is the frozen base-model weight matrix, while `A` and `B` are much smaller trainable matrices. This reduces GPU memory use, training time, and the size of the resulting fine-tuning artifact.

At inference time, the model consists of:

```text
Base model + LoRA adapter
```

## Prerequisites

* Python 3.10 or newer
* PyTorch
* A CUDA-capable GPU is recommended, although this small example can run on CPU slowly
* Sufficient disk space to download the base model

Install the dependencies:

```bash
pip install torch transformers datasets peft accelerate
```

## 1. Prepare training data

Create a file named `train.jsonl`. Each line should contain one JSON object with a `messages` array:

```json
{"messages":[{"role":"user","content":"What is Apache Kafka?"},{"role":"assistant","content":"Apache Kafka is a distributed event-streaming platform used to publish, store, and process streams of records."}]}
{"messages":[{"role":"user","content":"Explain a Kafka topic."},{"role":"assistant","content":"A Kafka topic is a named stream where producers write records and consumers read records."}]}
{"messages":[{"role":"user","content":"What is a Kafka consumer group?"},{"role":"assistant","content":"A consumer group is a set of consumers that cooperate to process records from Kafka topics."}]}
```

These examples are intentionally small and are only for demonstrating the workflow. A useful fine-tuning dataset usually contains hundreds or thousands of carefully reviewed examples.

### Data quality recommendations

* Keep the answers accurate and consistent.
* Match the data format to the behavior you want at inference time.
* Include representative edge cases.
* Avoid contradictory answers.
* Remove sensitive data unless it is explicitly approved for model training.
* Keep evaluation examples separate from the training set.

## 2. Train the LoRA adapter

Create a file named `train_lora.py`:

```python
import torch
from datasets import load_dataset
from transformers import (
    AutoTokenizer,
    AutoModelForCausalLM,
    TrainingArguments,
    Trainer,
    DataCollatorForLanguageModeling,
)
from peft import LoraConfig, get_peft_model


MODEL_ID = "Qwen/Qwen2.5-1.5B-Instruct"

# Load the tokenizer
tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)

if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

# Load the JSONL dataset
dataset = load_dataset(
    "json",
    data_files={"train": "train.jsonl"},
)["train"]


# Convert chat messages into the model's expected chat format
def format_example(example):
    text = tokenizer.apply_chat_template(
        example["messages"],
        tokenize=False,
        add_generation_prompt=False,
    )
    return {"text": text}


dataset = dataset.map(format_example)


# Tokenize examples
def tokenize(example):
    return tokenizer(
        example["text"],
        truncation=True,
        max_length=1024,
    )


tokenized_dataset = dataset.map(
    tokenize,
    batched=True,
    remove_columns=dataset.column_names,
)


# Load the base model
device_is_cuda = torch.cuda.is_available()

model = AutoModelForCausalLM.from_pretrained(
    MODEL_ID,
    torch_dtype=torch.float16 if device_is_cuda else torch.float32,
)

model.config.use_cache = False


# Configure LoRA
lora_config = LoraConfig(
    r=8,
    lora_alpha=16,
    lora_dropout=0.05,
    target_modules=["q_proj", "v_proj"],
    bias="none",
    task_type="CAUSAL_LM",
)


# Attach the LoRA adapter. The base model remains frozen.
model = get_peft_model(model, lora_config)
model.print_trainable_parameters()


# Configure training
training_args = TrainingArguments(
    output_dir="./lora-output",
    per_device_train_batch_size=2,
    gradient_accumulation_steps=8,
    learning_rate=2e-4,
    num_train_epochs=3,
    logging_steps=10,
    save_strategy="epoch",
    report_to="none",
    fp16=device_is_cuda,
)


data_collator = DataCollatorForLanguageModeling(
    tokenizer=tokenizer,
    mlm=False,
)


trainer = Trainer(
    model=model,
    args=training_args,
    train_dataset=tokenized_dataset,
    data_collator=data_collator,
)

trainer.train()

# Save only the LoRA adapter and tokenizer
model.save_pretrained("./lora-adapter")
tokenizer.save_pretrained("./lora-adapter")
```

Run the training job:

```bash
python train_lora.py
```

The most important configuration is:

```python
lora_config = LoraConfig(
    r=8,
    lora_alpha=16,
    lora_dropout=0.05,
    target_modules=["q_proj", "v_proj"],
    task_type="CAUSAL_LM",
)
```

### Main LoRA parameters

* `r`: The adapter rank. Larger values provide more capacity but use more memory.
* `lora_alpha`: Scaling factor applied to the LoRA update.
* `lora_dropout`: Regularization applied to the adapter during training.
* `target_modules`: Model layers that receive LoRA adapters.

For this Qwen model, `q_proj` and `v_proj` are common starting points. Adding more projection or feed-forward layers can increase adapter capacity and memory usage.

## 3. Run inference with the adapter

Create `inference.py`:

```python
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM
from peft import PeftModel


MODEL_ID = "Qwen/Qwen2.5-1.5B-Instruct"
ADAPTER_PATH = "./lora-adapter"

# Load the tokenizer saved with the adapter
tokenizer = AutoTokenizer.from_pretrained(ADAPTER_PATH)

# Load the original base model
base_model = AutoModelForCausalLM.from_pretrained(
    MODEL_ID,
    torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32,
)

# Attach the trained LoRA weights
model = PeftModel.from_pretrained(
    base_model,
    ADAPTER_PATH,
)

model.eval()

messages = [
    {
        "role": "user",
        "content": "What is a Kafka partition?",
    }
]

inputs = tokenizer.apply_chat_template(
    messages,
    return_tensors="pt",
    add_generation_prompt=True,
).to(model.device)

with torch.no_grad():
    outputs = model.generate(
        inputs,
        max_new_tokens=128,
        temperature=0.7,
        do_sample=True,
    )

# Decode only the newly generated tokens
generated_tokens = outputs[0][inputs.shape[-1]:]

print(
    tokenizer.decode(
        generated_tokens,
        skip_special_tokens=True,
    )
)
```

Run inference:

```bash
python inference.py
```

## Output files

After training, the adapter directory typically contains files similar to:

```text
lora-adapter/
├── adapter_config.json
├── adapter_model.safetensors
├── tokenizer.json
└── tokenizer_config.json
```

The adapter is much smaller than a complete copy of the base model. You can maintain multiple adapters for different domains while sharing the same base model.

## LoRA versus full fine-tuning

| Approach | Parameters updated | Memory use | Output artifact | Typical use |
|---|---:|---:|---:|---|
| Full fine-tuning | All model parameters | High | Complete model copy | Major capability or behavior changes |
| LoRA | Small adapter subset | Lower | Adapter only | Domain, style, format, or task adaptation |

## Practical tuning guidance

* Start with `r=8` or `r=16`.
* Increase the rank if the adapter underfits the task.
* Use a validation set to detect overfitting.
* Monitor generated outputs, not only training loss.
* Keep the learning rate and number of epochs modest when the dataset is small.
* Use a held-out evaluation set for meaningful comparisons.
* Consider QLoRA when GPU memory is limited.

## QLoRA extension

QLoRA combines LoRA with a quantized base model, commonly using 4-bit quantization. The base model is loaded in a compressed format while the LoRA parameters remain trainable. This substantially reduces GPU memory requirements, but requires additional packages such as `bitsandbytes` and a compatible CUDA environment.

The workflow remains:

```text
Quantized base model
        ↓
Frozen base weights
        ↓
Trainable LoRA adapters
        ↓
Saved adapter
```

## Troubleshooting

### CUDA out-of-memory

Try one or more of the following:

* Reduce `per_device_train_batch_size`.
* Increase `gradient_accumulation_steps` to preserve the effective batch size.
* Reduce `max_length`.
* Use QLoRA with 4-bit quantization.
* Reduce the LoRA rank.

### The model produces poor answers

Check the following:

* Training examples match the inference format.
* The dataset is large and diverse enough.
* The response text is high quality.
* The learning rate is not too high.
* The model is not overfitting a tiny dataset.
* `target_modules` are appropriate for the selected base model.

### Chat template errors

Different models use different chat templates. Always check the selected model's documentation and use its tokenizer's `apply_chat_template` when available.
