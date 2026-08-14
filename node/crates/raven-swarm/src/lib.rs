//! Reusable pieces of the Raven libp2p transport.
//!
//! The offline mailbox is deliberately feature gated. Default and release
//! builds do not advertise its protocol while the authenticated ATSAM session
//! integration remains on security hold.

#[cfg(feature = "experimental-offline-mailbox")]
pub mod mailbox;

#[cfg(feature = "experimental-nat-connectivity")]
pub mod connectivity;
