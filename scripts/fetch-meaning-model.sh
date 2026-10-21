#!/usr/bin/env bash
# The memory meaning model (#309, ADR-0027): BAAI/bge-small-en-v1.5 (MIT, ~130 MB), downloaded once at a pinned
# revision into Aegis's folder and checked by SHA-256. It runs on this Mac inside ModelService; nothing is sent.
set -euo pipefail
revision=5c38ec7c405ec4b44b94cc5a9bb96e735b38267a
destination="$HOME/Library/Application Support/Aegis/Models/bge-small-en-v1.5"
files=(
  "config.json 094f8e891b932f2000c92cfc663bac4c62069f5d8af5b5278c4306aef3084750"
  "tokenizer.json d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66"
  "tokenizer_config.json 9261e7d79b44c8195c1cada2b453e55b00aeb81e907a6664974b4d7776172ab3"
  "special_tokens_map.json b6d346be366a7d1d48332dbc9fdf3bf8960b5d879522b7799ddba59e76237ee3"
  "vocab.txt 07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"
  "modules.json 84e40c8e006c9b1d6c122e02cba9b02458120b5fb0c87b746c41e0207cf642cf"
  "1_Pooling/config.json d1caf60c96f5fba2157c0c26b76d80818fad6cf0b8eb5e73ec372ff9818eba5c"
  "model.safetensors 3c9f31665447c8911517620762200d2245a2518d6e7208acc78cd9db317e21ad"
)
mkdir -p "$destination/1_Pooling"
for entry in "${files[@]}"; do
  name=${entry% *}; sum=${entry#* }
  target="$destination/$name"
  if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | cut -d' ' -f1)" == "$sum" ]]; then continue; fi
  curl -sfL "https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/$revision/$name" -o "$target.part"
  [[ "$(shasum -a 256 "$target.part" | cut -d' ' -f1)" == "$sum" ]] || { rm -f "$target.part"; echo "✖ $name failed its check" >&2; exit 1; }
  mv "$target.part" "$target"
done
echo "✔ meaning model ready"
