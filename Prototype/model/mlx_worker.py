"""Runs one MLX model once, in its own process, so all its memory goes back to the system when it exits
(the same shape as Aegis's planned on-demand ModelService). Started by benchmark.py, offline.

    mlx_worker.py MODEL_PATH SPEC_JSON   ->   one JSON object on stdout

SPEC_JSON holds {"system": ..., "user": ..., "max_tokens": ...}.
"""

import json
import sys
import time

started = time.perf_counter()
from mlx_lm import load, stream_generate  # noqa: E402
from mlx_lm.sample_utils import make_sampler  # noqa: E402

imported = time.perf_counter()
model_path, spec_path = sys.argv[1], sys.argv[2]
with open(spec_path, encoding="utf-8") as f:
    spec = json.load(f)

model, tokenizer = load(model_path)
loaded = time.perf_counter()

messages = [{"role": "system", "content": spec["system"]}, {"role": "user", "content": spec["user"]}]
try:
    prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True, enable_thinking=False)
except TypeError:  # templates without a thinking switch
    prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)

text, first, last = "", None, None
begin = time.perf_counter()
for response in stream_generate(model, tokenizer, prompt, max_tokens=spec.get("max_tokens", 700), sampler=make_sampler(temp=0.0)):
    if first is None:
        first = time.perf_counter() - begin
    text += response.text
    last = response
finished = time.perf_counter()

print(
    json.dumps(
        {
            "import_s": imported - started,
            "load_s": loaded - imported,
            "first_token_s": first,
            "generate_s": finished - begin,
            "prompt_tokens": getattr(last, "prompt_tokens", None),
            "prompt_tps": getattr(last, "prompt_tps", None),
            "generation_tokens": getattr(last, "generation_tokens", None),
            "generation_tps": getattr(last, "generation_tps", None),
            "mlx_peak_gb": getattr(last, "peak_memory", None),
            "text": text,
        }
    )
)
