import 'package:flutter/foundation.dart';

enum PocketModelVariant {
  higherQuality(
    precision: 'fp32',
    nativePrecision: 0,
    label: 'Higher quality',
    coreBytes: 439555904,
    runtimeBytes: 440213643,
  ),
  faster(
    precision: 'int8',
    nativePrecision: 1,
    label: 'Faster',
    coreBytes: 165232420,
    runtimeBytes: 165890159,
  );

  final String precision;
  final int nativePrecision;
  final String label;
  final int coreBytes;
  final int runtimeBytes;

  const PocketModelVariant({
    required this.precision,
    required this.nativePrecision,
    required this.label,
    required this.coreBytes,
    required this.runtimeBytes,
  });

  String get cacheKey => precision;

  static PocketModelVariant fromStored(String? value) =>
      values.where((variant) => variant.precision == value).firstOrNull ??
      higherQuality;
}

@immutable
class PocketModelArtifact {
  final String name;
  final Uri url;
  final int size;
  final String sha256;

  const PocketModelArtifact({
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
  });
}

const pocketModelVersion = '5';
const pocketLegacyFp32Version = '4';
const pocketModelRevision = '58a6d00cf13d239b6748cb0769f35c580a8f606c';
const _pocketModelBase =
    'https://huggingface.co/KevinAHM/pocket-tts-onnx/resolve/'
    '$pocketModelRevision/onnx/english_2026-04';
const _pocketLicenseUrl =
    'https://huggingface.co/KevinAHM/pocket-tts-onnx/resolve/'
    '$pocketModelRevision/onnx/LICENSE';
const _pocketVoiceUrl =
    'https://huggingface.co/kyutai/tts-voices/resolve/'
    '323332d33f997de8394f24a193e1a76df720e01a/'
    'vctk/p333_023_enhanced.wav';

final pocketModelArtifacts = <PocketModelVariant, List<PocketModelArtifact>>{
  PocketModelVariant.higherQuality: [
    ..._commonArtifacts,
    _artifact(
      'flow_lm_main.onnx',
      302742149,
      '6d18315e2c33ca3e3aa4a4e3dca22f56d007fd823127e24948b37695bf54190f',
    ),
    _artifact(
      'flow_lm_flow.onnx',
      39097095,
      '085d239f68897e28fb06e95c743738ad8b8c092ee6dc55f5491313e81ff08062',
    ),
    _artifact(
      'mimi_decoder.onnx',
      41471926,
      '86f038caa02a96a0ff9c25526a0ff43a4906c418197ed72d3e30f720ac7ce802',
    ),
    ..._sharedFp32Graphs,
    ..._voiceAndLicense,
  ],
  PocketModelVariant.faster: [
    ..._commonArtifacts,
    _artifact(
      'flow_lm_main_int8.onnx',
      76341079,
      'f9bd8106b79a0192c1c43399ab938fb24900a95c1c599870d75a884e99000116',
    ),
    _artifact(
      'flow_lm_flow_int8.onnx',
      9962530,
      '3dd781ee5abee9e195320bf0106bebd6372a852b3b36352524ee78b40554635d',
    ),
    _artifact(
      'mimi_decoder_int8.onnx',
      22684077,
      '3630450a3297a101792a6ac66619ebc70ab916b265e6220c2afaef8b1673f925',
    ),
    ..._sharedFp32Graphs,
    ..._voiceAndLicense,
  ],
};

final _commonArtifacts = <PocketModelArtifact>[
  _artifact(
    'bundle.json',
    24381,
    'bab643150f437f37df080a710520ff39ed9ebd9a339f8ebdc739f7eddfc28b3f',
  ),
  _artifact(
    'bos_before_voice.npy',
    4224,
    'f46edf4f7007b7ba4ea58831f49d003e59e167b4641c44bb3addfe9231a780b1',
  ),
  _artifact(
    'tokenizer.model',
    59339,
    'd461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6',
  ),
];

final _sharedFp32Graphs = <PocketModelArtifact>[
  _artifact(
    'mimi_encoder.onnx',
    39768446,
    '853e2ca623b8782d94c3745ec6133bfdff7ce33d9b11128bd29ea03f28d76e3d',
  ),
  _artifact(
    'text_conditioner.onnx',
    16388344,
    '4ecee995fb69f85c7a7493d11f7b5ee15d9950facc7ab3f5c9c49ef1e03847bb',
  ),
];

final _voiceAndLicense = <PocketModelArtifact>[
  PocketModelArtifact(
    name: 'reference_sample.wav',
    url: Uri.parse(_pocketVoiceUrl),
    size: 639084,
    sha256: 'a35b0468382218e9f37a9a7494d1e4b74deaf18d7ced22265b4e325bb55c183f',
  ),
  PocketModelArtifact(
    name: 'LICENSE',
    url: Uri.parse(_pocketLicenseUrl),
    size: 18655,
    sha256: 'fe7b4ce83b8381cc5b216bbb4af73c570688d1b819c73bbaed8ca401f4677cd6',
  ),
];

PocketModelArtifact _artifact(String name, int size, String sha256) =>
    PocketModelArtifact(
      name: name,
      url: Uri.parse('$_pocketModelBase/$name'),
      size: size,
      sha256: sha256,
    );

const pocketModelLicenseText = '''
Pocket TTS
© Kyutai.

Licensed under the Creative Commons Attribution 4.0 International License
(CC-BY-4.0). License text: https://creativecommons.org/licenses/by/4.0/

Original model by Kyutai: https://huggingface.co/kyutai/pocket-tts
Paper: Charles, Roebel, et al., Pocket TTS (arXiv:2509.06926).
Mimi neural codec by Kyutai is bundled as part of the model.

April 2026 ONNX export by KevinAHM:
https://huggingface.co/KevinAHM/pocket-tts-onnx
Pinned revision: 58a6d00cf13d239b6748cb0769f35c580a8f606c
Bundle: english_2026-04. The Faster option uses the upstream-supported
three-graph INT8 selection; encoder and text conditioner remain FP32.

Bundled reference voice (reference_sample.wav):
"Mary (f, conversation)" preset from the Kyutai TTS demo voice catalogue
(https://kyutai.org/tts), distributed via
https://huggingface.co/kyutai/tts-voices as `vctk/p333_023_enhanced.wav`.
Original recording from the Voice Cloning Toolkit (VCTK) corpus, speaker p333:
https://datashare.ed.ac.uk/handle/10283/3443 (CC-BY-4.0).
Recording enhancement (denoise/dereverb) by ai-coustics:
https://ai-coustics.com/

Buzz ships all ONNX/model artifacts and the reference voice WAV unmodified,
renamed only by placement in the local model directory.

Provided "AS IS", without warranty of any kind, express or implied. See the
license text for full warranty disclaimer.
''';
