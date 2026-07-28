//! Pocket TTS engine for caller-provided January and April model bundles.
//!
//! The January layout runs through sherpa-onnx's `OfflineTts`. The April
//! `english_2026-04` bundle uses the same linked ONNX Runtime with its
//! SentencePiece tokenizer, learned BOS, and recurrent state manifests.
//!
//! ## Attribution
//!
//! - **Model**: Kyutai *Pocket TTS* — Charles, Roebel, et al., 2026.
//!   arXiv:2509.06926. Original repository: <https://huggingface.co/kyutai/pocket-tts>.
//!   Licensed CC-BY-4.0.
//! - **Mimi neural codec**: Kyutai, bundled in the same release. CC-BY-4.0.
//! - **ONNX export**: KevinAHM —
//!   <https://huggingface.co/KevinAHM/pocket-tts-onnx>. CC-BY-4.0.
//! - **sherpa-onnx repackage**: csukuangfj / k2-fsa —
//!   <https://huggingface.co/csukuangfj2/sherpa-onnx-pocket-tts-2026-01-26>.
//!   Repackages KevinAHM's export with the file layout sherpa-onnx's
//!   `OfflineTtsPocketModelConfig` expects. CC-BY-4.0.
//! - **Reference voice WAV** (`reference_sample.wav`): the "Mary
//!   (f, conversation)" preset from the Kyutai TTS demo
//!   (<https://kyutai.org/tts>), which maps to `vctk/p333_023_enhanced.wav`
//!   in <https://huggingface.co/kyutai/tts-voices>. CC-BY-4.0, base recording
//!   from the VCTK corpus, enhanced by ai-coustics.
//!
//! Callers own acquisition, storage, and the required CC-BY-4.0 attribution.
//!
//! ## Engine-module contract (see `huddle::tts`)
//!
//! `pocket.rs` exposes the shared loading and synthesis surface, including
//! explicit runtime-only model options:
//!
//! - `SAMPLE_RATE: u32`             — engine output sample rate in Hz.
//! - `DEFAULT_VOICE: &str`          — default voice name (without extension).
//! - `VOICE_FILE_EXT: &str`         — extension for per-voice files on disk.
//! - `load_text_to_speech(model_dir)`              → `Result<Engine, String>`
//! - `load_voice_style(path)`                      → `Result<VoiceStyle, String>`
//! - `Engine::synth_chunk(&self, text, lang, &VoiceStyle, steps)`
//!   → `Result<Vec<f32>, String>`
//!
//! `lang` and `steps` are accepted for API compatibility with the previous
//! Kokoro engine but are unused — Pocket TTS does its own language ID from
//! the input text and is not a diffusion model (consistency LM, one step).
//! There is no speed knob: sherpa-onnx's `GenerationConfig.speed` is only
//! read by some model families (vits), never by the Pocket impl
//! (`offline-tts-pocket-impl.h` — zero references), and upstream pocket-tts
//! has no speed parameter either.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use sherpa_onnx::{GenerationConfig, OfflineTts, OfflineTtsConfig, Wave};

#[path = "pocket_april.rs"]
mod pocket_april;
#[path = "pocket_models.rs"]
mod pocket_models;

use pocket_april::{prepare_april_prompt, AprilPocketTts};
pub use pocket_models::{
    april_model_info, PocketLoadOptions, PocketModelArtifact, PocketModelInfo,
    PocketModelSelection, PocketPrecision, APRIL_BUNDLE_ID, APRIL_MAX_TOKEN_PER_CHUNK,
    APRIL_MODEL_ID, APRIL_MODEL_REVISION,
};

// ── Engine-module contract: public consts ─────────────────────────────────────

/// Pocket TTS emits 24 kHz mono PCM. Matches the previous Kokoro output rate,
/// so the rodio sink and inter-sentence silence buffer in `tts.rs` remain valid.
pub const SAMPLE_RATE: u32 = 24_000;

/// Name (without extension) of the bundled reference voice. The model directory
/// is expected to contain `<DEFAULT_VOICE>.<VOICE_FILE_EXT>` after install.
pub const DEFAULT_VOICE: &str = "reference_sample";

/// Voice files for Pocket TTS are reference audio (WAV). Distinct from the
/// Kokoro `.bin` style vectors — the model conditions on raw waveform samples,
/// not a precomputed embedding, so the extension change is honest.
pub const VOICE_FILE_EXT: &str = "wav";

// ── Tuning ────────────────────────────────────────────────────────────────────

/// LRU cache size for cloned voice embeddings inside the sherpa-onnx engine.
/// We bind to one voice per pipeline today, but the upstream example uses 16
/// and the cost is negligible — keep room for future multi-voice support.
const VOICE_EMBEDDING_CACHE_CAPACITY: i32 = 16;

/// Pocket TTS is a consistency-based LM. Generation quality saturates at one
/// denoising step — the upstream `GenerationConfig` default of 5 multiplies
/// synthesis time by ~5× with no audible benefit on this model.
const SYNTH_NUM_STEPS: i32 = 1;

/// Leave the generated audio's silences untouched (1.0 is the identity).
///
/// sherpa-onnx's `ScaleSilence` (`offline-tts.cc`) is *not* pre/post padding
/// control: it finds every interior silence run ≥ 0.2 s (|s| ≤ 0.01) and
/// multiplies its length by this factor. The reference Pocket TTS pipeline
/// preserves natural clause breaks, breaths, and punctuation pauses, so the
/// identity scale keeps those interior silences intact.
const SYNTH_SILENCE_SCALE: f32 = 1.0;

/// sherpa-onnx upstream default for `max_frames` (LM steps), in
/// `offline-tts-pocket-impl.h:Generate`. 500 steps ≈ 40 s of audio at the
/// Mimi 12.5 Hz frame rate. Referenced only by the regression test below;
/// production code path never raises (or even reads) this value — we just
/// leave sherpa-onnx's own default in place by not setting the override.
#[cfg(test)]
const SHERPA_ONNX_MAX_FRAMES_DEFAULT: i32 = 500;

/// Tight `max_frames` we ask for on short, padded prompts to bound the
/// original "monster breathing" runaway. 100 LM steps ≈ 8 s of audio —
/// roomy for any one-to-four-word utterance the user is likely to elicit
/// while still well short of the 40 s upstream default. Chosen with slack so
/// we never *truncate* a legitimate short reply.
const SHORT_PROMPT_MAX_FRAMES: i32 = 100;

/// Word-count threshold (inclusive) below which we pad the prompt with
/// leading spaces and cap `max_frames` tighter than the upstream default.
/// Matches upstream `pocket_tts.models.tts_model.prepare_text_prompt`. Above
/// this threshold we leave sherpa-onnx's own defaults in place because
/// dropping `frames_after_eos` below the upstream default of 3 can clip the
/// leading audio of multi-clause sentences.
const SHORT_PROMPT_WORD_THRESHOLD: usize = 4;

/// Number of leading spaces prepended to short prompts. The upstream Python
/// uses exactly 8 — keep parity rather than tuning blindly.
///
/// This is upstream's *only* mitigation for the FlowLM cold-start smear on
/// short utterances (kyutai-labs/pocket-tts #91, #70): the autoregressive
/// generation has a 2–3 step "settle" period where the first phoneme can be
/// smeared. The pad must remain whitespace-only: synthesized sacrificial text
/// requires amplitude-threshold trimming, which can eat soft word starts.
const SHORT_PROMPT_PAD_SPACES: usize = 8;

/// sherpa-onnx's documented `frames_after_eos` default. We deliberately do
/// *not* override this knob because values below the upstream default of 3 can
/// clip the leading audio of multi-clause sentences. The constant exists only
/// for the invariant test below. Source: `offline-tts-pocket-impl.h:Generate`.
#[cfg(test)]
const SHERPA_ONNX_FRAMES_AFTER_EOS_DEFAULT: i32 = 3;

// ── ONNX file names (five Pocket TTS sessions plus two JSON tables) ───────────

const FILE_LM_MAIN: &str = "lm_main.onnx";
const FILE_LM_FLOW: &str = "lm_flow.onnx";
const FILE_ENCODER: &str = "encoder.onnx";
const FILE_DECODER: &str = "decoder.onnx";
const FILE_TEXT_COND: &str = "text_conditioner.onnx";
const FILE_VOCAB: &str = "vocab.json";
const FILE_TOKEN_SCORES: &str = "token_scores.json";

// ── Voice style ───────────────────────────────────────────────────────────────

/// Loaded reference voice — normalised f32 PCM samples plus their sample rate.
///
/// Pocket TTS takes a reference waveform per generation call (not a
/// precomputed style embedding), so we keep the samples in memory and clone
/// the small `Vec` into each `GenerationConfig` rather than re-reading the
/// WAV from disk on every sentence.
#[derive(Debug, Clone)]
pub struct VoiceStyle {
    samples: Vec<f32>,
    sample_rate: i32,
}

/// Load a reference voice WAV from disk.
///
/// Accepts any sample rate sherpa-onnx's `Wave::read` can decode — Pocket TTS
/// resamples internally using `reference_sample_rate`. The bundled
/// `reference_sample.wav` ("Mary" — VCTK p333, enhanced) is 32 kHz mono.
pub fn load_voice_style(path: &Path) -> Result<VoiceStyle, String> {
    let path_str = path
        .to_str()
        .ok_or_else(|| format!("voice path is not valid UTF-8: {}", path.display()))?;
    let wave = Wave::read(path_str)
        .ok_or_else(|| format!("could not read voice WAV at {}", path.display()))?;
    let samples = wave.samples().to_vec();
    if samples.is_empty() {
        return Err(format!("voice WAV is empty: {}", path.display()));
    }
    Ok(VoiceStyle {
        samples,
        sample_rate: wave.sample_rate(),
    })
}

// ── Engine ────────────────────────────────────────────────────────────────────

/// Pocket TTS engine handle, normally kept resident by its caller.
pub struct PocketTts {
    inner: PocketTtsInner,
    model_info: Option<PocketModelInfo>,
}

enum PocketTtsInner {
    January(OfflineTts),
    April(Box<Mutex<AprilPocketTts>>),
}

/// Build a Pocket TTS engine from a caller-provided model directory.
///
/// An April `bundle.json` selects FP32 April automatically. Directories
/// without that manifest retain the source-compatible January loader.
pub fn load_text_to_speech(model_dir: &str) -> Result<PocketTts, String> {
    load_text_to_speech_with_options(model_dir, PocketLoadOptions::default())
}

/// Build a Pocket TTS engine with explicit runtime-only model options.
///
/// Application download, cache, fallback, and UI policy intentionally remain
/// outside this crate.
pub fn load_text_to_speech_with_options(
    model_dir: &str,
    options: PocketLoadOptions,
) -> Result<PocketTts, String> {
    if options.num_threads == 0 {
        return Err("Pocket TTS num_threads must be at least 1".to_string());
    }
    let dir = PathBuf::from(model_dir);
    let april_precision = match options.model {
        PocketModelSelection::Auto if dir.join("bundle.json").is_file() => {
            Some(PocketPrecision::Fp32)
        }
        PocketModelSelection::Auto => None,
        PocketModelSelection::English2026_04(precision) => Some(precision),
    };

    if let Some(precision) = april_precision {
        let info = april_model_info(precision);
        for artifact in info.artifacts {
            let path = dir.join(artifact.filename);
            if !path.is_file() {
                return Err(format!(
                    "incomplete Pocket TTS {} {:?} variant: missing {}",
                    info.bundle_id,
                    info.precision,
                    path.display()
                ));
            }
        }
        return Ok(PocketTts {
            inner: PocketTtsInner::April(Box::new(Mutex::new(AprilPocketTts::load(
                &dir,
                precision,
                options.num_threads,
            )?))),
            model_info: Some(info),
        });
    }

    for name in [
        FILE_LM_MAIN,
        FILE_LM_FLOW,
        FILE_ENCODER,
        FILE_DECODER,
        FILE_TEXT_COND,
        FILE_VOCAB,
        FILE_TOKEN_SCORES,
    ] {
        let p = dir.join(name);
        if !p.is_file() {
            return Err(format!("missing Pocket TTS file: {}", p.display()));
        }
    }

    let to_str = |name: &str| -> String { dir.join(name).to_string_lossy().into_owned() };

    // Build the config by mutating defaults — mirrors `stt.rs` and stays
    // resilient if sherpa-onnx adds unrelated model-family fields.
    let mut cfg = OfflineTtsConfig::default();
    cfg.model.pocket.lm_main = Some(to_str(FILE_LM_MAIN));
    cfg.model.pocket.lm_flow = Some(to_str(FILE_LM_FLOW));
    cfg.model.pocket.encoder = Some(to_str(FILE_ENCODER));
    cfg.model.pocket.decoder = Some(to_str(FILE_DECODER));
    cfg.model.pocket.text_conditioner = Some(to_str(FILE_TEXT_COND));
    cfg.model.pocket.vocab_json = Some(to_str(FILE_VOCAB));
    cfg.model.pocket.token_scores_json = Some(to_str(FILE_TOKEN_SCORES));
    cfg.model.pocket.voice_embedding_cache_capacity = VOICE_EMBEDDING_CACHE_CAPACITY;
    cfg.model.num_threads = i32::try_from(options.num_threads).map_err(|_| {
        format!(
            "Pocket TTS num_threads is too large: {}",
            options.num_threads
        )
    })?;
    // Explicit — defaults are not part of the API contract, and noisy debug
    // logging in release builds would be expensive on every synthesized chunk.
    cfg.model.debug = false;

    let inner = OfflineTts::create(&cfg)
        .ok_or_else(|| "OfflineTts::create returned None for Pocket TTS".to_string())?;
    Ok(PocketTts {
        inner: PocketTtsInner::January(inner),
        model_info: None,
    })
}

// ── Prompt preparation ────────────────────────────────────────────────────────

/// Result of [`prepare_pocket_prompt`]: a synthesizer-ready prompt plus the
/// per-call generation overrides derived from the original text.
///
/// `None` for either override means "leave sherpa-onnx's documented default
/// in place". The pipeline only sets `max_frames` (and only for short
/// padded inputs) so it can bound the original "monster breathing" runaway
/// without disturbing the rest of the LM sampling envelope.
#[derive(Debug, Clone, PartialEq)]
#[doc(hidden)]
pub struct PreparedPrompt {
    /// Text to hand to `OfflineTts::generate_with_config`. Capitalized,
    /// punctuation-terminated, and (for short inputs) left-padded with
    /// spaces — upstream's mitigation for the FlowLM cold-start smear.
    pub text: String,
    /// Value to pass via `GenerationConfig.extra["max_frames"]`, or `None` to
    /// keep the upstream default of 500 LM steps. We only override on short
    /// padded prompts where we have a tight expectation on output length.
    pub max_frames: Option<i32>,
}

/// Mirror of the *text-preparation* half of upstream
/// `pocket_tts.models.tts_model.prepare_text_prompt`. Sherpa-onnx's C++
/// Pocket TTS impl does not run these preparation steps, so short /
/// unpunctuated / lowercase inputs can trigger up to 40 s of runaway
/// generation when the EOS logit never crosses its threshold. We replicate
/// the upstream Python recipe here:
///
/// 1. Collapse interior whitespace (already done by `preprocess_for_tts`, but
///    cheap to re-check after sentence splitting).
/// 2. Capitalize the first letter.
/// 3. Append `.` if the text doesn't end in punctuation.
/// 4. If fewer than five words, prepend `SHORT_PROMPT_PAD_SPACES` spaces
///    (upstream's cold-start mitigation — see the constant's docstring) and
///    return a tight [`SHORT_PROMPT_MAX_FRAMES`] cap so the LM can't run
///    away if EOS still doesn't fire.
///
/// We do **not** override `frames_after_eos` — sherpa-onnx's default of 3
/// is what we want. An earlier version set it to 1 on long inputs, which
/// clipped the leading audio of multi-clause sentences ("first 'yep' is
/// just static" regression). Tests `prepare_prompt_never_lowers_frames_…`
/// lock this in.
///
/// Returns `None` only if the input is empty after trimming — caller should
/// skip synthesis in that case.
#[doc(hidden)]
pub fn prepare_pocket_prompt(input: &str) -> Option<PreparedPrompt> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }

    // Collapse stray double-spaces / embedded newlines that may slip past
    // `preprocess_for_tts` when sentences are spliced back together.
    let mut cleaned = String::with_capacity(trimmed.len());
    let mut last_was_space = false;
    for ch in trimmed.chars() {
        let is_ws = ch.is_whitespace();
        if is_ws {
            if !last_was_space {
                cleaned.push(' ');
            }
            last_was_space = true;
        } else {
            cleaned.push(ch);
            last_was_space = false;
        }
    }

    // Capitalize first character. Uses `to_uppercase` (multi-codepoint safe).
    let first = cleaned.chars().next().expect("cleaned non-empty above");
    if first.is_lowercase() {
        let upper: String = first.to_uppercase().collect();
        let mut iter = cleaned.chars();
        iter.next();
        cleaned = upper + iter.as_str();
    }

    // Ensure terminal punctuation. Anything not in `.!?;:,` gets a period.
    // The upstream Python only checks `isalnum` → period, but for our agent
    // text we already may end in `!` `?` `.` etc. — treat any of those as OK.
    let last = cleaned
        .chars()
        .next_back()
        .expect("cleaned non-empty above");
    if !matches!(last, '.' | '!' | '?' | ';' | ':' | ',') {
        cleaned.push('.');
    }

    // Word count of the *cleaned but not padded* text — padding is whitespace
    // only and would just lie to the threshold check below.
    let word_count = cleaned.split_whitespace().count();

    let (final_text, max_frames) = if word_count <= SHORT_PROMPT_WORD_THRESHOLD {
        let mut padded = String::with_capacity(cleaned.len() + SHORT_PROMPT_PAD_SPACES);
        for _ in 0..SHORT_PROMPT_PAD_SPACES {
            padded.push(' ');
        }
        padded.push_str(&cleaned);
        (padded, Some(SHORT_PROMPT_MAX_FRAMES))
    } else {
        // For everything ≥5 words, fall back to upstream defaults. Overriding
        // these is what caused the "first 'yep' is static" regression — the
        // upstream LM has been tuned for `frames_after_eos = 3` and
        // `max_frames = 500`, and there's no clear win in second-guessing.
        (cleaned, None)
    };

    Some(PreparedPrompt {
        text: final_text,
        max_frames,
    })
}

/// Build the `GenerationConfig.extra` HashMap from a [`PreparedPrompt`].
///
/// Centralised so the invariant test below can assert that we **never** emit a
/// `frames_after_eos` override. Leaving the key unset preserves sherpa-onnx's
/// upstream default of 3.
fn build_generation_extra(prepared: &PreparedPrompt) -> Option<HashMap<String, serde_json::Value>> {
    prepared.max_frames.map(|mf| {
        let mut h: HashMap<String, serde_json::Value> = HashMap::with_capacity(1);
        h.insert("max_frames".to_string(), serde_json::Value::from(mf));
        h
    })
}

impl PocketTts {
    /// Metadata for the loaded April model.
    ///
    /// January's legacy sherpa layout predates the immutable bundle contract,
    /// so it returns `None`.
    pub fn model_info(&self) -> Option<PocketModelInfo> {
        self.model_info
    }

    /// Prepare model-valid synthesis units for `text`.
    ///
    /// April splits with its bundle tokenizer and exact 50-token constraint.
    /// The legacy January loader has no equivalent public tokenizer or token
    /// limit, so it returns the prepared prompt as one synthesis unit.
    pub fn split_text_into_chunks(&self, text: &str) -> Result<Vec<String>, String> {
        match &self.inner {
            PocketTtsInner::January(_) => Ok(prepare_pocket_prompt(text)
                .map(|prepared| vec![prepared.text])
                .unwrap_or_default()),
            PocketTtsInner::April(engine) => {
                let Some(prepared) = prepare_april_prompt(text) else {
                    return Ok(Vec::new());
                };
                engine
                    .lock()
                    .map_err(|_| "Pocket TTS engine lock poisoned".to_string())?
                    .split_prompt(&prepared)
            }
        }
    }

    /// Synthesise `text` with the given reference voice.
    ///
    /// `_lang` and `_steps` are accepted for API compatibility with the
    /// previous Kokoro engine. Pocket TTS infers language from the input text
    /// directly and is a one-step consistency model. Returns an empty buffer
    /// for whitespace-only input.
    pub fn synth_chunk(
        &self,
        text: &str,
        lang: &str,
        style: &VoiceStyle,
        steps: usize,
    ) -> Result<Vec<f32>, String> {
        self.synth_chunk_with_callback(text, lang, style, steps, None::<fn(&[f32], f32) -> bool>)
    }

    /// Synthesise `text`, allowing the caller to stop generation early.
    ///
    /// The callback receives the samples generated so far and a progress
    /// value in `[0, 1]`. Return `true` to continue or `false` to cancel.
    /// Clients that do not need cancellation should use [`Self::synth_chunk`].
    pub fn synth_chunk_with_callback<F>(
        &self,
        text: &str,
        _lang: &str,
        style: &VoiceStyle,
        _steps: usize,
        mut callback: Option<F>,
    ) -> Result<Vec<f32>, String>
    where
        F: FnMut(&[f32], f32) -> bool + 'static,
    {
        match &self.inner {
            PocketTtsInner::January(engine) => {
                // Mirror January upstream prompt preparation and retain its
                // short-prompt generation bounds.
                let prepared = match prepare_pocket_prompt(text) {
                    Some(p) => p,
                    None => return Ok(Vec::new()),
                };
                let cfg = GenerationConfig {
                    num_steps: SYNTH_NUM_STEPS,
                    silence_scale: SYNTH_SILENCE_SCALE,
                    reference_audio: Some(style.samples.clone()),
                    reference_sample_rate: style.sample_rate,
                    extra: build_generation_extra(&prepared),
                    ..Default::default()
                };
                let audio = engine
                    .generate_with_config(&prepared.text, &cfg, callback)
                    .ok_or_else(|| {
                        format!(
                            "Pocket TTS synthesis failed for text ({} chars)",
                            prepared.text.len()
                        )
                    })?;
                let sample_rate = audio.sample_rate();
                if sample_rate != SAMPLE_RATE as i32 {
                    eprintln!(
                        "buzz-voice: Pocket TTS returned unexpected sample rate {sample_rate}Hz \
                         (expected {SAMPLE_RATE}Hz); playback speed may be wrong"
                    );
                }
                Ok(audio.samples().to_vec())
            }
            PocketTtsInner::April(engine) => {
                let prepared = match prepare_april_prompt(text) {
                    Some(prepared) => prepared,
                    None => return Ok(Vec::new()),
                };
                let mut engine = engine
                    .lock()
                    .map_err(|_| "Pocket TTS engine lock poisoned".to_string())?;
                let chunks = engine.split_prompt(&prepared)?;
                let chunk_count = chunks.len() as f32;
                let mut samples = Vec::new();

                for (chunk_index, chunk) in chunks.into_iter().enumerate() {
                    let prepared = prepare_april_prompt(&chunk)
                        .ok_or_else(|| "Pocket TTS prompt chunk became empty".to_string())?;
                    let (chunk_samples, cancelled) = {
                        let mut cancelled = false;
                        let mut adapted_callback =
                            |current_chunk_samples: &[f32], chunk_progress: f32| {
                                let Some(callback) = callback.as_mut() else {
                                    return true;
                                };
                                let mut cumulative =
                                    Vec::with_capacity(samples.len() + current_chunk_samples.len());
                                cumulative.extend_from_slice(&samples);
                                cumulative.extend_from_slice(current_chunk_samples);
                                let progress = (chunk_index as f32 + chunk_progress) / chunk_count;
                                let should_continue = callback(&cumulative, progress);
                                cancelled = !should_continue;
                                should_continue
                            };
                        let chunk_samples =
                            engine.synth_chunk(&prepared, style, Some(&mut adapted_callback))?;
                        (chunk_samples, cancelled)
                    };
                    if cancelled {
                        return Ok(Vec::new());
                    }
                    samples.extend(chunk_samples);
                }

                Ok(samples)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── prepare_pocket_prompt ────────────────────────────────────────────────

    #[test]
    fn prepare_prompt_returns_none_for_empty_input() {
        assert!(prepare_pocket_prompt("").is_none());
        assert!(prepare_pocket_prompt("   ").is_none());
        assert!(prepare_pocket_prompt("\n\t  ").is_none());
    }

    /// Helper: the exact leading sequence prepended to every short prompt —
    /// 8 spaces of padding (upstream's cold-start mitigation).
    /// Centralising this keeps the assertions readable.
    fn short_prefix() -> String {
        " ".repeat(SHORT_PROMPT_PAD_SPACES)
    }

    #[test]
    fn prepare_prompt_pads_and_capitalizes_one_word() {
        // The "yep" case Tyler hit in production — bare lowercase one-word
        // utterance with no punctuation. Must be padded with the short-prompt
        // space pad, capitalized, terminated, with a tight `max_frames` cap
        // to bound runaway gen.
        let out = prepare_pocket_prompt("yep").expect("non-empty");
        assert_eq!(out.text, format!("{}Yep.", short_prefix()));
        assert_eq!(out.max_frames, Some(SHORT_PROMPT_MAX_FRAMES));
        const {
            assert!(
                SHORT_PROMPT_MAX_FRAMES < SHERPA_ONNX_MAX_FRAMES_DEFAULT,
                "short cap must be tighter than the upstream default"
            );
        }
    }

    #[test]
    fn prepare_prompt_preserves_existing_punctuation() {
        let out = prepare_pocket_prompt("yes!").expect("non-empty");
        assert_eq!(out.text, format!("{}Yes!", short_prefix())); // exclamation kept
        let out = prepare_pocket_prompt("really?").expect("non-empty");
        assert_eq!(out.text, format!("{}Really?", short_prefix()));
    }

    #[test]
    fn prepare_prompt_threshold_is_inclusive_at_four_words() {
        // 4 words = short (padded + tight max_frames); 5 words = long
        // (no padding, no overrides — upstream defaults stand).
        let four = prepare_pocket_prompt("one two three four").expect("non-empty");
        assert_eq!(
            four.text,
            format!("{}One two three four.", short_prefix()),
            "four-word input should get exactly the space pad"
        );
        assert_eq!(four.max_frames, Some(SHORT_PROMPT_MAX_FRAMES));

        let five = prepare_pocket_prompt("one two three four five").expect("non-empty");
        assert!(
            !five.text.starts_with(' '),
            "five-word input should NOT be padded"
        );
        assert_eq!(
            five.max_frames, None,
            "long inputs must leave sherpa-onnx's max_frames default in place"
        );
    }

    #[test]
    fn prepare_prompt_does_not_pad_long_text() {
        let long = "This is a longer sentence that the model should handle just fine.";
        let out = prepare_pocket_prompt(long).expect("non-empty");
        assert!(!out.text.starts_with(' '));
        assert_eq!(out.max_frames, None);
        assert!(out.text.ends_with('.'));
    }

    #[test]
    fn prepare_prompt_collapses_whitespace() {
        let out = prepare_pocket_prompt("Hello    world\n\nfriend").expect("non-empty");
        // 3 words → short → padded. Interior whitespace collapsed.
        assert_eq!(out.text, format!("{}Hello world friend.", short_prefix()));
    }

    #[test]
    fn prepare_prompt_does_not_double_capitalize_already_uppercase() {
        let out = prepare_pocket_prompt("HELLO there").expect("non-empty");
        assert_eq!(out.text, format!("{}HELLO there.", short_prefix()));
    }

    #[test]
    fn prepare_prompt_handles_non_ascii_first_letter() {
        // Cyrillic lowercase 'д' → uppercase 'Д'. Must not panic / produce
        // mojibake.
        let out = prepare_pocket_prompt("дa").expect("non-empty");
        assert!(out.text.contains("Дa."));
    }

    /// REGRESSION GUARD: short prompts must receive *only* whitespace
    /// padding — no sacrificial text. A previous revision prepended a
    /// `". . "` cold-start absorber and trimmed the rendered audio back out
    /// with an amplitude threshold that could eat soft word onsets. If
    /// non-whitespace ever reappears in the pad, the synth output will
    /// contain audio for text the user never wrote.
    #[test]
    fn prepare_prompt_pad_is_whitespace_only() {
        let out = prepare_pocket_prompt("I'm happy.").expect("non-empty");
        let pad_len = out.text.len() - "I'm happy.".len();
        assert!(
            out.text[..pad_len].chars().all(|c| c == ' '),
            "short-prompt pad must be spaces only, got {:?}",
            &out.text[..pad_len]
        );
        assert_eq!(out.text, format!("{}I'm happy.", short_prefix()));
    }

    // ── build_generation_extra ───────────────────────────────────────────────
    //
    // Short prompts override only `max_frames`; long prompts emit no extras.
    // Every other knob remains at sherpa-onnx's documented default, notably
    // `frames_after_eos = 3`.

    #[test]
    fn build_extra_short_prompt_sets_only_max_frames() {
        let prepared = prepare_pocket_prompt("yep").expect("non-empty");
        let extra = build_generation_extra(&prepared).expect("short prompts get extra");
        // Exactly one key — `max_frames` — and nothing else.
        assert_eq!(extra.len(), 1, "extra has unexpected keys: {extra:?}");
        assert_eq!(
            extra.get("max_frames"),
            Some(&serde_json::Value::from(SHORT_PROMPT_MAX_FRAMES))
        );
        assert!(
            !extra.contains_key("frames_after_eos"),
            "frames_after_eos must never be set — upstream default of {SHERPA_ONNX_FRAMES_AFTER_EOS_DEFAULT} is what we want"
        );
    }

    #[test]
    fn build_extra_long_prompt_is_none() {
        // ≥5 words: no extras, so the upstream LM defaults remain authoritative.
        let prepared = prepare_pocket_prompt("Yep, I can hear you.").expect("non-empty");
        assert_eq!(
            build_generation_extra(&prepared),
            None,
            "long prompts must not override any LM knob"
        );
    }

    #[test]
    fn build_extra_never_lowers_frames_after_eos_for_any_word_count() {
        // Sweep a range of prompt lengths and assert the `extra` map (when
        // present) never carries a `frames_after_eos` override that's lower
        // than the upstream sherpa-onnx default. Implemented as a structural
        // check — we just never set the key — but worth a property test in
        // case someone reintroduces the override in the future.
        let prompts: &[&str] = &[
            "hi",
            "hi there",
            "yes please",
            "one two three four",
            "one two three four five",
            "a slightly longer reply, hopefully fine",
            "This is a multi-clause sentence. It has two parts.",
            "really really really really really long prompt with lots of words just to be sure",
        ];
        for &p in prompts {
            let prepared = prepare_pocket_prompt(p).expect("non-empty");
            if let Some(extra) = build_generation_extra(&prepared) {
                if let Some(v) = extra.get("frames_after_eos") {
                    let n = v.as_i64().expect("frames_after_eos should be int");
                    assert!(
                        n >= SHERPA_ONNX_FRAMES_AFTER_EOS_DEFAULT as i64,
                        "prompt {p:?} set frames_after_eos={n}, below upstream default of {SHERPA_ONNX_FRAMES_AFTER_EOS_DEFAULT}"
                    );
                }
            }
        }
    }

    #[test]
    fn short_prompt_max_frames_is_below_upstream_default() {
        // Sanity: the override only ever *lowers* the cap, never raises it.
        const {
            assert!(SHORT_PROMPT_MAX_FRAMES < SHERPA_ONNX_MAX_FRAMES_DEFAULT);
        }
        // …and is still large enough for a one-to-four-word reply. At Mimi's
        // 12.5 Hz frame rate, 100 frames = 8 s, which is roomy.
        const {
            assert!(SHORT_PROMPT_MAX_FRAMES >= 50, "would risk truncation");
        }
    }

    #[test]
    fn explicit_april_variant_reports_first_missing_artifact() {
        let dir =
            std::env::temp_dir().join(format!("buzz-pocket-incomplete-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create incomplete model dir");

        let error = load_text_to_speech_with_options(
            dir.to_str().expect("UTF-8 temp path"),
            PocketLoadOptions {
                model: PocketModelSelection::English2026_04(PocketPrecision::Int8),
                num_threads: 1,
            },
        )
        .err()
        .expect("incomplete variant should fail");

        assert!(error.contains("incomplete Pocket TTS english_2026-04 Int8 variant"));
        assert!(error.contains("bundle.json"));
        std::fs::remove_dir_all(dir).expect("remove incomplete model dir");
    }

    #[test]
    #[ignore = "requires BUZZ_POCKET_TEST_MODEL_DIR"]
    fn april_callback_can_cancel_before_model_inference() {
        let dir = std::env::var("BUZZ_POCKET_TEST_MODEL_DIR")
            .expect("set BUZZ_POCKET_TEST_MODEL_DIR to the verified April bundle");
        let engine = load_text_to_speech_with_options(
            &dir,
            PocketLoadOptions {
                model: PocketModelSelection::English2026_04(PocketPrecision::Fp32),
                num_threads: 1,
            },
        )
        .expect("load April FP32 bundle");
        let voice =
            load_voice_style(&Path::new(&dir).join(format!("{DEFAULT_VOICE}.{VOICE_FILE_EXT}")))
                .expect("load reference voice");

        let samples = engine
            .synth_chunk_with_callback(
                "Cancel before inference.",
                "en",
                &voice,
                1,
                Some(|_samples: &[f32], _progress: f32| false),
            )
            .expect("cancel synthesis");
        assert!(samples.is_empty());
    }

    #[test]
    #[ignore = "requires BUZZ_POCKET_TEST_MODEL_DIR with FP32 and INT8 artifacts"]
    fn april_precisions_synthesize_non_silent_audio() {
        let dir = std::env::var("BUZZ_POCKET_TEST_MODEL_DIR")
            .expect("set BUZZ_POCKET_TEST_MODEL_DIR to the verified April bundle");
        let voice =
            load_voice_style(&Path::new(&dir).join(format!("{DEFAULT_VOICE}.{VOICE_FILE_EXT}")))
                .expect("load reference voice");

        for precision in [PocketPrecision::Fp32, PocketPrecision::Int8] {
            let engine = load_text_to_speech_with_options(
                &dir,
                PocketLoadOptions {
                    model: PocketModelSelection::English2026_04(precision),
                    num_threads: 1,
                },
            )
            .expect("load April precision");
            assert_eq!(
                engine.model_info().expect("April model info").precision,
                precision
            );
            let samples = engine
                .synth_chunk("Hello there.", "en", &voice, 1)
                .expect("synthesize April precision");
            assert!(!samples.is_empty(), "{precision:?} returned no samples");
            assert!(
                samples.iter().any(|sample| sample.abs() > 1e-5),
                "{precision:?} returned digital silence"
            );
        }
    }

    #[test]
    #[ignore = "requires BUZZ_POCKET_TEST_MODEL_DIR"]
    fn april_public_synthesis_handles_text_over_token_limit() {
        let dir = std::env::var("BUZZ_POCKET_TEST_MODEL_DIR")
            .expect("set BUZZ_POCKET_TEST_MODEL_DIR to the verified April bundle");
        let engine = load_text_to_speech_with_options(
            &dir,
            PocketLoadOptions {
                model: PocketModelSelection::English2026_04(PocketPrecision::Fp32),
                num_threads: 1,
            },
        )
        .expect("load April FP32 bundle");
        let voice =
            load_voice_style(&Path::new(&dir).join(format!("{DEFAULT_VOICE}.{VOICE_FILE_EXT}")))
                .expect("load reference voice");
        let text = "This deliberately long passage crosses the model token boundary while using \
                    the public synthesis method directly. It verifies that callers receive one \
                    continuous sample buffer without needing to duplicate the model tokenizer or \
                    understand its exact token budget. The runtime must split the prompt safely, \
                    synthesize every piece, and preserve compatibility with existing callers.";

        let chunks = engine
            .split_text_into_chunks(text)
            .expect("split long April prompt");
        assert!(chunks.len() > 1, "test text must exceed one model chunk");

        let samples = engine
            .synth_chunk(text, "en", &voice, 1)
            .expect("synthesize long April prompt");
        assert!(!samples.is_empty());
        assert!(samples.iter().any(|sample| sample.abs() > 1e-5));
    }

    #[test]
    #[ignore = "requires BUZZ_POCKET_JANUARY_TEST_MODEL_DIR"]
    fn january_auto_detection_remains_source_compatible() {
        let dir = std::env::var("BUZZ_POCKET_JANUARY_TEST_MODEL_DIR")
            .expect("set BUZZ_POCKET_JANUARY_TEST_MODEL_DIR to a January bundle");
        let engine = load_text_to_speech(&dir).expect("auto-load January bundle");
        assert!(engine.model_info().is_none());
        let voice =
            load_voice_style(&Path::new(&dir).join(format!("{DEFAULT_VOICE}.{VOICE_FILE_EXT}")))
                .expect("load January reference voice");
        let samples = engine
            .synth_chunk("Hello there.", "en", &voice, 1)
            .expect("synthesize January bundle");
        assert!(!samples.is_empty());
        assert!(samples.iter().any(|sample| sample.abs() > 1e-5));
    }
}
