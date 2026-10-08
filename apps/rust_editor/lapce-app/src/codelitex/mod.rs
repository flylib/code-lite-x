//! CodeLiteX Extension Module Boundary
//!
//! This module contains CodeLiteX-specific branding, constants, theme tokens,
//! and extensions. By isolating customizations here, changes to the upstream
//! Lapce core are minimized and clearly bounded.

pub const APP_NAME: &str = "CodeLiteX";
pub const APP_DISPLAY_NAME: &str = "CodeLiteX";
pub const APP_BUNDLE_ID: &str = "com.codelite.codelitex";
pub const APP_QUALIFIER: &str = "com";
pub const APP_ORGANIZATION: &str = "codelite";
pub const APP_REPO_URL: &str = "https://github.com/flylib/code-lite-x";

// Upstream attribution as required by Apache-2.0
pub const UPSTREAM_BASE: &str = "Lapce v0.4.6";
pub const UPSTREAM_URL: &str = "https://github.com/lapce/lapce";
pub const UPSTREAM_LICENSE: &str = "Apache-2.0";

pub mod git;
