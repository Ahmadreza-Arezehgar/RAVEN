# tests/test_determinism.py
import subprocess, sys, filecmp, os, shutil, tempfile, pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]  # .../hybrid_messenger
GEN = REPO / "protocol/reference/generate_rvn1.py"
OUT = REPO / "shared-vectors/rvn1"

def test_regeneration_is_byte_identical():
    assert OUT.exists(), "run generate_rvn1.py once before this test"
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([sys.executable, str(GEN), "--out", tmp], check=True)
        # Every file under OUT must be byte-identical to a fresh generation.
        for f in OUT.rglob("*.json"):
            rel = f.relative_to(OUT)
            assert filecmp.cmp(f, pathlib.Path(tmp)/rel, shallow=False), f"drift in {rel}"
