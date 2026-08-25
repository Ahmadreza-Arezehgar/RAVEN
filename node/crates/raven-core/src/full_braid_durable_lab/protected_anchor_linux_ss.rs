//! No-prompt Secret Service client for Task 0B.3 (lab-only).
//!
//! Opens a **plain** session. CreateItem/Delete that return a prompt path map to
//! `LockedOrPromptRequired` without calling `Prompt.Prompt`.
//! Only the existing unlocked default collection is used (no create_collection).

#![cfg(all(target_os = "linux", target_env = "gnu"))]

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use zbus::dbus_proxy;
use zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};
use zvariant_derive::Type;

const SS_NAME: &str = "org.freedesktop.secrets";
const SS_ITEM_LABEL: &str = "org.freedesktop.Secret.Item.Label";
const SS_ITEM_ATTRIBUTES: &str = "org.freedesktop.Secret.Item.Attributes";
const ALG_PLAIN: &str = "plain";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NopromptError {
    Unavailable,
    LockedOrPromptRequired,
    Capacity,
    Io,
}

#[derive(Debug, Serialize, Deserialize, Type)]
struct SecretStruct {
    session: OwnedObjectPath,
    parameters: Vec<u8>,
    value: Vec<u8>,
    content_type: String,
}

#[derive(Debug, Serialize, Deserialize, Type)]
struct OpenSessionResult {
    output: OwnedValue,
    result: OwnedObjectPath,
}

#[derive(Debug, Serialize, Deserialize, Type)]
struct SearchItemsResult {
    unlocked: Vec<OwnedObjectPath>,
    locked: Vec<OwnedObjectPath>,
}

#[derive(Debug, Serialize, Deserialize, Type)]
struct CreateItemResult {
    item: OwnedObjectPath,
    prompt: OwnedObjectPath,
}

#[dbus_proxy(
    interface = "org.freedesktop.Secret.Service",
    default_service = "org.freedesktop.secrets",
    default_path = "/org/freedesktop/secrets"
)]
trait Service {
    fn open_session(&self, algorithm: &str, input: Value<'_>) -> zbus::Result<OpenSessionResult>;
    fn read_alias(&self, name: &str) -> zbus::Result<OwnedObjectPath>;
    fn search_items(&self, attributes: HashMap<&str, &str>) -> zbus::Result<SearchItemsResult>;
}

#[dbus_proxy(
    interface = "org.freedesktop.Secret.Collection",
    default_service = "org.freedesktop.secrets"
)]
trait Collection {
    fn create_item(
        &self,
        properties: HashMap<&str, Value<'_>>,
        secret: SecretStruct,
        replace: bool,
    ) -> zbus::Result<CreateItemResult>;
    #[dbus_proxy(property)]
    fn locked(&self) -> zbus::fdo::Result<bool>;
}

#[dbus_proxy(
    interface = "org.freedesktop.Secret.Item",
    default_service = "org.freedesktop.secrets"
)]
trait Item {
    fn delete(&self) -> zbus::Result<OwnedObjectPath>;
    fn get_secret(&self, session: &ObjectPath<'_>) -> zbus::Result<SecretStruct>;
    #[dbus_proxy(property)]
    fn locked(&self) -> zbus::fdo::Result<bool>;
    #[dbus_proxy(property)]
    fn attributes(&self) -> zbus::fdo::Result<HashMap<String, String>>;
    #[dbus_proxy(property)]
    fn label(&self) -> zbus::fdo::Result<String>;
}

pub struct NopromptSs {
    conn: zbus::Connection,
    session_path: OwnedObjectPath,
    default_collection: OwnedObjectPath,
}

impl NopromptSs {
    pub fn connect() -> Result<Self, NopromptError> {
        let conn = zbus::Connection::new_session().map_err(|_| NopromptError::Unavailable)?;
        let service = ServiceProxy::new(&conn).map_err(|_| NopromptError::Unavailable)?;
        let session = service
            .open_session(ALG_PLAIN, Value::from(""))
            .map_err(map_connect_err)?;
        let default_collection = service
            .read_alias("default")
            .map_err(|_| NopromptError::Unavailable)?;
        if default_collection.as_str() == "/" {
            return Err(NopromptError::Unavailable);
        }
        let coll = CollectionProxy::new_for(&conn, SS_NAME, default_collection.as_str())
            .map_err(|_| NopromptError::Unavailable)?;
        match coll.locked() {
            Ok(true) => return Err(NopromptError::LockedOrPromptRequired),
            Ok(false) => {}
            Err(_) => return Err(NopromptError::Unavailable),
        }
        Ok(Self {
            conn,
            session_path: session.result,
            default_collection,
        })
    }

    pub fn default_collection_path(&self) -> &str {
        self.default_collection.as_str()
    }

    pub fn search(
        &self,
        attrs: HashMap<&str, &str>,
    ) -> Result<Vec<OwnedObjectPath>, NopromptError> {
        let service = ServiceProxy::new(&self.conn).map_err(|_| NopromptError::Unavailable)?;
        let res = service.search_items(attrs).map_err(map_connect_err)?;
        if !res.locked.is_empty() {
            return Err(NopromptError::LockedOrPromptRequired);
        }
        Ok(res.unlocked)
    }

    pub fn item_locked(&self, path: &str) -> Result<bool, NopromptError> {
        let item = ItemProxy::new_for(&self.conn, SS_NAME, path).map_err(|_| NopromptError::Io)?;
        item.locked().map_err(|_| NopromptError::Io)
    }

    pub fn item_label(&self, path: &str) -> Result<String, NopromptError> {
        let item = ItemProxy::new_for(&self.conn, SS_NAME, path).map_err(|_| NopromptError::Io)?;
        item.label().map_err(|_| NopromptError::Io)
    }

    pub fn item_attributes(&self, path: &str) -> Result<HashMap<String, String>, NopromptError> {
        let item = ItemProxy::new_for(&self.conn, SS_NAME, path).map_err(|_| NopromptError::Io)?;
        item.attributes().map_err(|_| NopromptError::Io)
    }

    pub fn item_secret(&self, path: &str) -> Result<(Vec<u8>, String), NopromptError> {
        let item = ItemProxy::new_for(&self.conn, SS_NAME, path).map_err(|_| NopromptError::Io)?;
        if item.locked().map_err(|_| NopromptError::Io)? {
            return Err(NopromptError::LockedOrPromptRequired);
        }
        let secret = item
            .get_secret(&self.session_path)
            .map_err(map_connect_err)?;
        Ok((secret.value, secret.content_type))
    }

    /// CreateItem (`replace=false`). Never executes Prompt.
    pub fn create_item_noprompt(
        &self,
        label: &str,
        attributes: HashMap<&str, &str>,
        secret: &[u8],
        content_type: &str,
    ) -> Result<OwnedObjectPath, NopromptError> {
        let coll = CollectionProxy::new_for(&self.conn, SS_NAME, self.default_collection.as_str())
            .map_err(|_| NopromptError::Io)?;
        match coll.locked() {
            Ok(true) => return Err(NopromptError::LockedOrPromptRequired),
            Ok(false) => {}
            Err(_) => return Err(NopromptError::Unavailable),
        }

        let mut properties: HashMap<&str, Value<'_>> = HashMap::new();
        properties.insert(SS_ITEM_LABEL, Value::from(label));
        properties.insert(SS_ITEM_ATTRIBUTES, Value::from(attributes));

        let secret_struct = SecretStruct {
            session: self.session_path.clone(),
            parameters: Vec::new(),
            value: secret.to_vec(),
            content_type: content_type.to_string(),
        };
        let created = coll
            .create_item(properties, secret_struct, false)
            .map_err(map_mutate_err)?;
        if created.item.as_str() == "/" || created.prompt.as_str() != "/" {
            return Err(NopromptError::LockedOrPromptRequired);
        }
        Ok(created.item)
    }

    /// Item.Delete without Prompt.Prompt.
    pub fn delete_item_noprompt(&self, path: &str) -> Result<(), NopromptError> {
        let item = ItemProxy::new_for(&self.conn, SS_NAME, path).map_err(|_| NopromptError::Io)?;
        match item.locked() {
            Ok(true) => return Err(NopromptError::LockedOrPromptRequired),
            Ok(false) => {}
            Err(_) => return Err(NopromptError::Io),
        }
        let prompt = item.delete().map_err(map_mutate_err)?;
        if prompt.as_str() != "/" {
            return Err(NopromptError::LockedOrPromptRequired);
        }
        Ok(())
    }
}

fn map_connect_err(err: zbus::Error) -> NopromptError {
    let msg = err.to_string();
    if msg.contains("NoSpace") || msg.contains("ENOSPC") {
        NopromptError::Capacity
    } else if msg.contains("Locked") || msg.contains("Prompt") || msg.contains("prompt") {
        NopromptError::LockedOrPromptRequired
    } else {
        NopromptError::Unavailable
    }
}

fn map_mutate_err(err: zbus::Error) -> NopromptError {
    let msg = err.to_string();
    if msg.contains("NoSpace") || msg.contains("ENOSPC") || msg.contains("NoMemory") {
        NopromptError::Capacity
    } else if msg.contains("Locked") || msg.contains("Prompt") || msg.contains("prompt") {
        NopromptError::LockedOrPromptRequired
    } else {
        NopromptError::Io
    }
}
