# Third-party model notice

## Paraformer Chinese and English offline ASR

- Files: `model.int8.onnx`, `tokens.txt`
- Upstream export: [csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09](https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09)
- Sherpa-ONNX model guide: [Offline Paraformer models](https://github.com/k2-fsa/sherpa/blob/master/docs/source/onnx/pretrained_models/offline-paraformer/paraformer-models.rst)
- Base model attribution: Alibaba DAMO Academy / FunASR, `speech_paraformer_asr_nat-zh-cn-16k-common-vocab8358-onnx`.
- License provenance: the upstream conversion page does not state a separate model license. The OpenVoiceOS model card for the same ONNX graph says its graph is copied byte-for-byte from the sherpa-onnx export and identifies the base FunASR model as Apache-2.0: [model card and attribution](https://huggingface.co/OpenVoiceOS/paraformer-zh-small-onnx/blob/main/README.md).
- Model file size: 81,828,675 bytes (about 81.8 MB); the model and tokens are bundled for offline first use. No sample recordings or training files are included.

The sherpa-onnx runtime package is a separate dependency distributed under Apache-2.0. The `record` package is distributed under BSD-3-Clause.

## Silero voice activity detection

- File: `assets/speech_models/silero-vad-int8/silero_vad.int8.onnx`
- Upstream export: [k2-fsa/sherpa-onnx Silero VAD models](https://k2-fsa.github.io/sherpa/onnx/vad/silero-vad.html)
- License: Silero VAD is MIT-licensed; sherpa-onnx documents the model as an 8-bit, 16 kHz export maintained by k2-fsa. [VAD license information](https://k2-fsa.github.io/sherpa/onnx/vad/index.html)
- File size: 212,860 bytes. SHA-256: `C36D490AFF5AB924CA6C7AEEC4D8F6BD3D22DB6FA17611B9C5B17EAE58AC3A20`.
- Used locally to reject recordings without detected speech before Paraformer receives audio.
