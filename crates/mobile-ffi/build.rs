fn main() {
    uniffi::generate_scaffolding("../../crates/mobile-ffi/src/m3u8.udl").unwrap_or_default();
    // proc-macro approach needs no UDL; this is a no-op fallback
}
