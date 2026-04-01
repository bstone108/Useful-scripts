#!/bin/bash

GPU=0
TARGET_LIMIT="50.00"

PMODE=$(/usr/bin/nvidia-smi -i "$GPU" --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | xargs)
CURRENT_LIMIT=$(/usr/bin/nvidia-smi -i "$GPU" --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | awk '{printf "%.2f", $1}')

if [[ -z "$CURRENT_LIMIT" ]]; then
    logger "[gpu-power] nvidia-smi query failed for GPU $GPU"
    exit 1
fi

if [[ "$PMODE" != "Enabled" || "$CURRENT_LIMIT" != "$TARGET_LIMIT" ]]; then
    /usr/bin/nvidia-smi -i "$GPU" -pm 1 >/dev/null 2>&1
    /usr/bin/nvidia-smi -i "$GPU" -pl "$TARGET_LIMIT" >/dev/null 2>&1

    NEW_PMODE=$(/usr/bin/nvidia-smi -i "$GPU" --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | xargs)
    NEW_LIMIT=$(/usr/bin/nvidia-smi -i "$GPU" --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | awk '{printf "%.2f", $1}')

    logger "[gpu-power] Corrected GPU $GPU state: persistence=$NEW_PMODE, power_limit=${NEW_LIMIT}W"
fi
