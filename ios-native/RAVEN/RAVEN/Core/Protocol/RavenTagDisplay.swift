//
//  RavenTagDisplay.swift
//  RAVEN
//
//  Soft Unique Raven Tags (docs/RAVEN_TAG_V1.md) — petname-first labels for
//  the serverless / RavenEnvelopeV1 path. MeshEnvelope default unchanged.
//

import Foundation

/// Three-layer display helper (Zooko's triangle): Layer C petname primary,
/// Layer B public tag subtitle, Layer A address never primary.
enum RavenTagDisplay {
    /// Primary inbox/contact label. Prefers petname; falls back to @tag; address last.
    static func primaryLabel(
        petname: String?,
        publicTag: String?,
        addressOrFallback: String
    ) -> String {
        let pet = (petname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !pet.isEmpty { return pet }
        let tag = normalizeTag(publicTag)
        if !tag.isEmpty { return "@\(tag)" }
        return addressOrFallback
    }

    /// Subtitle under petname (`@ahmad`) — nil when absent or same as primary.
    static func publicTagSubtitle(publicTag: String?, primary: String) -> String? {
        let tag = normalizeTag(publicTag)
        guard !tag.isEmpty else { return nil }
        let sub = "@\(tag)"
        if sub.caseInsensitiveCompare(primary) == .orderedSame { return nil }
        return sub
    }

    static func normalizeTag(_ raw: String?) -> String {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return ""
        }
        if s.hasPrefix("@") { s.removeFirst() }
        return s.lowercased()
    }

    /// When `ravenEnvelopeV1` is ON, prefer petname-first composition for serverless UI.
    static func inboxTitle(
        displayName: String,
        username: String?,
        flaggedServerless: Bool = FeatureFlag.isRavenEnvelopeV1Enabled
    ) -> (title: String, subtitle: String?) {
        if flaggedServerless {
            // Treat displayName as petname (Layer C), username as public tag (Layer B).
            let title = primaryLabel(
                petname: displayName,
                publicTag: username,
                addressOrFallback: displayName
            )
            let sub = publicTagSubtitle(publicTag: username, primary: title)
            return (title, sub)
        }
        // Legacy MeshEnvelope path: keep existing displayName behavior.
        return (displayName, nil)
    }
}
