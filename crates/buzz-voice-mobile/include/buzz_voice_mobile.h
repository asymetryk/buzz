#ifndef BUZZ_VOICE_MOBILE_H
#define BUZZ_VOICE_MOBILE_H

#include <stddef.h>
#include <stdint.h>

typedef struct BuzzVoiceEngineResult {
  void *engine;
  char *error;
} BuzzVoiceEngineResult;

typedef struct BuzzVoicePcm {
  int16_t *samples;
  size_t len;
  uint32_t sample_rate;
  char *error;
} BuzzVoicePcm;

#define BUZZ_VOICE_PRECISION_FP32 0
#define BUZZ_VOICE_PRECISION_INT8 1

BuzzVoiceEngineResult buzz_voice_engine_create(const char *model_dir,
                                               uint8_t precision);
char *buzz_voice_prepare_chunks_json(void *engine, const char *text);
BuzzVoicePcm buzz_voice_engine_synthesize(void *engine, const char *text);
void buzz_voice_engine_cancel(void *engine);
void buzz_voice_engine_reset_cancel(void *engine);
void buzz_voice_engine_destroy(void *engine);
void buzz_voice_pcm_free(BuzzVoicePcm pcm);
void buzz_voice_string_free(char *value);

#endif
