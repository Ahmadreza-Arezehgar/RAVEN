# tests/test_determinism.py
import subprocess, sys, filecmp, os, shutil, tempfile, pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]  # .../hybrid_messenger
GEN = REPO / "protocol/reference/generate_rvn1.py"
OUT = REPO / "shared-vectors/rvn1"

def test_regeneration_is_byte_identical():
    assert OUT.exists(), "run generate_rvn1.py once before this test"
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([sys.executable, str(GEN), "--out", tmp], check=True)
        tmp_root = pathlib.Path(tmp)
        committed = {f.relative_to(OUT) for f in OUT.rglob("*.json")}
        regenerated = {f.relative_to(tmp_root) for f in tmp_root.rglob("*.json")}
        # Symmetric: a newly-emitted-but-uncommitted vector (or a deleted one) is drift too.
        assert committed == regenerated, f"file set differs: {committed ^ regenerated}"
        for rel in committed:
            assert filecmp.cmp(OUT/rel, tmp_root/rel, shallow=False), f"drift in {rel}"
