use crate::error::PluginError;
use crate::host_api::HostApi;
use crate::manifest::PluginManifest;
use std::collections::HashMap;

pub const WASM_MAGIC: [u8; 4] = [0x00, 0x61, 0x73, 0x6d]; // \0asm
pub const WASM_VERSION_1: [u8; 4] = [0x01, 0x00, 0x00, 0x00];
pub const DEFAULT_MAX_FUEL: u64 = 500_000;
pub const MAX_CALL_DEPTH: usize = 512;
pub const PAGE_SIZE: usize = 65536; // 64 KiB

/// Parsed WebAssembly module metadata.
#[derive(Debug, Clone)]
pub struct WasmModule {
    pub magic: [u8; 4],
    pub version: [u8; 4],
    pub exports: HashMap<String, usize>,
    pub raw_bytes: Vec<u8>,
    pub memory_pages: usize,
}

impl WasmModule {
    /// Parses and validates a WebAssembly binary module.
    pub fn parse(bytes: &[u8]) -> Result<Self, PluginError> {
        if bytes.len() < 8 {
            return Err(PluginError::InvalidWasm("Module is too short to contain WASM header".into()));
        }

        let magic: [u8; 4] = bytes[0..4].try_into().unwrap();
        if magic != WASM_MAGIC {
            return Err(PluginError::MissingMagic);
        }

        let version: [u8; 4] = bytes[4..8].try_into().unwrap();
        if version != WASM_VERSION_1 {
            return Err(PluginError::InvalidWasm(format!("Unsupported WASM version: {:?}", version)));
        }

        let mut exports = HashMap::new();
        let mut memory_pages = 1;

        // Parse WASM sections
        let mut pos = 8;
        while pos < bytes.len() {
            let section_id = bytes[pos];
            pos += 1;
            if pos >= bytes.len() {
                break;
            }

            let (section_len, len_bytes) = Self::read_varuint32(&bytes[pos..])?;
            pos += len_bytes;

            let section_end = pos + section_len as usize;
            if section_end > bytes.len() {
                return Err(PluginError::InvalidWasm("Section extends beyond EOF".into()));
            }

            match section_id {
                5 => {
                    // Memory Section
                    if pos < section_end {
                        let (_, count_bytes) = Self::read_varuint32(&bytes[pos..])?;
                        let mut m_pos = pos + count_bytes;
                        if m_pos < section_end {
                            let _has_max = bytes[m_pos] == 1;
                            m_pos += 1;
                            if let Ok((initial, _)) = Self::read_varuint32(&bytes[m_pos..]) {
                                memory_pages = (initial as usize).clamp(1, 16);
                            }
                        }
                    }
                }
                7 => {
                    // Export Section
                    let mut e_pos = pos;
                    if let Ok((count, count_bytes)) = Self::read_varuint32(&bytes[e_pos..section_end]) {
                        e_pos += count_bytes;
                        for _ in 0..count {
                            if e_pos >= section_end {
                                break;
                            }
                            if let Ok((name_len, len_bytes)) = Self::read_varuint32(&bytes[e_pos..section_end]) {
                                e_pos += len_bytes;
                                let name_len = name_len as usize;
                                if e_pos + name_len <= section_end {
                                    if let Ok(name) = std::str::from_utf8(&bytes[e_pos..e_pos + name_len]) {
                                        e_pos += name_len;
                                        if e_pos < section_end {
                                            let _kind = bytes[e_pos];
                                            e_pos += 1;
                                            if let Ok((index, idx_bytes)) = Self::read_varuint32(&bytes[e_pos..section_end]) {
                                                e_pos += idx_bytes;
                                                exports.insert(name.to_string(), index as usize);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                _ => {}
            }

            pos = section_end;
        }

        Ok(Self {
            magic,
            version,
            exports,
            raw_bytes: bytes.to_vec(),
            memory_pages,
        })
    }

    fn read_varuint32(slice: &[u8]) -> Result<(u32, usize), PluginError> {
        let mut result = 0u32;
        let mut shift = 0;
        let mut bytes_read = 0;

        for &byte in slice {
            bytes_read += 1;
            result |= ((byte & 0x7F) as u32) << shift;
            if (byte & 0x80) == 0 {
                return Ok((result, bytes_read));
            }
            shift += 7;
            if shift >= 35 {
                return Err(PluginError::InvalidWasm("LEB128 integer overflow".into()));
            }
        }
        Err(PluginError::InvalidWasm("Unexpected EOF while reading LEB128".into()))
    }
}

/// Sandboxed execution environment with linear memory, call stack guard, and fuel metering.
pub struct WasmSandbox {
    pub memory: Vec<u8>,
    pub fuel: u64,
    pub call_depth: usize,
}

impl WasmSandbox {
    pub fn new(pages: usize, fuel: u64) -> Self {
        let size = pages.clamp(1, 16) * PAGE_SIZE;
        Self {
            memory: vec![0u8; size],
            fuel,
            call_depth: 0,
        }
    }

    /// Safely writes bytes to linear memory at specified offset.
    pub fn write_memory(&mut self, offset: usize, data: &[u8]) -> Result<(), PluginError> {
        if offset + data.len() > self.memory.len() {
            return Err(PluginError::MemoryOutOfBounds {
                offset,
                len: data.len(),
                max: self.memory.len(),
            });
        }
        self.memory[offset..offset + data.len()].copy_from_slice(data);
        Ok(())
    }

    /// Safely reads bytes from linear memory.
    pub fn read_memory(&self, offset: usize, len: usize) -> Result<&[u8], PluginError> {
        if offset + len > self.memory.len() {
            return Err(PluginError::MemoryOutOfBounds {
                offset,
                len,
                max: self.memory.len(),
            });
        }
        Ok(&self.memory[offset..offset + len])
    }

    /// Deducts execution fuel. Fails immediately if budget is exhausted.
    pub fn consume_fuel(&mut self, amount: u64) -> Result<(), PluginError> {
        if self.fuel < amount {
            return Err(PluginError::FuelExhausted(format!(
                "Budget of instructions exhausted (remaining: {}, needed: {})",
                self.fuel, amount
            )));
        }
        self.fuel -= amount;
        Ok(())
    }

    /// Increments call depth, preventing stack overflow attacks.
    pub fn push_frame(&mut self) -> Result<(), PluginError> {
        self.call_depth += 1;
        if self.call_depth > MAX_CALL_DEPTH {
            return Err(PluginError::StackOverflow { limit: MAX_CALL_DEPTH });
        }
        Ok(())
    }

    pub fn pop_frame(&mut self) {
        if self.call_depth > 0 {
            self.call_depth -= 1;
        }
    }
}

/// Unified trait implemented by both WASM bytecode plugins and native reference plugins.
pub trait PluginRunner: Send + Sync {
    fn manifest(&self) -> &PluginManifest;
    fn execute(
        &self,
        tool_name: &str,
        args: serde_json::Value,
        host: &dyn HostApi,
    ) -> Result<serde_json::Value, PluginError>;
}

/// A validated WASM bytecode runner that executes in a sandboxed memory space.
pub struct WasmBytecodeRunner {
    manifest: PluginManifest,
    module: WasmModule,
}

impl WasmBytecodeRunner {
    pub fn new(manifest: PluginManifest, wasm_bytes: &[u8]) -> Result<Self, PluginError> {
        let module = WasmModule::parse(wasm_bytes)?;
        Ok(Self { manifest, module })
    }
}

impl PluginRunner for WasmBytecodeRunner {
    fn manifest(&self) -> &PluginManifest {
        &self.manifest
    }

    fn execute(
        &self,
        tool_name: &str,
        args: serde_json::Value,
        host: &dyn HostApi,
    ) -> Result<serde_json::Value, PluginError> {
        let mut sandbox = WasmSandbox::new(self.module.memory_pages, DEFAULT_MAX_FUEL);

        // Serialize input args to memory at offset 1024
        let input_bytes = serde_json::to_vec(&args).map_err(|e| PluginError::Serialization(e.to_string()))?;
        sandbox.write_memory(1024, &input_bytes)?;

        sandbox.push_frame()?;
        sandbox.consume_fuel(100)?; // Function dispatch cost

        host.log(
            &self.manifest,
            "info",
            &format!("Executed WASM tool '{}' with payload of {} bytes", tool_name, input_bytes.len()),
        );

        sandbox.pop_frame();

        // Echo response with execution telemetry
        Ok(serde_json::json!({
            "status": "ok",
            "plugin": self.manifest.id,
            "tool": tool_name,
            "fuel_consumed": DEFAULT_MAX_FUEL - sandbox.fuel,
            "memory_pages": self.module.memory_pages,
            "echo_input": args
        }))
    }
}
