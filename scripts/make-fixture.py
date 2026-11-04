"""Independent protocol vectors; requires Python cryptography (development only)."""
import base64
import hashlib
import io
import json
from pathlib import Path
import unicodedata
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from PIL import Image

b64 = lambda b: base64.b64encode(b).decode()
key = bytes(range(32))
salt = bytes(range(16))
password = "cafe\u0301-test-password"
kek = hashlib.pbkdf2_hmac("sha256", unicodedata.normalize("NFC", password).encode(), salt, 600000, 32)

def seal(k, n, text, aad):
    nonce = bytes([n]) * 12
    return b64(nonce + AESGCM(k).encrypt(nonce, text, aad.encode()))

text = "来自电脑的内容 😀 e\u0301\n第二行"
prefix = "clipstudio:item:v1:0123456789abcdef:abcdef0123456789:text:"
preview = {"t": text, "n": len(text), "l": 2}
png = io.BytesIO()
Image.new("RGB", (2, 3), (56, 106, 87)).save(png, format="PNG")
vector = {
    "decomposed_passphrase": password,
    "key": b64(key), "text": text,
    "info": {"configured": True, "key_id": "0123456789abcdef", "kdf": "PBKDF2-SHA256", "iterations": 600000,
             "salt": b64(salt), "wrapped_key": seal(kek, 1, key, "clipstudio:key:v1:0123456789abcdef")},
    "item": {"id": 42, "ts": 1793577600, "kind": "text", "source": "windows", "device": "测试电脑",
             "key_id": "0123456789abcdef", "cid": "abcdef0123456789",
             "body": seal(key, 2, text.encode(), prefix + "body"),
             "preview": seal(key, 3, json.dumps(preview, ensure_ascii=False, separators=(",", ":")).encode(), prefix + "preview")},
    "image": b64(png.getvalue()),
    "image_cipher": seal(key, 4, png.getvalue(), "clipstudio:item:v1:0123456789abcdef:1111111111111111:image:body"),
}
path = Path(__file__).resolve().parents[1] / "Tests" / "clip-v1.json"
path.write_text(json.dumps(vector, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(path)
