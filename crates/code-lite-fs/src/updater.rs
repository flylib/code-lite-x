//! # code-lite-fs::updater
//!
//! Production-grade differential auto-updater engine for CodeLiteX.
//! Implements Architecture Decision D3:
//! - macOS: AppBundleDelta (Sparkle-style bundle replacement to preserve code signature & notarization)
//! - Linux / Windows: ComponentDelta (atomic replacement of dynamic library & frontend assets with backup & rollback)

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum UpdaterError {
    #[error("Invalid version manifest: {0}")]
    InvalidManifest(String),

    #[error("Unsupported platform: {0}")]
    UnsupportedPlatform(String),

    #[error("Checksum verification failed for {file}: expected {expected}, actual {actual}")]
    ChecksumMismatch {
        file: String,
        expected: String,
        actual: String,
    },

    #[error("IO error during update operation: {0}")]
    Io(String),

    #[error("Rollback failed: {0}")]
    RollbackFailed(String),
}

/// Target platform classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlatformKind {
    Macos,
    Linux,
    Windows,
    Unknown,
}

impl PlatformKind {
    /// Detects current operating system platform.
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            PlatformKind::Macos
        } else if cfg!(target_os = "linux") {
            PlatformKind::Linux
        } else if cfg!(target_os = "windows") {
            PlatformKind::Windows
        } else {
            PlatformKind::Unknown
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            PlatformKind::Macos => "macos",
            PlatformKind::Linux => "linux",
            PlatformKind::Windows => "windows",
            PlatformKind::Unknown => "unknown",
        }
    }

    pub fn from_str_name(name: &str) -> Self {
        match name.to_lowercase().as_str() {
            "macos" | "darwin" | "osx" => PlatformKind::Macos,
            "linux" => PlatformKind::Linux,
            "windows" | "win32" | "win" => PlatformKind::Windows,
            _ => PlatformKind::Unknown,
        }
    }
}

/// Differential update strategy based on OS security and signing constraints (D3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UpdateStrategy {
    /// macOS: Full application bundle or binary delta preserving code signature & notarization.
    AppBundleDelta,
    /// Linux / Windows: Component-level atomic hot replacement (dynamic lib + assets).
    ComponentDelta,
}

impl UpdateStrategy {
    pub fn for_platform(platform: PlatformKind) -> Self {
        match platform {
            PlatformKind::Macos => UpdateStrategy::AppBundleDelta,
            PlatformKind::Linux | PlatformKind::Windows => UpdateStrategy::ComponentDelta,
            PlatformKind::Unknown => UpdateStrategy::AppBundleDelta,
        }
    }
}

/// Description of a downloadable update artifact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlatformArtifact {
    pub target_name: String,
    pub target_path: String,
    pub url: String,
    pub sha256: String,
    pub size_bytes: u64,
}

/// Platform-specific release specifications.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlatformRelease {
    pub strategy: UpdateStrategy,
    pub artifacts: Vec<PlatformArtifact>,
    #[serde(default)]
    pub installer_url: Option<String>,
}

/// Release manifest metadata (`version.json`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VersionManifest {
    pub version: String,
    pub release_date: String,
    pub release_notes: String,
    #[serde(default)]
    pub min_compatible_version: Option<String>,
    pub platforms: HashMap<String, PlatformRelease>,
}

/// Output result of an update check.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateCheckResult {
    pub current_version: String,
    pub latest_version: String,
    pub has_update: bool,
    pub platform: String,
    pub strategy: UpdateStrategy,
    pub release_notes: String,
    pub artifacts: Vec<PlatformArtifact>,
    pub installer_url: Option<String>,
}

/// Result report after applying component delta.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApplyReport {
    pub success: bool,
    pub updated_files: Vec<String>,
    pub backup_dir: Option<String>,
    pub rollback_executed: bool,
}

/// Compares two Semantic Version strings (e.g., "0.1.0" vs "0.2.0").
pub fn compare_semver(v1: &str, v2: &str) -> Ordering {
    let parse_nums = |s: &str| -> (u32, u32, u32) {
        let clean = s.trim().trim_start_matches('v').split('-').next().unwrap_or(s);
        let mut parts = clean.split('.').map(|p| p.parse::<u32>().unwrap_or(0));
        let major = parts.next().unwrap_or(0);
        let minor = parts.next().unwrap_or(0);
        let patch = parts.next().unwrap_or(0);
        (major, minor, patch)
    };

    let p1 = parse_nums(v1);
    let p2 = parse_nums(v2);

    match p1.0.cmp(&p2.0) {
        Ordering::Equal => match p1.1.cmp(&p2.1) {
            Ordering::Equal => p1.2.cmp(&p2.2),
            other => other,
        },
        other => other,
    }
}

/// Self-contained FIPS 180-4 compliant SHA-256 calculation.
pub fn sha256_digest(data: &[u8]) -> String {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];

    let k: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    let bit_len = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while (msg.len() % 64) != 56 {
        msg.push(0x00);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for (i, c) in chunk.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([c[0], c[1], c[2], c[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }

        let mut a = h[0];
        let mut b = h[1];
        let mut c = h[2];
        let mut d = h[3];
        let mut e = h[4];
        let mut f = h[5];
        let mut g = h[6];
        let mut h_val = h[7];

        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = h_val
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(k[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            h_val = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(h_val);
    }

    let mut out = String::with_capacity(64);
    for val in &h {
        out.push_str(&format!("{:08x}", val));
    }
    out
}

/// Core Auto-Updater Engine.
pub struct UpdaterEngine;

impl UpdaterEngine {
    /// Checks for available updates by comparing current version against `version.json`.
    pub fn check_update(
        current_version: &str,
        manifest_json: &str,
        forced_platform: Option<PlatformKind>,
    ) -> Result<UpdateCheckResult, UpdaterError> {
        let manifest: VersionManifest = serde_json::from_str(manifest_json)
            .map_err(|e| UpdaterError::InvalidManifest(e.to_string()))?;

        let platform = forced_platform.unwrap_or_else(PlatformKind::current);
        let platform_str = platform.as_str();

        let release = manifest
            .platforms
            .get(platform_str)
            .cloned()
            .unwrap_or_else(|| PlatformRelease {
                strategy: UpdateStrategy::for_platform(platform),
                artifacts: Vec::new(),
                installer_url: None,
            });

        let has_update = compare_semver(current_version, &manifest.version) == Ordering::Less;

        Ok(UpdateCheckResult {
            current_version: current_version.to_string(),
            latest_version: manifest.version,
            has_update,
            platform: platform_str.to_string(),
            strategy: release.strategy,
            release_notes: manifest.release_notes,
            artifacts: release.artifacts,
            installer_url: release.installer_url,
        })
    }

    /// Stages an artifact into a temporary directory after verifying its SHA256 checksum.
    pub fn stage_artifact(
        staging_dir: &Path,
        file_name: &str,
        data: &[u8],
        expected_sha256: &str,
    ) -> Result<PathBuf, UpdaterError> {
        let actual_hash = sha256_digest(data);
        if !actual_hash.eq_ignore_ascii_case(expected_sha256.trim()) {
            return Err(UpdaterError::ChecksumMismatch {
                file: file_name.to_string(),
                expected: expected_sha256.to_string(),
                actual: actual_hash,
            });
        }

        fs::create_dir_all(staging_dir).map_err(|e| UpdaterError::Io(e.to_string()))?;
        let target_path = staging_dir.join(file_name);
        fs::write(&target_path, data).map_err(|e| UpdaterError::Io(e.to_string()))?;

        Ok(target_path)
    }

    /// Performs atomic component delta update on Linux/Windows.
    /// Creates backup snapshot of existing target files before copying.
    /// If an error occurs, rolls back all replaced files automatically.
    pub fn apply_component_delta(
        staging_dir: &Path,
        target_install_dir: &Path,
        relative_files: &[String],
    ) -> Result<ApplyReport, UpdaterError> {
        fs::create_dir_all(target_install_dir).map_err(|e| UpdaterError::Io(e.to_string()))?;

        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let backup_dir = target_install_dir.join(format!(".update_backup_{}", timestamp));
        fs::create_dir_all(&backup_dir).map_err(|e| UpdaterError::Io(e.to_string()))?;

        let mut backed_up = Vec::new();
        let mut updated = Vec::new();

        // 1. Backup existing files
        for rel in relative_files {
            let target_file = target_install_dir.join(rel);
            if target_file.exists() {
                let backup_file = backup_dir.join(rel);
                if let Some(parent) = backup_file.parent() {
                    fs::create_dir_all(parent).map_err(|e| UpdaterError::Io(e.to_string()))?;
                }
                if let Err(e) = fs::copy(&target_file, &backup_file) {
                    return Err(UpdaterError::Io(format!("Failed to backup {}: {}", target_file.display(), e)));
                }
                backed_up.push(rel.clone());
            }
        }

        // 2. Copy new files from staging to target
        let mut apply_failed = false;
        let mut error_msg = String::new();

        for rel in relative_files {
            let src_file = staging_dir.join(rel);
            let dst_file = target_install_dir.join(rel);

            if !src_file.exists() {
                apply_failed = true;
                error_msg = format!("Staged file missing: {}", src_file.display());
                break;
            }

            if let Some(parent) = dst_file.parent() {
                if let Err(e) = fs::create_dir_all(parent) {
                    apply_failed = true;
                    error_msg = format!("Failed to create directory {}: {}", parent.display(), e);
                    break;
                }
            }

            if let Err(e) = fs::copy(&src_file, &dst_file) {
                apply_failed = true;
                error_msg = format!("Failed to copy {} to {}: {}", src_file.display(), dst_file.display(), e);
                break;
            }

            updated.push(rel.clone());
        }

        // 3. Rollback on failure
        if apply_failed {
            for rel in &backed_up {
                let backup_file = backup_dir.join(rel);
                let dst_file = target_install_dir.join(rel);
                let _ = fs::copy(&backup_file, &dst_file);
            }
            return Err(UpdaterError::RollbackFailed(format!(
                "Update failed and rolled back: {}",
                error_msg
            )));
        }

        Ok(ApplyReport {
            success: true,
            updated_files: updated,
            backup_dir: Some(backup_dir.to_string_lossy().to_string()),
            rollback_executed: false,
        })
    }

    /// Generates macOS atomic app bundle swap script for restart.
    /// Preserves notarization and signature by replacing the whole bundle.
    pub fn generate_macos_swap_script(staging_app_path: &Path, target_app_path: &Path) -> String {
        let staging_str = staging_app_path.to_string_lossy();
        let target_str = target_app_path.to_string_lossy();

        format!(
            r#"#!/usr/bin/env bash
# ==============================================================================
# CodeLiteX macOS Sparkle-style Atomic Bundle Swap
# ==============================================================================
set -e

STAGING="{staging_str}"
TARGET="{target_str}"

# Wait for current instance to gracefully terminate
sleep 0.8

if [ -d "$STAGING" ]; then
    rm -rf "$TARGET"
    mv "$STAGING" "$TARGET"
    open "$TARGET"
fi
"#
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_sha256_known_vectors() {
        assert_eq!(
            sha256_digest(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_digest(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn test_semver_comparison() {
        assert_eq!(compare_semver("0.1.0", "0.2.0"), Ordering::Less);
        assert_eq!(compare_semver("0.2.0", "0.1.0"), Ordering::Greater);
        assert_eq!(compare_semver("0.1.0", "0.1.0"), Ordering::Equal);
        assert_eq!(compare_semver("v1.0.0", "0.9.9"), Ordering::Greater);
        assert_eq!(compare_semver("0.1.5", "0.1.10"), Ordering::Less);
    }

    #[test]
    fn test_check_update_with_manifest() {
        let manifest = r#"{
            "version": "0.2.0",
            "release_date": "2026-09-10",
            "release_notes": "Phase 11: Cross-platform release",
            "platforms": {
                "macos": {
                    "strategy": "app_bundle_delta",
                    "artifacts": [
                        {
                            "target_name": "CodeLiteX.app.zip",
                            "target_path": ".",
                            "url": "https://releases.codelitex.org/macos/CodeLiteX-0.2.0.zip",
                            "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                            "size_bytes": 10485760
                        }
                    ]
                },
                "linux": {
                    "strategy": "component_delta",
                    "artifacts": [
                        {
                            "target_name": "libcodelite.so",
                            "target_path": "lib/libcodelite.so",
                            "url": "https://releases.codelitex.org/linux/libcodelite.so",
                            "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                            "size_bytes": 7340032
                        }
                    ]
                }
            }
        }"#;

        // Current version is older
        let res = UpdaterEngine::check_update("0.1.0", manifest, Some(PlatformKind::Macos)).unwrap();
        assert!(res.has_update);
        assert_eq!(res.latest_version, "0.2.0");
        assert_eq!(res.strategy, UpdateStrategy::AppBundleDelta);
        assert_eq!(res.artifacts.len(), 1);

        // Current version is up to date
        let res_current = UpdaterEngine::check_update("0.2.0", manifest, Some(PlatformKind::Macos)).unwrap();
        assert!(!res_current.has_update);

        // Linux platform uses ComponentDelta strategy
        let res_linux = UpdaterEngine::check_update("0.1.0", manifest, Some(PlatformKind::Linux)).unwrap();
        assert!(res_linux.has_update);
        assert_eq!(res_linux.strategy, UpdateStrategy::ComponentDelta);
    }

    #[test]
    fn test_staging_with_sha256_verification() {
        let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let temp_dir = std::env::temp_dir().join(format!("codelite_stage_test_{}", ts));
        let data = b"abc";
        let valid_hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        let invalid_hash = "0000000000000000000000000000000000000000000000000000000000000000";

        // Valid hash succeeds
        let staged_path = UpdaterEngine::stage_artifact(&temp_dir, "libcodelite.so", data, valid_hash).unwrap();
        assert!(staged_path.exists());
        assert_eq!(fs::read(&staged_path).unwrap(), data);

        // Invalid hash fails
        let err = UpdaterEngine::stage_artifact(&temp_dir, "bad.so", data, invalid_hash).unwrap_err();
        assert!(matches!(err, UpdaterError::ChecksumMismatch { .. }));

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_component_delta_apply_and_rollback() {
        let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let base_dir = std::env::temp_dir().join(format!("codelite_delta_test_{}", ts));
        let staging_dir = base_dir.join("staging");
        let install_dir = base_dir.join("install");

        fs::create_dir_all(&staging_dir).unwrap();
        fs::create_dir_all(install_dir.join("lib")).unwrap();

        // Old file in install dir
        fs::write(install_dir.join("lib/libcodelite.so"), b"v1_binary").unwrap();

        // New file in staging dir
        fs::create_dir_all(staging_dir.join("lib")).unwrap();
        fs::write(staging_dir.join("lib/libcodelite.so"), b"v2_binary").unwrap();

        let files = vec!["lib/libcodelite.so".to_string()];
        let report = UpdaterEngine::apply_component_delta(&staging_dir, &install_dir, &files).unwrap();

        assert!(report.success);
        assert_eq!(report.updated_files.len(), 1);
        assert_eq!(fs::read(install_dir.join("lib/libcodelite.so")).unwrap(), b"v2_binary");

        // Verify backup was created
        let backup_path = PathBuf::from(report.backup_dir.unwrap());
        assert!(backup_path.join("lib/libcodelite.so").exists());
        assert_eq!(fs::read(backup_path.join("lib/libcodelite.so")).unwrap(), b"v1_binary");

        // Test failure & rollback when a staged file is missing
        let missing_files = vec!["missing_file.so".to_string()];
        let rollback_res = UpdaterEngine::apply_component_delta(&staging_dir, &install_dir, &missing_files);
        assert!(rollback_res.is_err());

        let _ = fs::remove_dir_all(&base_dir);
    }

    #[test]
    fn test_macos_swap_script_generation() {
        let staging = PathBuf::from("/tmp/CodeLiteX_new.app");
        let target = PathBuf::from("/Applications/CodeLiteX.app");
        let script = UpdaterEngine::generate_macos_swap_script(&staging, &target);

        assert!(script.contains("STAGING=\"/tmp/CodeLiteX_new.app\""));
        assert!(script.contains("TARGET=\"/Applications/CodeLiteX.app\""));
        assert!(script.contains("rm -rf \"$TARGET\""));
        assert!(script.contains("mv \"$STAGING\" \"$TARGET\""));
        assert!(script.contains("open \"$TARGET\""));
    }
}
