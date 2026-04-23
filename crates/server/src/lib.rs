// Module declarations
pub(crate) mod auth;
pub(crate) mod handlers;
pub(crate) mod helpers;
pub(crate) mod persistence;
pub(crate) mod router;
pub(crate) mod state;
pub(crate) mod types;

// Public re-exports for consumers (mobile-ffi, main.rs)
pub use router::{
    init_tracing, run_from_env, start_embedded_server, EmbeddedServer, EmbeddedServerConfig,
};
