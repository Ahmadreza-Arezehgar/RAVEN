//! Terminal / UI string sanitization — ANSI CSI and bidi overrides.
//!
//! Checklist §26 / abuse tests: identity spoofing via bidirectional controls
//! or escape sequences in aliases / message previews must be neutralized.

/// Strip ANSI CSI / OSC-ish escape sequences (ESC [ ... final-byte).
pub fn strip_ansi(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b {
            i += 1;
            if i < bytes.len() && (bytes[i] == b'[' || bytes[i] == b']') {
                let start = bytes[i];
                i += 1;
                while i < bytes.len() {
                    let c = bytes[i];
                    i += 1;
                    if start == b'[' && (0x40..=0x7e).contains(&c) {
                        break;
                    }
                    if start == b']' && (c == 0x07 || c == b'\\') {
                        break;
                    }
                }
                continue;
            }
            // lone ESC — drop
            continue;
        }
        out.push(bytes[i] as char);
        // Only push valid single-byte here; for UTF-8 copy char-wise instead.
        i += 1;
    }
    // Re-do properly with chars for UTF-8 safety:
    strip_ansi_chars(input)
}

fn strip_ansi_chars(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            match chars.peek().copied() {
                Some('[') => {
                    chars.next();
                    for d in chars.by_ref() {
                        if ('\u{40}'..='\u{7e}').contains(&d) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    chars.next();
                    for d in chars.by_ref() {
                        if d == '\u{07}' || d == '\\' {
                            break;
                        }
                    }
                }
                _ => {}
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// Unicode bidi / isolate controls that can spoof order in terminals.
const BIDI_CONTROLS: &[char] = &[
    '\u{202A}', // LRE
    '\u{202B}', // RLE
    '\u{202C}', // PDF
    '\u{202D}', // LRO
    '\u{202E}', // RLO
    '\u{2066}', // LRI
    '\u{2067}', // RLI
    '\u{2068}', // FSI
    '\u{2069}', // PDI
    '\u{200E}', // LRM
    '\u{200F}', // RLM
];

pub fn strip_bidi(input: &str) -> String {
    input
        .chars()
        .filter(|c| !BIDI_CONTROLS.contains(c))
        .collect()
}

/// Sanitize for terminal display (aliases, previews, doctor output).
pub fn sanitize_terminal_text(input: &str) -> String {
    let stripped = strip_bidi(&strip_ansi(input));
    stripped
        .chars()
        .filter(|c| {
            // Drop C0 controls except TAB/LF/CR; drop DEL and C1.
            let u = *c as u32;
            if u == 0x09 || u == 0x0a || u == 0x0d {
                return true;
            }
            if u < 0x20 || u == 0x7f || (0x80..=0x9f).contains(&u) {
                return false;
            }
            true
        })
        .collect()
}

/// True if input contained dangerous controls before sanitization.
pub fn had_dangerous_controls(input: &str) -> bool {
    sanitize_terminal_text(input) != input
        || input
            .chars()
            .any(|c| c == '\u{1b}' || BIDI_CONTROLS.contains(&c))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_ansi_color() {
        let s = "\u{1b}[31mRED\u{1b}[0m";
        assert_eq!(sanitize_terminal_text(s), "RED");
    }

    #[test]
    fn strips_bidi_override() {
        // RLO can reverse displayed order: spoof "alice" as something else in some UIs.
        let s = "evila\u{202E}ecila".to_string();
        let clean = sanitize_terminal_text(&s);
        assert!(!clean.contains('\u{202E}'));
        assert_eq!(clean, "evilaecila");
        assert!(had_dangerous_controls(&s));
    }

    #[test]
    fn clean_passthrough() {
        assert_eq!(sanitize_terminal_text("hello bob"), "hello bob");
        assert!(!had_dangerous_controls("hello bob"));
    }

    #[test]
    fn strips_nul_and_c0() {
        let s = "ok\u{0000}bad\u{0007}x";
        assert_eq!(sanitize_terminal_text(s), "okbadx");
        assert!(had_dangerous_controls(s));
    }
}
