//! RavenIntroductionV1 — recipient-specific encrypted social introductions.
//!
//! Outer fields are metadata for local routing; sensitive note stays sealed.

use crate::atsam_aead::{seal_rvna1_v2, unseal_rvna1_v2};
use crate::canon::{lp, u64_be};
use crate::identity::Identity;

pub const INTRO_DOMAIN: &[u8] = b"rvn1/intro";
/// Social-introduction notes require an authenticated ATSAM session root.
/// Public identity material must never be treated as an encryption secret.
pub const INTRO_SESSION_REQUIRED: &str =
    "INTRO_SESSION_REQUIRED: authenticated ATSAM root required";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RavenIntroductionV1 {
    pub intro_id: [u8; 16],
    pub introducer_raven_id: String,
    pub subject_raven_id: String,
    pub recipient_raven_id: String,
    pub subject_display_name: String,
    pub subject_aliases: Vec<String>,
    pub created_at: u64,
    pub expires_at: u64,
    /// E2EE note ciphertext (opaque to relays).
    pub note_ciphertext: Vec<u8>,
    pub signature: [u8; 64],
    pub introducer_pub: [u8; 32],
}

impl RavenIntroductionV1 {
    pub fn signing_bytes(&self) -> Result<Vec<u8>, String> {
        let mut out = INTRO_DOMAIN.to_vec();
        out.extend_from_slice(&self.intro_id);
        out.extend(lp(self.introducer_raven_id.as_bytes())?);
        out.extend(lp(self.subject_raven_id.as_bytes())?);
        out.extend(lp(self.recipient_raven_id.as_bytes())?);
        out.extend(lp(self.subject_display_name.as_bytes())?);
        out.extend_from_slice(&(self.subject_aliases.len() as u16).to_be_bytes());
        for a in &self.subject_aliases {
            out.extend(lp(a.as_bytes())?);
        }
        out.extend_from_slice(&u64_be(self.created_at));
        out.extend_from_slice(&u64_be(self.expires_at));
        out.extend(lp(&self.note_ciphertext)?);
        Ok(out)
    }

    pub fn sign(mut self, introducer: &Identity) -> Result<Self, String> {
        self.introducer_pub = introducer.public_key_bytes();
        self.introducer_raven_id = introducer.address();
        let sb = self.signing_bytes()?;
        self.signature = introducer.sign(&sb);
        Ok(self)
    }

    pub fn verify(&self, now_ms: u64) -> Result<(), String> {
        if now_ms > self.expires_at {
            return Err("INTRO_EXPIRED".into());
        }
        if self.expires_at <= self.created_at
            || crate::address::encode_address(&self.introducer_pub) != self.introducer_raven_id
        {
            return Err("INTRO_IDENTITY_OR_TIME_MISMATCH".into());
        }
        let sb = self.signing_bytes()?;
        if !Identity::verify(&self.introducer_pub, &sb, &self.signature) {
            return Err("INTRO_BAD_SIG".into());
        }
        Ok(())
    }

    /// Rootless compatibility entry point. Always fails closed, including
    /// debug and lab-feature builds; use `seal_note_with_atsam_root`.
    pub fn seal_note(
        introducer: &Identity,
        recipient_pub: &[u8; 32],
        recipient_addr: &str,
        plaintext_note: &[u8],
        intro_id: &[u8; 16],
    ) -> Result<Vec<u8>, String> {
        let _ = (
            introducer,
            recipient_pub,
            recipient_addr,
            plaintext_note,
            intro_id,
        );
        Err(INTRO_SESSION_REQUIRED.into())
    }

    /// Seal a note under an authenticated ATSAM session root. The caller must
    /// allocate the chain index and nonce exactly once and persist that state.
    #[allow(clippy::too_many_arguments)]
    pub fn seal_note_with_atsam_root(
        introducer: &Identity,
        recipient_pub: &[u8; 32],
        recipient_addr: &str,
        plaintext_note: &[u8],
        intro_id: &[u8; 16],
        root: &[u8; 32],
        chain_index: u32,
        nonce: &[u8; 12],
    ) -> Result<Vec<u8>, String> {
        if crate::address::encode_address(recipient_pub) != recipient_addr {
            return Err("INTRO_RECIPIENT_KEY_MISMATCH".into());
        }
        seal_rvna1_v2(
            root,
            &introducer.address(),
            recipient_addr,
            &hex::encode(intro_id),
            chain_index,
            plaintext_note,
            nonce,
        )
    }

    pub fn open_note(
        &self,
        recipient: &Identity,
        introducer_pub: &[u8; 32],
    ) -> Result<Vec<u8>, String> {
        let _ = (recipient, introducer_pub);
        Err(INTRO_SESSION_REQUIRED.into())
    }

    pub fn open_note_with_atsam_root(
        &self,
        recipient: &Identity,
        introducer_pub: &[u8; 32],
        root: &[u8; 32],
    ) -> Result<Vec<u8>, String> {
        if self.introducer_pub != *introducer_pub
            || self.recipient_raven_id != recipient.address()
            || self.introducer_raven_id != crate::address::encode_address(introducer_pub)
        {
            return Err("INTRO_IDENTITY_MISMATCH".into());
        }
        unseal_rvna1_v2(
            root,
            &self.note_ciphertext,
            &self.introducer_raven_id,
            &self.recipient_raven_id,
            &hex::encode(self.intro_id),
        )
    }
}

#[derive(Default)]
pub struct IntroductionInbox {
    /// Recipient-local encrypted intros (keyed by intro_id hex).
    pub items: Vec<RavenIntroductionV1>,
}

impl IntroductionInbox {
    pub fn add(&mut self, intro: RavenIntroductionV1, now_ms: u64) -> Result<(), String> {
        intro.verify(now_ms)?;
        if self.items.iter().any(|i| i.intro_id == intro.intro_id) {
            return Ok(()); // dedup
        }
        self.items.push(intro);
        Ok(())
    }

    pub fn for_subject_alias(&self, alias: &str, now_ms: u64) -> Vec<&RavenIntroductionV1> {
        let want = alias.trim().trim_start_matches('@').to_lowercase();
        self.items
            .iter()
            .filter(|i| {
                i.verify(now_ms).is_ok()
                    && i.subject_aliases
                        .iter()
                        .any(|a| a.trim().trim_start_matches('@').eq_ignore_ascii_case(&want))
            })
            .collect()
    }
}
