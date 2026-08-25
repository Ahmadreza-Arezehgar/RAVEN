//! Full Braid transition-agent codes (design §5.1).

/// Canonical Full Braid state-machine agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum BraidAgent {
    KeysUnsampled = 0,
    KeysSampled = 1,
    HeaderSent = 2,
    Ct1Received = 3,
    EkSentCt1Received = 4,
    NoHeaderReceived = 5,
    HeaderReceived = 6,
    Ct1Sampled = 7,
    EkReceivedCt1Sampled = 8,
    Ct1Acknowledged = 9,
    Ct2Sampled = 10,
    Terminal = 14,
}

impl BraidAgent {
    /// Strictly decode a registered agent code.
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            AGENT_KEYS_UNSAMPLED => Some(Self::KeysUnsampled),
            AGENT_KEYS_SAMPLED => Some(Self::KeysSampled),
            AGENT_HEADER_SENT => Some(Self::HeaderSent),
            AGENT_CT1_RECEIVED => Some(Self::Ct1Received),
            AGENT_EK_SENT_CT1_RECEIVED => Some(Self::EkSentCt1Received),
            AGENT_NO_HEADER_RECEIVED => Some(Self::NoHeaderReceived),
            AGENT_HEADER_RECEIVED => Some(Self::HeaderReceived),
            AGENT_CT1_SAMPLED => Some(Self::Ct1Sampled),
            AGENT_EK_RECEIVED_CT1_SAMPLED => Some(Self::EkReceivedCt1Sampled),
            AGENT_CT1_ACKNOWLEDGED => Some(Self::Ct1Acknowledged),
            AGENT_CT2_SAMPLED => Some(Self::Ct2Sampled),
            AGENT_TERMINAL => Some(Self::Terminal),
            _ => None,
        }
    }

    pub const fn code(self) -> u8 {
        self as u8
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::KeysUnsampled => "KeysUnsampled",
            Self::KeysSampled => "KeysSampled",
            Self::HeaderSent => "HeaderSent",
            Self::Ct1Received => "Ct1Received",
            Self::EkSentCt1Received => "EkSentCt1Received",
            Self::NoHeaderReceived => "NoHeaderReceived",
            Self::HeaderReceived => "HeaderReceived",
            Self::Ct1Sampled => "Ct1Sampled",
            Self::EkReceivedCt1Sampled => "EkReceivedCt1Sampled",
            Self::Ct1Acknowledged => "Ct1Acknowledged",
            Self::Ct2Sampled => "Ct2Sampled",
            Self::Terminal => "Terminal",
        }
    }
}

pub const AGENT_KEYS_UNSAMPLED: u8 = BraidAgent::KeysUnsampled as u8;
pub const AGENT_KEYS_SAMPLED: u8 = BraidAgent::KeysSampled as u8;
pub const AGENT_HEADER_SENT: u8 = BraidAgent::HeaderSent as u8;
pub const AGENT_CT1_RECEIVED: u8 = BraidAgent::Ct1Received as u8;
pub const AGENT_EK_SENT_CT1_RECEIVED: u8 = BraidAgent::EkSentCt1Received as u8;
pub const AGENT_NO_HEADER_RECEIVED: u8 = BraidAgent::NoHeaderReceived as u8;
pub const AGENT_HEADER_RECEIVED: u8 = BraidAgent::HeaderReceived as u8;
pub const AGENT_CT1_SAMPLED: u8 = BraidAgent::Ct1Sampled as u8;
pub const AGENT_EK_RECEIVED_CT1_SAMPLED: u8 = BraidAgent::EkReceivedCt1Sampled as u8;
pub const AGENT_CT1_ACKNOWLEDGED: u8 = BraidAgent::Ct1Acknowledged as u8;
pub const AGENT_CT2_SAMPLED: u8 = BraidAgent::Ct2Sampled as u8;
pub const AGENT_TERMINAL: u8 = BraidAgent::Terminal as u8;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_codes_and_names_match_design() {
        let expected = [
            (AGENT_KEYS_UNSAMPLED, "KeysUnsampled"),
            (AGENT_KEYS_SAMPLED, "KeysSampled"),
            (AGENT_HEADER_SENT, "HeaderSent"),
            (AGENT_CT1_RECEIVED, "Ct1Received"),
            (AGENT_EK_SENT_CT1_RECEIVED, "EkSentCt1Received"),
            (AGENT_NO_HEADER_RECEIVED, "NoHeaderReceived"),
            (AGENT_HEADER_RECEIVED, "HeaderReceived"),
            (AGENT_CT1_SAMPLED, "Ct1Sampled"),
            (AGENT_EK_RECEIVED_CT1_SAMPLED, "EkReceivedCt1Sampled"),
            (AGENT_CT1_ACKNOWLEDGED, "Ct1Acknowledged"),
            (AGENT_CT2_SAMPLED, "Ct2Sampled"),
            (AGENT_TERMINAL, "Terminal"),
        ];

        for (code, name) in expected {
            let agent = BraidAgent::from_code(code).expect("registered agent");
            assert_eq!(agent.code(), code);
            assert_eq!(agent.name(), name);
        }
        assert!(BraidAgent::from_code(11).is_none());
        assert!(BraidAgent::from_code(13).is_none());
        assert!(BraidAgent::from_code(15).is_none());
    }
}
