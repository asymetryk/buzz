//! Minimal C ABI for running [`buzz_voice::pocket`] on mobile.

#![deny(unsafe_op_in_unsafe_fn)]

use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use buzz_voice::pocket::{
    load_text_to_speech, load_voice_style, PocketTts, VoiceStyle, DEFAULT_VOICE, SAMPLE_RATE,
    VOICE_FILE_EXT,
};

struct Engine {
    tts: PocketTts,
    voice: VoiceStyle,
    cancelled: Arc<AtomicBool>,
}

/// Result returned by [`buzz_voice_engine_create`].
#[repr(C)]
pub struct BuzzVoiceEngineResult {
    /// Opaque engine handle, or null when creation failed.
    pub engine: *mut c_void,
    /// Owned UTF-8 error string, or null on success.
    pub error: *mut c_char,
}

/// Owned 24 kHz mono signed-16-bit PCM returned by
/// [`buzz_voice_engine_synthesize`].
#[repr(C)]
pub struct BuzzVoicePcm {
    /// Owned sample buffer, or null when synthesis failed.
    pub samples: *mut i16,
    /// Number of samples in `samples`.
    pub len: usize,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Owned UTF-8 error string, or null on success.
    pub error: *mut c_char,
}

fn owned_error(message: impl Into<String>) -> *mut c_char {
    let message = message.into().replace('\0', " ");
    CString::new(message)
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

fn engine_error(message: impl Into<String>) -> BuzzVoiceEngineResult {
    BuzzVoiceEngineResult {
        engine: ptr::null_mut(),
        error: owned_error(message),
    }
}

fn pcm_error(message: impl Into<String>) -> BuzzVoicePcm {
    BuzzVoicePcm {
        samples: ptr::null_mut(),
        len: 0,
        sample_rate: SAMPLE_RATE,
        error: owned_error(message),
    }
}

fn input_string(value: *const c_char, label: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("{label} is null"));
    }
    // SAFETY: The C ABI requires a non-null, NUL-terminated string that stays
    // alive for the duration of this call. We copy it before returning.
    let value = unsafe { CStr::from_ptr(value) };
    value
        .to_str()
        .map(str::to_owned)
        .map_err(|error| format!("{label} is not UTF-8: {error}"))
}

/// Create and retain one Pocket engine and its reference voice.
#[no_mangle]
pub extern "C" fn buzz_voice_engine_create(model_dir: *const c_char) -> BuzzVoiceEngineResult {
    let model_dir = match input_string(model_dir, "model_dir") {
        Ok(value) => value,
        Err(error) => return engine_error(error),
    };
    let voice_path = std::path::Path::new(&model_dir)
        .join(DEFAULT_VOICE)
        .with_extension(VOICE_FILE_EXT);
    let tts = match load_text_to_speech(&model_dir) {
        Ok(value) => value,
        Err(error) => return engine_error(error),
    };
    let voice = match load_voice_style(&voice_path) {
        Ok(value) => value,
        Err(error) => return engine_error(error),
    };
    let engine = Box::new(Engine {
        tts,
        voice,
        cancelled: Arc::new(AtomicBool::new(false)),
    });
    BuzzVoiceEngineResult {
        engine: Box::into_raw(engine).cast(),
        error: ptr::null_mut(),
    }
}

/// Synthesize one utterance into owned signed-16-bit PCM.
#[no_mangle]
pub extern "C" fn buzz_voice_engine_synthesize(
    engine: *mut c_void,
    text: *const c_char,
) -> BuzzVoicePcm {
    if engine.is_null() {
        return pcm_error("engine is null");
    }
    let text = match input_string(text, "text") {
        Ok(value) => value,
        Err(error) => return pcm_error(error),
    };
    // SAFETY: A handle returned by `buzz_voice_engine_create` remains owned by
    // the caller until `buzz_voice_engine_destroy`; synthesis and destroy must
    // not overlap. Cancellation only touches the atomic flag.
    let engine = unsafe { &*(engine.cast::<Engine>()) };
    engine.cancelled.store(false, Ordering::Release);
    let cancelled = Arc::clone(&engine.cancelled);
    let samples = match engine
        .tts
        .synth_chunk_with_callback(
            &text,
            "en",
            &engine.voice,
            1,
            Some(move |_: &[f32], _| !cancelled.load(Ordering::Acquire)),
        ) {
        Ok(value) => value,
        Err(error) => return pcm_error(error),
    };
    if engine.cancelled.load(Ordering::Acquire) {
        return pcm_error("synthesis cancelled");
    }

    let samples: Box<[i16]> = samples
        .into_iter()
        .map(|sample| {
            let sample = if sample.is_finite() { sample } else { 0.0 };
            (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
        })
        .collect::<Vec<_>>()
        .into_boxed_slice();
    let len = samples.len();
    BuzzVoicePcm {
        samples: Box::into_raw(samples).cast::<i16>(),
        len,
        sample_rate: SAMPLE_RATE,
        error: ptr::null_mut(),
    }
}

/// Request cancellation of the current synthesis call.
#[no_mangle]
pub extern "C" fn buzz_voice_engine_cancel(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    // SAFETY: See `buzz_voice_engine_synthesize`. The engine remains alive
    // while this atomic cancellation request is issued.
    let engine = unsafe { &*(engine.cast::<Engine>()) };
    engine.cancelled.store(true, Ordering::Release);
}

/// Destroy an engine after any synthesis call has returned.
#[no_mangle]
pub extern "C" fn buzz_voice_engine_destroy(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    // SAFETY: The pointer came from `Box::into_raw` in create and is consumed
    // exactly once by this function.
    unsafe { drop(Box::from_raw(engine.cast::<Engine>())) };
}

/// Release a PCM value returned by [`buzz_voice_engine_synthesize`].
#[no_mangle]
pub extern "C" fn buzz_voice_pcm_free(pcm: BuzzVoicePcm) {
    if !pcm.samples.is_null() {
        // SAFETY: The allocation came from `Box<[i16]>` in synthesis and is
        // consumed exactly once here with the same slice length.
        let slice = ptr::slice_from_raw_parts_mut(pcm.samples, pcm.len);
        unsafe { drop(Box::from_raw(slice)) };
    }
    buzz_voice_string_free(pcm.error);
}

/// Release an error string returned by this ABI.
#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn buzz_voice_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    // SAFETY: Error pointers are produced by `CString::into_raw` and consumed
    // exactly once here.
    unsafe { drop(CString::from_raw(value)) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_inputs_return_owned_errors() {
        let engine = buzz_voice_engine_create(ptr::null());
        assert!(engine.engine.is_null());
        assert!(!engine.error.is_null());
        buzz_voice_string_free(engine.error);

        let pcm = buzz_voice_engine_synthesize(ptr::null_mut(), ptr::null());
        assert!(pcm.samples.is_null());
        assert_eq!(pcm.len, 0);
        assert_eq!(pcm.sample_rate, SAMPLE_RATE);
        assert!(!pcm.error.is_null());
        buzz_voice_pcm_free(pcm);
    }
}
