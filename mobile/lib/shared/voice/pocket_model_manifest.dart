import 'package:flutter/foundation.dart';

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

const pocketModelVersion = '3';
const pocketModelRuntimeBytes = 473251634;
const pocketModelDownloadBytes = 473270289;
const _pocketModelBase =
    'https://huggingface.co/csukuangfj2/'
    'sherpa-onnx-pocket-tts-2026-01-26/resolve/'
    '96d1e53ce3311ca6c2c6a35e2062d36b4cec6fa3';
const _pocketVoiceUrl =
    'https://huggingface.co/kyutai/tts-voices/resolve/'
    '323332d33f997de8394f24a193e1a76df720e01a/'
    'vctk/p333_023_enhanced.wav';

final pocketModelArtifacts = <PocketModelArtifact>[
  _artifact(
    'decoder.onnx',
    41478706,
    'f267880fde6c58b17b0a8f3647eaf8dcfad321f833f32d583ebc2fb2d1a15f10',
  ),
  _artifact(
    'encoder.onnx',
    72713165,
    'e8f2f6d301ffb96e398b138a7dc6d3038622d236044636b73d920bab85890260',
  ),
  _artifact(
    'lm_flow.onnx',
    39097094,
    '79c013a554a54e63319c33c0cc8830cbbedc9b7e448ae7e26f7923ae11f9873e',
  ),
  _artifact(
    'lm_main.onnx',
    302742148,
    '255d1a9263c5abdf36034abfc19c11d21cc5f40f0f87d8361288e972cbd5c578',
  ),
  _artifact(
    'text_conditioner.onnx',
    16388343,
    '0b84e837d7bfaf2c896627b03e3f080320309f37f4fc7df7698c644f7ba5e6b1',
  ),
  _artifact(
    'vocab.json',
    69478,
    '6fb646346cf931016f70c4921aab0900ce7a304b893cb02135c74e294abfea01',
  ),
  _artifact(
    'token_scores.json',
    123616,
    '5be2f278caf9b9800741f0fd82bff677f4943ec764c356f907213434b622d958',
  ),
  PocketModelArtifact(
    name: 'reference_sample.wav',
    url: Uri.parse(_pocketVoiceUrl),
    size: 639084,
    sha256: 'a35b0468382218e9f37a9a7494d1e4b74deaf18d7ced22265b4e325bb55c183f',
  ),
  _artifact(
    'LICENSE',
    18655,
    'fe7b4ce83b8381cc5b216bbb4af73c570688d1b819c73bbaed8ca401f4677cd6',
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

Original model: https://huggingface.co/kyutai/pocket-tts
ONNX export: https://huggingface.co/KevinAHM/pocket-tts-onnx
Sherpa-onnx repackage:
https://huggingface.co/csukuangfj2/sherpa-onnx-pocket-tts-2026-01-26

Reference voice: Mary (VCTK p333, enhanced by ai-coustics), from
https://huggingface.co/kyutai/tts-voices

Provided "AS IS", without warranty of any kind, express or implied.
''';
