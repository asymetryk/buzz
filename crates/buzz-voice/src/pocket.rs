//! Pocket TTS engine for Kyutai's `english_2026-04` bundle.
//!
//! Pocket TTS is a compact zero-shot voice-cloning model from Kyutai. Buzz
//! uses the full-precision April ONNX export and implements its SentencePiece,
//! learned-BOS, and recurrent-state frontend on top of the ONNX Runtime already
//! linked by sherpa-onnx.
//!
//! ## Attribution
//!
//! - **Model**: Kyutai *Pocket TTS* — Charles, Roebel, et al., 2026.
//!   arXiv:2509.06926. Original repository: <https://huggingface.co/kyutai/pocket-tts>.
//!   Licensed CC-BY-4.0.
//! - **Mimi neural codec**: Kyutai, bundled in the same release. CC-BY-4.0.
//! - **ONNX export**: KevinAHM —
//!   <https://huggingface.co/KevinAHM/pocket-tts-onnx>. CC-BY-4.0.
//! - **Reference voice WAV** (`reference_sample.wav`): the "Mary
//!   (f, conversation)" preset from the Kyutai TTS demo
//!   (<https://kyutai.org/tts>), which maps to `vctk/p333_023_enhanced.wav`
//!   in <https://huggingface.co/kyutai/tts-voices>. CC-BY-4.0, base recording
//!   from the VCTK corpus, enhanced by ai-coustics.
//!
//! Buzz ships these files unmodified; see the on-disk `MODEL_LICENSE.txt`
//! sidecar written by `huddle::models` during install for the canonical
//! CC-BY-4.0 §3(a)(1) attribution block.
//!
//! ## Engine-module contract (see `huddle::tts`)
//!
//! `pocket.rs` exposes a fixed surface used by `tts.rs`. Mirroring this
//! contract is what lets the TTS pipeline stay engine-agnostic:
//!
//! - `SAMPLE_RATE: u32`             — engine output sample rate in Hz.
//! - `DEFAULT_VOICE: &str`          — default voice name (without extension).
//! - `VOICE_FILE_EXT: &str`         — extension for per-voice files on disk.
//! - `load_text_to_speech(model_dir)`              → `Result<Engine, String>`
//! - `load_voice_style(path)`                      → `Result<VoiceStyle, String>`
//! - `Engine::synth_chunk(&self, text, lang, &VoiceStyle, steps)`
//!   → `Result<Vec<f32>, String>`
//!
//! `lang` and `steps` are accepted for compatibility with the shared engine
//! contract but are unused: this bundle is English-only and uses one flow step.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use sherpa_onnx::Wave;

#[path = "pocket_april.rs"]
mod pocket_april;
use pocket_april::AprilPocketTts;

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

/// Pocket TTS engine handle, owned by the TTS worker for a huddle session.
pub struct PocketTts {
    inner: Mutex<AprilPocketTts>,
}

/// Build the April Pocket TTS engine from the directory installed by
/// `huddle::models`.
pub fn load_text_to_speech(model_dir: &str) -> Result<PocketTts, String> {
    let dir = PathBuf::from(model_dir);
    Ok(PocketTts {
        inner: Mutex::new(AprilPocketTts::load(&dir)?),
    })
}

// ── Prompt preparation ────────────────────────────────────────────────────────

/// Result of [`prepare_pocket_prompt`].
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct PreparedPrompt {
    /// Capitalized, whitespace-normalized, punctuation-terminated text.
    pub text: String,
    /// April's upstream heuristic is 3+2 frames for ≤4 words and 1+2 otherwise.
    pub frames_after_eos: usize,
}

/// Mirror the April bundle's upstream text preparation:
///
/// 1. Collapse interior whitespace (already done by `preprocess_for_tts`, but
///    cheap to re-check after sentence splitting).
/// 2. Capitalize the first letter.
/// 3. Append `.` when the last character is alphanumeric.
/// 4. Use the model's word-count-based post-EOS frame heuristic.
///
/// The bundle disables short-input space padding; prompts must stay unpadded
/// so phrase starts match the model's expected input distribution.
///
/// Returns `None` only if the input is empty after trimming — caller should
/// skip synthesis in that case.
pub(crate) fn prepare_pocket_prompt(input: &str) -> Option<PreparedPrompt> {
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
    if last.is_alphanumeric() {
        cleaned.push('.');
    }

    let word_count = cleaned.split_whitespace().count();

    Some(PreparedPrompt {
        text: cleaned,
        frames_after_eos: if word_count <= 4 { 5 } else { 3 },
    })
}

impl PocketTts {
    /// Split text at word boundaries using the April bundle's exact tokenizer
    /// limit. Callers should treat every returned item as an independent
    /// playback chunk so cancellation and boundary processing remain visible.
    pub fn split_text_into_chunks(&self, text: &str) -> Result<Vec<String>, String> {
        let prepared = match prepare_pocket_prompt(text) {
            Some(p) => p,
            None => return Ok(Vec::new()),
        };

        self.inner
            .lock()
            .map_err(|_| "Pocket TTS engine lock poisoned".to_string())?
            .split_prompt(&prepared)
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
        _lang: &str,
        style: &VoiceStyle,
        _steps: usize,
    ) -> Result<Vec<f32>, String> {
        // Mirror the April bundle's prompt normalization and EOS policy.
        let prepared = match prepare_pocket_prompt(text) {
            Some(p) => p,
            None => return Ok(Vec::new()),
        };

        self.inner
            .lock()
            .map_err(|_| "Pocket TTS engine lock poisoned".to_string())?
            .synth_chunk(&prepared, style)
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

    #[test]
    fn prepare_prompt_capitalizes_one_word_without_january_padding() {
        let out = prepare_pocket_prompt("yep").expect("non-empty");
        assert_eq!(out.text, "Yep.");
        assert_eq!(out.frames_after_eos, 5);
    }

    #[test]
    fn prepare_prompt_preserves_existing_punctuation() {
        let out = prepare_pocket_prompt("yes!").expect("non-empty");
        assert_eq!(out.text, "Yes!");
        let out = prepare_pocket_prompt("really?").expect("non-empty");
        assert_eq!(out.text, "Really?");
    }

    #[test]
    fn prepare_prompt_threshold_is_inclusive_at_four_words() {
        // Only the post-EOS heuristic changes at the four-word boundary.
        let four = prepare_pocket_prompt("one two three four").expect("non-empty");
        assert_eq!(four.text, "One two three four.");
        assert_eq!(four.frames_after_eos, 5);

        let five = prepare_pocket_prompt("one two three four five").expect("non-empty");
        assert_eq!(five.text, "One two three four five.");
        assert_eq!(five.frames_after_eos, 3);
    }

    #[test]
    fn prepare_prompt_does_not_pad_long_text() {
        let long = "This is a longer sentence that the model should handle just fine.";
        let out = prepare_pocket_prompt(long).expect("non-empty");
        assert!(!out.text.starts_with(' '));
        assert_eq!(out.frames_after_eos, 3);
        assert!(out.text.ends_with('.'));
    }

    #[test]
    fn prepare_prompt_collapses_whitespace() {
        let out = prepare_pocket_prompt("Hello    world\n\nfriend").expect("non-empty");
        assert_eq!(out.text, "Hello world friend.");
    }

    #[test]
    fn prepare_prompt_does_not_double_capitalize_already_uppercase() {
        let out = prepare_pocket_prompt("HELLO there").expect("non-empty");
        assert_eq!(out.text, "HELLO there.");
    }

    #[test]
    fn prepare_prompt_handles_non_ascii_first_letter() {
        // Cyrillic lowercase 'д' → uppercase 'Д'. Must not panic / produce
        // mojibake.
        let out = prepare_pocket_prompt("дa").expect("non-empty");
        assert!(out.text.contains("Дa."));
    }

    #[test]
    fn prepare_prompt_does_not_add_an_onset_prefix() {
        let out = prepare_pocket_prompt("I'm happy.").expect("non-empty");
        assert_eq!(out.text, "I'm happy.");
    }
}
