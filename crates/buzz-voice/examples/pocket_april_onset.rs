//! Generate one raw, untrimmed April Pocket TTS onset-stress clip.
//!
//! Each sentence is a separate synthesis call, making every sentence start an
//! explicit model-generation boundary. Outputs are concatenated without fades,
//! trimming, normalization, or gain; only 250 ms of digital silence is inserted
//! between calls so boundaries are easy to identify while listening.
//!
//! Usage:
//!   cargo run --release -p buzz-voice --example pocket_april_onset -- \
//!     <model-dir> <output.wav> [fp32|int8]

use std::path::PathBuf;

use buzz_voice::pocket::{
    load_text_to_speech_with_options, load_voice_style, PocketLoadOptions, PocketModelSelection,
    PocketPrecision, DEFAULT_VOICE, SAMPLE_RATE, VOICE_FILE_EXT,
};

const PASSAGE: &[&str] = &[
    "Yep.",
    "Hello there.",
    "What happened?",
    "Try this now.",
    "Please check again.",
    "Start with the smallest change.",
    "I'm listening.",
    "I've got it.",
    "Sounds good to me.",
];

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let model_dir = PathBuf::from(args.next().ok_or("missing model directory argument")?);
    let output = PathBuf::from(args.next().ok_or("missing output WAV argument")?);
    let precision = match args.next().as_deref() {
        None | Some("fp32") => PocketPrecision::Fp32,
        Some("int8") => PocketPrecision::Int8,
        Some(value) => return Err(format!("unsupported precision {value:?}; use fp32 or int8")),
    };
    if args.next().is_some() {
        return Err("unexpected extra argument".to_string());
    }

    let engine = load_text_to_speech_with_options(
        model_dir
            .to_str()
            .ok_or_else(|| format!("model path is not UTF-8: {}", model_dir.display()))?,
        PocketLoadOptions {
            model: PocketModelSelection::English2026_04(precision),
            num_threads: 1,
        },
    )?;
    eprintln!("precision: {precision:?}");
    let voice_path = model_dir.join(format!("{DEFAULT_VOICE}.{VOICE_FILE_EXT}"));
    let voice = load_voice_style(&voice_path)?;
    let boundary_silence = vec![0.0_f32; SAMPLE_RATE as usize / 4];
    let mut combined = Vec::new();

    for (index, text) in PASSAGE.iter().enumerate() {
        eprintln!("boundary {}: {text}", index + 1);
        let samples = engine.synth_chunk(text, "en", &voice, 1)?;
        eprintln!(
            "  raw samples: {} ({:.3} s)",
            samples.len(),
            samples.len() as f32 / SAMPLE_RATE as f32
        );
        combined.extend_from_slice(&samples);
        if index + 1 != PASSAGE.len() {
            combined.extend_from_slice(&boundary_silence);
        }
    }

    let output_str = output
        .to_str()
        .ok_or_else(|| format!("output path is not UTF-8: {}", output.display()))?;
    if !sherpa_onnx::write(output_str, &combined, SAMPLE_RATE as i32) {
        return Err(format!("could not write {}", output.display()));
    }
    eprintln!(
        "wrote {} raw samples ({:.3} s) to {}",
        combined.len(),
        combined.len() as f32 / SAMPLE_RATE as f32,
        output.display()
    );
    Ok(())
}
