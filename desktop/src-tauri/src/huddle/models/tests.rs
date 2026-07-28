use super::*;

#[test]
fn tts_readiness_requires_license_sidecar() {
    let temp = tempfile::tempdir().expect("tempdir");
    let slot = ModelSlot::new(TTS_MODEL_DIR_NAME, TTS_EXPECTED_FILES, TTS_MODEL_VERSION);
    let model_dir = temp.path().join(TTS_MODEL_DIR_NAME);
    std::fs::create_dir_all(&model_dir).expect("create model dir");

    for file in TTS_EXPECTED_FILES {
        std::fs::write(model_dir.join(file), b"test").expect("write expected file");
    }
    std::fs::write(model_dir.join(MANIFEST_FILENAME), TTS_MODEL_VERSION).expect("manifest");

    assert!(slot.is_ready(temp.path()));

    std::fs::remove_file(model_dir.join(TTS_LICENSE_FILE_NAME)).expect("remove sidecar");
    assert!(!slot.is_ready(temp.path()));
}

#[test]
fn interrupted_install_restores_previous_model_directory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let slot = ModelSlot::new(TTS_MODEL_DIR_NAME, TTS_EXPECTED_FILES, TTS_MODEL_VERSION);
    let backup_dir = temp.path().join("pocket-tts.old");
    std::fs::create_dir_all(&backup_dir).expect("create backup");
    std::fs::write(backup_dir.join("sentinel"), b"january").expect("write sentinel");

    slot.recover_interrupted_install(temp.path());

    assert_eq!(
        std::fs::read(temp.path().join(TTS_MODEL_DIR_NAME).join("sentinel"))
            .expect("restored sentinel"),
        b"january"
    );
    assert!(!backup_dir.exists());
}

#[test]
fn interrupted_install_replaces_incomplete_destination_with_backup() {
    let temp = tempfile::tempdir().expect("tempdir");
    let slot = ModelSlot::new(TTS_MODEL_DIR_NAME, TTS_EXPECTED_FILES, TTS_MODEL_VERSION);
    let model_dir = temp.path().join(TTS_MODEL_DIR_NAME);
    let backup_dir = temp.path().join("pocket-tts.old");
    std::fs::create_dir_all(&model_dir).expect("create incomplete destination");
    std::fs::write(model_dir.join("incomplete"), b"april").expect("write incomplete file");
    std::fs::create_dir_all(&backup_dir).expect("create backup");
    std::fs::write(backup_dir.join("sentinel"), b"january").expect("write sentinel");

    slot.recover_interrupted_install(temp.path());

    assert_eq!(
        std::fs::read(model_dir.join("sentinel")).expect("restored sentinel"),
        b"january"
    );
    assert!(!model_dir.join("incomplete").exists());
    assert!(!backup_dir.exists());
}
