//! Raven Task 0B.3 R0 hard-stop proofs against a live Secret Service provider.
//!
//! Requires a session bus with an unlocked default collection (e.g. GNOME Keyring
//! under `dbus-run-session`). These tests refuse plain-session no-prompt use and
//! never call Prompt.Prompt.

#![cfg(all(target_os = "linux", target_env = "gnu"))]

use secret_service::{EncryptionType, Error, SecretService};
use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};
use zeroize::Zeroize;

fn unique_attr(tag: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("time")
        .as_nanos();
    format!("raven-r0-{tag}-{nanos}-{}", std::process::id())
}

fn assert_r0_provider_content_type(item: &secret_service::Item, object: &str) {
    let observed = item.get_secret_content_type().expect("content type");
    assert!(
        matches!(observed.as_str(), "application/octet-stream" | "text/plain"),
        "unexpected Secret Service content type: {}",
        observed
    );
    println!("R0_PROVIDER_CONTENT_TYPE[{object}]={observed}");
}

/// DH negotiate + encrypted create/get round-trip without prompt.
#[test]
fn dh_create_get_no_prompt_round_trip() {
    let ss = SecretService::new(EncryptionType::Dh).expect("DH session");
    let collection = ss.get_default_collection().expect("default collection");
    assert!(
        !collection.is_locked().expect("locked?"),
        "default collection must be unlocked for R0 proofs"
    );

    let scope = unique_attr("scope");
    let mut attrs = HashMap::new();
    attrs.insert("application", "app.raven.r0");
    attrs.insert("protocol", "raven-r0-hard-stop");
    attrs.insert("kind", "probe");
    attrs.insert("scope", scope.as_str());

    let mut secret = [0xA5u8; 32];
    let item = collection
        .create_item_no_prompt(
            "RAVEN R0 DH probe",
            attrs,
            &secret,
            "application/octet-stream",
        )
        .expect("create_item_no_prompt");

    let coll_path = item.collection_path().expect("collection_path");
    assert!(
        coll_path.starts_with("/org/freedesktop/secrets/collection/"),
        "unexpected collection path: {}",
        coll_path
    );
    assert_eq!(
        coll_path,
        collection.collection_path.as_str(),
        "item parent must match create collection"
    );

    item.with_secret_zeroizing(|read| assert_eq!(read, &secret[..]))
        .expect("with_secret_zeroizing");
    assert_r0_provider_content_type(&item, "seed");

    item.delete_no_prompt().expect("delete_no_prompt");
    secret.zeroize();
}

/// Plain session must not be usable for the no-prompt create surface.
#[test]
fn plain_session_rejected_by_no_prompt_create() {
    let ss = SecretService::new(EncryptionType::Plain).expect("plain session opens for compat");
    let collection = ss.get_default_collection().expect("default");
    let mut attrs = HashMap::new();
    attrs.insert("application", "app.raven.r0");
    let result = collection.create_item_no_prompt(
        "x",
        attrs,
        b"0123456789abcdef0123456789abcdef",
        "application/octet-stream",
    );
    match result {
        Err(Error::Crypto(_)) => {}
        Err(other) => panic!("expected Crypto reject for plain, got {:?}", other),
        Ok(_) => panic!("plain must fail closed for no-prompt"),
    }
}

/// A compatibility Plain item cannot be deleted through Raven's no-prompt API.
#[test]
fn plain_session_rejected_by_no_prompt_delete_and_zeroizing_read() {
    let ss = SecretService::new(EncryptionType::Plain).expect("plain compatibility session");
    let collection = ss.get_default_collection().expect("default");
    let scope = unique_attr("plain-delete");
    let mut attrs = HashMap::new();
    attrs.insert("application", "app.raven.r0-negative");
    attrs.insert("scope", scope.as_str());
    let item = collection
        .create_item(
            "RAVEN R0 plain negative",
            attrs,
            b"not-a-protected-anchor-secret",
            false,
            "application/octet-stream",
        )
        .expect("create compatibility item");

    assert!(matches!(item.delete_no_prompt(), Err(Error::Crypto(_))));
    assert!(matches!(
        item.with_secret_zeroizing(|_| ()),
        Err(Error::Crypto(_))
    ));
    item.delete().expect("cleanup compatibility item");
}

/// The protected record size used by RVFA1 survives the DH transfer exactly.
#[test]
fn dh_rvfa1_sized_binary_round_trip() {
    let ss = SecretService::new(EncryptionType::Dh).expect("DH");
    let collection = ss.get_default_collection().expect("default");
    let scope = unique_attr("rvfa1");
    let mut attrs = HashMap::new();
    attrs.insert("application", "app.raven.r0");
    attrs.insert("protocol", "atsam-full-braid-v1");
    attrs.insert("kind", "anchor");
    attrs.insert("scope", scope.as_str());
    let mut record = [0u8; 204];
    for (index, byte) in record.iter_mut().enumerate() {
        *byte = (index as u8).wrapping_mul(37).wrapping_add(11);
    }
    let item = collection
        .create_item_no_prompt(
            "RAVEN R0 RVFA1 probe",
            attrs,
            &record,
            "application/octet-stream",
        )
        .expect("create RVFA1 probe");

    item.with_secret_zeroizing(|read| assert_eq!(read, &record[..]))
        .expect("read RVFA1 probe");
    assert_r0_provider_content_type(&item, "rvfa1");
    item.delete_no_prompt().expect("cleanup RVFA1 probe");
    record.zeroize();
}

/// Collection path binding is derived from the created item, not a mutable alias.
#[test]
fn collection_path_round_trip_by_path_api() {
    let ss = SecretService::new(EncryptionType::Dh).expect("DH");
    let collection = ss.get_default_collection().expect("default");
    let scope = unique_attr("path");
    let mut attrs = HashMap::new();
    attrs.insert("application", "app.raven.r0");
    attrs.insert("scope", scope.as_str());
    let item = collection
        .create_item_no_prompt(
            "RAVEN R0 path probe",
            attrs,
            &[0x11u8; 32],
            "application/octet-stream",
        )
        .expect("create");
    let path = item.collection_path().expect("path");
    assert_eq!(collection.collection_path.as_str(), path);
    item.delete_no_prompt().expect("cleanup");
}

/// A locked collection is deferred without any unlock or Prompt.Prompt call.
/// This test intentionally runs last and leaves the ephemeral test keyring locked.
#[test]
fn zzz_locked_collection_is_refused_without_prompt_or_unlock() {
    let ss = SecretService::new(EncryptionType::Dh).expect("DH");
    let collection = ss.get_default_collection().expect("default");
    assert!(!collection.is_locked().expect("initial lock state"));
    collection.lock().expect("lock collection without prompt");
    assert!(collection.is_locked().expect("locked state"));

    let scope = unique_attr("locked");
    let mut attrs = HashMap::new();
    attrs.insert("application", "app.raven.r0");
    attrs.insert("scope", scope.as_str());
    assert!(matches!(
        collection.create_item_no_prompt(
            "must not be created",
            attrs,
            &[0x55; 32],
            "application/octet-stream",
        ),
        Err(Error::Locked)
    ));
    assert!(collection.is_locked().expect("must remain locked"));
}
