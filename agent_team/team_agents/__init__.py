"""RDAP — Raven Distributed Agent Protocol: A2A agents secured with RVN1."""

from __future__ import annotations

__version__ = '1.0.1'

import sys
from pathlib import Path


def _bootstrap_protocol_path() -> None:
    """Make the raven_protocol reference importable from any repo layout."""
    for base in Path(__file__).resolve().parents:
        ref = base / 'protocol' / 'reference'
        if ref.is_dir() and str(ref) not in sys.path:
            sys.path.insert(0, str(ref))
            return


_bootstrap_protocol_path()
