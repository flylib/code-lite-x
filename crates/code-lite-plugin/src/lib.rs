pub mod builtins;
pub mod engine;
pub mod error;
pub mod host_api;
pub mod manifest;
pub mod registry;

pub use engine::{PluginRunner, WasmBytecodeRunner, WasmModule, WasmSandbox, WASM_MAGIC, WASM_VERSION_1};
pub use error::PluginError;
pub use host_api::{DiagnosticRecord, HostApi, StandardHostApi};
pub use manifest::{PluginInfo, PluginManifest, PluginPermission, PluginStatus, PluginToolSpec};
pub use registry::PluginRegistry;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wasm_header_and_magic_validation() {
        // Valid WASM header (\0asm 1.0.0.0)
        let valid_header = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
        let module = WasmModule::parse(&valid_header);
        assert!(module.is_ok());

        // Invalid magic header
        let invalid_magic = [0x7f, 0x45, 0x4c, 0x46, 0x01, 0x00, 0x00, 0x00];
        let err = WasmModule::parse(&invalid_magic);
        assert!(err.is_err());
        match err.unwrap_err() {
            PluginError::MissingMagic => {}
            other => panic!("Expected MissingMagic, got {:?}", other),
        }

        // Truncated header
        let truncated = [0x00, 0x61];
        assert!(WasmModule::parse(&truncated).is_err());
    }

    #[test]
    fn test_wasm_sandbox_fuel_metering() {
        let mut sandbox = WasmSandbox::new(1, 100);
        assert!(sandbox.consume_fuel(40).is_ok());
        assert_eq!(sandbox.fuel, 60);

        // Consume remaining + exceed
        let err = sandbox.consume_fuel(70);
        assert!(err.is_err());
        match err.unwrap_err() {
            PluginError::FuelExhausted(_) => {}
            other => panic!("Expected FuelExhausted, got {:?}", other),
        }
    }

    #[test]
    fn test_wasm_sandbox_memory_bounds() {
        let mut sandbox = WasmSandbox::new(1, 1000); // 1 page = 65536 bytes
        let test_data = b"CodeLiteX";

        assert!(sandbox.write_memory(100, test_data).is_ok());
        let read = sandbox.read_memory(100, test_data.len()).unwrap();
        assert_eq!(read, test_data);

        // Out of bounds write
        let err_write = sandbox.write_memory(65530, test_data);
        assert!(err_write.is_err());
        match err_write.unwrap_err() {
            PluginError::MemoryOutOfBounds { offset, len, max } => {
                assert_eq!(offset, 65530);
                assert_eq!(len, test_data.len());
                assert_eq!(max, 65536);
            }
            other => panic!("Expected MemoryOutOfBounds, got {:?}", other),
        }
    }

    #[test]
    fn test_host_api_permission_denial() {
        let host = StandardHostApi::new("/tmp");

        // Plugin without ReadBuffer permission
        let manifest = PluginManifest {
            id: "test.unprivileged".into(),
            name: "Unprivileged".into(),
            version: "0.1.0".into(),
            author: "Tester".into(),
            description: "No permissions".into(),
            entrypoint: "test.wasm".into(),
            permissions: vec![PluginPermission::Log],
            provided_tools: vec![],
        };

        let err = host.read_buffer(&manifest, "Cargo.toml");
        assert!(err.is_err());
        match err.unwrap_err() {
            PluginError::PermissionDenied { plugin, permission } => {
                assert_eq!(plugin, "test.unprivileged");
                assert_eq!(permission, "read_buffer");
            }
            other => panic!("Expected PermissionDenied, got {:?}", other),
        }
    }

    #[test]
    fn test_builtins_sql_inspector() {
        let registry = PluginRegistry::new();
        let host = StandardHostApi::new("/tmp");

        // Safe query
        let select_args = serde_json::json!({
            "query": "SELECT id, name FROM users WHERE active = 1;"
        });
        let res = registry.execute_tool("codelite.sql_inspector", "inspect_sql", select_args, &host).unwrap();
        assert_eq!(res["operation"], "SELECT");
        assert_eq!(res["is_destructive"], false);
        assert_eq!(res["tables"].as_array().unwrap()[0], "users");

        // Destructive query (DROP TABLE)
        let drop_args = serde_json::json!({
            "query": "DROP TABLE critical_data;"
        });
        let res_drop = registry.execute_tool("codelite.sql_inspector", "inspect_sql", drop_args, &host).unwrap();
        assert_eq!(res_drop["operation"], "DROP");
        assert_eq!(res_drop["is_destructive"], true);
        assert_eq!(res_drop["recommended_risk"], "critical");
    }

    #[test]
    fn test_builtins_custom_linter() {
        let registry = PluginRegistry::new();
        let host = StandardHostApi::new("/tmp");

        let code = "fn valid() {\n    // TODO: implement later \n}\n";
        let args = serde_json::json!({ "content": code });

        let res = registry.execute_tool("codelite.custom_linter", "lint_code", args, &host).unwrap();
        assert_eq!(res["clean"], false);
        assert!(res["violations_count"].as_u64().unwrap() >= 2); // trailing whitespace + TODO
    }

    #[test]
    fn test_plugin_registry_lifecycle_and_toggle() {
        let registry = PluginRegistry::new();
        let host = StandardHostApi::new("/tmp");

        let plugins = registry.list_plugins();
        assert!(plugins.len() >= 2);

        // Disable sql inspector
        let disabled_info = registry.toggle_plugin("codelite.sql_inspector", false).unwrap();
        assert_eq!(disabled_info.status, PluginStatus::Disabled);

        // Attempting to run tool on disabled plugin must fail
        let args = serde_json::json!({ "query": "SELECT 1;" });
        let err = registry.execute_tool("codelite.sql_inspector", "inspect_sql", args, &host);
        assert!(err.is_err());
        match err.unwrap_err() {
            PluginError::PluginDisabled(id) => assert_eq!(id, "codelite.sql_inspector"),
            other => panic!("Expected PluginDisabled, got {:?}", other),
        }

        // Re-enable
        let enabled_info = registry.toggle_plugin("codelite.sql_inspector", true).unwrap();
        assert_eq!(enabled_info.status, PluginStatus::Enabled);

        let res = registry.execute_tool("codelite.sql_inspector", "inspect_sql", serde_json::json!({ "query": "SELECT 1;" }), &host);
        assert!(res.is_ok());
    }
}
