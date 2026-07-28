//! Immutable Pocket TTS model capabilities.
//!
//! This module describes caller-provided model files. Download URLs, cache
//! layout, installation, fallback policy, and user-facing selection remain the
//! responsibility of each application.

/// Pinned upstream export repository for the April model.
pub const APRIL_MODEL_ID: &str = "KevinAHM/pocket-tts-onnx";

/// Pinned upstream revision containing the `english_2026-04` bundle.
pub const APRIL_MODEL_REVISION: &str = "58a6d00cf13d239b6748cb0769f35c580a8f606c";

/// Language bundle selected from the pinned export.
pub const APRIL_BUNDLE_ID: &str = "english_2026-04";

/// Maximum prompt size declared by the April bundle.
pub const APRIL_MAX_TOKEN_PER_CHUNK: usize = 50;

/// ONNX precision supported by the April runtime.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PocketPrecision {
    /// All five selected ONNX graphs use full-precision weights.
    Fp32 = 0,
    /// FlowLM main, FlowLM flow, and Mimi decoder use upstream INT8 graphs.
    ///
    /// The pinned upstream runtime keeps Mimi encoder and text conditioner in
    /// full precision for this mode.
    Int8 = 1,
}

/// Model selection for a Pocket TTS engine.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PocketModelSelection {
    /// Detect April from `bundle.json`; otherwise retain the January loader.
    #[default]
    Auto,
    /// Load the pinned April bundle with an explicit precision.
    English2026_04(PocketPrecision),
}

/// Runtime configuration independent of application acquisition policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PocketLoadOptions {
    /// Model generation and precision to load.
    pub model: PocketModelSelection,
    /// ONNX Runtime intra-op thread count.
    pub num_threads: usize,
}

impl Default for PocketLoadOptions {
    fn default() -> Self {
        Self {
            model: PocketModelSelection::Auto,
            // A conservative default avoids imposing a desktop-tuned policy on
            // mobile callers. Applications may opt into a measured value.
            num_threads: 1,
        }
    }
}

/// One immutable artifact required by a model precision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PocketModelArtifact {
    pub filename: &'static str,
    pub sha256: &'static str,
    pub size_bytes: u64,
    pub quantized: bool,
}

/// Capabilities of the effective runtime model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PocketModelInfo {
    pub bundle_id: &'static str,
    pub source_model_id: &'static str,
    pub revision: Option<&'static str>,
    pub precision: PocketPrecision,
    pub sample_rate: u32,
    pub max_token_per_chunk: Option<usize>,
    pub artifacts: &'static [PocketModelArtifact],
    pub quantized_components: &'static [&'static str],
}

const COMMON_ARTIFACTS: [PocketModelArtifact; 3] = [
    PocketModelArtifact {
        filename: "bundle.json",
        sha256: "bab643150f437f37df080a710520ff39ed9ebd9a339f8ebdc739f7eddfc28b3f",
        size_bytes: 24_381,
        quantized: false,
    },
    PocketModelArtifact {
        filename: "bos_before_voice.npy",
        sha256: "f46edf4f7007b7ba4ea58831f49d003e59e167b4641c44bb3addfe9231a780b1",
        size_bytes: 4_224,
        quantized: false,
    },
    PocketModelArtifact {
        filename: "tokenizer.model",
        sha256: "d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6",
        size_bytes: 59_339,
        quantized: false,
    },
];

const FP32_ARTIFACTS: [PocketModelArtifact; 8] = [
    COMMON_ARTIFACTS[0],
    COMMON_ARTIFACTS[1],
    COMMON_ARTIFACTS[2],
    PocketModelArtifact {
        filename: "flow_lm_main.onnx",
        sha256: "6d18315e2c33ca3e3aa4a4e3dca22f56d007fd823127e24948b37695bf54190f",
        size_bytes: 302_742_149,
        quantized: false,
    },
    PocketModelArtifact {
        filename: "flow_lm_flow.onnx",
        sha256: "085d239f68897e28fb06e95c743738ad8b8c092ee6dc55f5491313e81ff08062",
        size_bytes: 39_097_095,
        quantized: false,
    },
    PocketModelArtifact {
        filename: "mimi_decoder.onnx",
        sha256: "86f038caa02a96a0ff9c25526a0ff43a4906c418197ed72d3e30f720ac7ce802",
        size_bytes: 41_471_926,
        quantized: false,
    },
    PocketModelArtifact {
        filename: "mimi_encoder.onnx",
        sha256: "853e2ca623b8782d94c3745ec6133bfdff7ce33d9b11128bd29ea03f28d76e3d",
        size_bytes: 39_768_446,
        quantized: false,
    },
    PocketModelArtifact {
        filename: "text_conditioner.onnx",
        sha256: "4ecee995fb69f85c7a7493d11f7b5ee15d9950facc7ab3f5c9c49ef1e03847bb",
        size_bytes: 16_388_344,
        quantized: false,
    },
];

const INT8_ARTIFACTS: [PocketModelArtifact; 8] = [
    COMMON_ARTIFACTS[0],
    COMMON_ARTIFACTS[1],
    COMMON_ARTIFACTS[2],
    PocketModelArtifact {
        filename: "flow_lm_main_int8.onnx",
        sha256: "f9bd8106b79a0192c1c43399ab938fb24900a95c1c599870d75a884e99000116",
        size_bytes: 76_341_079,
        quantized: true,
    },
    PocketModelArtifact {
        filename: "flow_lm_flow_int8.onnx",
        sha256: "3dd781ee5abee9e195320bf0106bebd6372a852b3b36352524ee78b40554635d",
        size_bytes: 9_962_530,
        quantized: true,
    },
    PocketModelArtifact {
        filename: "mimi_decoder_int8.onnx",
        sha256: "3630450a3297a101792a6ac66619ebc70ab916b265e6220c2afaef8b1673f925",
        size_bytes: 22_684_077,
        quantized: true,
    },
    // The pinned upstream precision selector intentionally retains these two
    // full-precision graphs even though additional INT8 exports exist.
    FP32_ARTIFACTS[6],
    FP32_ARTIFACTS[7],
];

const INT8_COMPONENTS: [&str; 3] = ["flow_lm_main", "flow_lm_flow", "mimi_decoder"];

/// Return immutable metadata for an April precision.
pub const fn april_model_info(precision: PocketPrecision) -> PocketModelInfo {
    let (artifacts, quantized_components): (
        &'static [PocketModelArtifact],
        &'static [&'static str],
    ) = match precision {
        PocketPrecision::Fp32 => (&FP32_ARTIFACTS, &[]),
        PocketPrecision::Int8 => (&INT8_ARTIFACTS, &INT8_COMPONENTS),
    };

    PocketModelInfo {
        bundle_id: APRIL_BUNDLE_ID,
        source_model_id: APRIL_MODEL_ID,
        revision: Some(APRIL_MODEL_REVISION),
        precision,
        sample_rate: 24_000,
        max_token_per_chunk: Some(APRIL_MAX_TOKEN_PER_CHUNK),
        artifacts,
        quantized_components,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn precision_metadata_matches_pinned_upstream_layout() {
        let fp32 = april_model_info(PocketPrecision::Fp32);
        let int8 = april_model_info(PocketPrecision::Int8);

        assert_eq!(fp32.artifacts.len(), 8);
        assert_eq!(int8.artifacts.len(), 8);
        assert_eq!(
            int8.quantized_components,
            ["flow_lm_main", "flow_lm_flow", "mimi_decoder"]
        );
        assert!(int8
            .artifacts
            .iter()
            .any(|artifact| artifact.filename == "mimi_encoder.onnx" && !artifact.quantized));
        assert!(!int8
            .artifacts
            .iter()
            .any(|artifact| artifact.filename == "mimi_encoder_int8.onnx"));
        assert_eq!(
            fp32.artifacts
                .iter()
                .map(|artifact| artifact.size_bytes)
                .sum::<u64>(),
            439_555_904
        );
        assert_eq!(
            int8.artifacts
                .iter()
                .map(|artifact| artifact.size_bytes)
                .sum::<u64>(),
            165_232_420
        );
    }
}
