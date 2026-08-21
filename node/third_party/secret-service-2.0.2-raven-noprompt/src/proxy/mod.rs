//Copyright 2020 secret-service-rs Developers
//
// Licensed under the Apache License, Version 2.0, <LICENSE-APACHE or
// http://apache.org/licenses/LICENSE-2.0> or the MIT license <LICENSE-MIT or
// http://opensource.org/licenses/MIT>, at your option. This file may not be
// copied, modified, or distributed except according to those terms.

pub mod collection;
pub mod item;
pub mod prompt;
pub mod service;
pub mod session;

use serde::{Deserialize, Serialize};
use zeroize::Zeroize;
use zvariant::OwnedObjectPath;
use zvariant_derive::Type;

#[derive(Serialize, Deserialize, Type)]
pub struct SecretStruct {
    pub(crate) session: OwnedObjectPath,
    pub(crate) parameters: Vec<u8>,
    pub(crate) value: Vec<u8>,
    pub(crate) content_type: String,
}

impl std::fmt::Debug for SecretStruct {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SecretStruct")
            .field("session", &self.session)
            .field("parameters_len", &self.parameters.len())
            .field("value_len", &self.value.len())
            .field("content_type", &self.content_type)
            .finish()
    }
}

impl Drop for SecretStruct {
    fn drop(&mut self) {
        self.parameters.zeroize();
        self.value.zeroize();
    }
}
