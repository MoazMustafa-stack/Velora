//! Pure Linux telemetry parsers and rate calculators.
//!
//! Runtime scheduling and latest-value publication belong to P4.06. Keeping
//! this layer free of filesystem and clock access makes kernel input fixtures
//! deterministic and prevents sampling work from leaking into IPC handlers.

pub mod cpu;
pub mod disk;
pub mod memory;
pub mod network;
pub mod runtime;
