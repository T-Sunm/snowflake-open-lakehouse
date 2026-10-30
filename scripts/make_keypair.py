"""Create an RSA key pair for Snowflake key-pair authentication.

Writes the PRIVATE key to .keys/snowflake_rsa_key.p8 (never commit this file)
and prints the statement that registers the PUBLIC key with your Snowflake user.

Usage (from the repository root), with your Snowflake user name:
    uv run --with cryptography python scripts/make_keypair.py <USER>
"""

import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

KEY_PATH = Path(".keys/snowflake_rsa_key.p8")

if len(sys.argv) != 2:
    raise SystemExit("Usage: python scripts/make_keypair.py <SNOWFLAKE_USER>")
user = sys.argv[1]

if KEY_PATH.exists():
    raise SystemExit(f"{KEY_PATH} already exists. Delete it first if you want a new key.")

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

KEY_PATH.parent.mkdir(exist_ok=True)
KEY_PATH.write_bytes(
    key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
)

public_pem = key.public_key().public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
).decode()

# Snowflake wants the base64 body only, without the BEGIN/END lines or newlines.
public_body = "".join(public_pem.strip().splitlines()[1:-1])

print(f"Private key written to {KEY_PATH}")
print()
print("Run this in Snowsight (as SECURITYADMIN):")
print()
print(f"ALTER USER {user} SET RSA_PUBLIC_KEY = '{public_body}';")