from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.backends import default_backend
from typing import Tuple, Union
import secrets

class CryptoUtils:
    @staticmethod
    def generate_key_pair() -> Tuple[x25519.X25519PrivateKey, bytes]:
        private_key = x25519.X25519PrivateKey.generate()
        public_key = private_key.public_key().public_bytes_raw()
        return private_key, public_key
    
    @staticmethod
    def preform_diff_hellman_agreement(private_key: x25519.X25519PrivateKey, public_key: bytes) -> bytes:
        peer_public_key = x25519.X25519PublicKey.from_public_bytes(public_key)
        shared_secret = private_key.exchange(peer_public_key)
        return shared_secret
    

    @staticmethod
    def perform_key_derivation_using_hkdf(input_key: bytes, info: bytes, length: int = 32) -> bytes:
        hkdf = HKDF(
            algorithm=hashes.SHA256(),
            length=length,
            salt=b'',
            info=info,
            backend=default_backend()
        )
        return hkdf.derive(input_key)
    

    @staticmethod
    def encrypt(key: bytes, plaintext: Union[str, bytes], associated_data: bytes = b'') -> bytes:
        """Encrypt plaintext using AES-GCM"""
        if isinstance(plaintext, str):
            plaintext = plaintext.encode('utf-8')
        
        aesgcm = AESGCM(key)
        nonce = secrets.token_bytes(12)
        cipher_text = aesgcm.encrypt(nonce, plaintext, associated_data)
        return nonce + cipher_text

    @staticmethod
    def decrypt(key: bytes, ciphertext_with_nonce: bytes, associated_data: bytes = b'') -> bytes:
        """Decrypt ciphertext using AES-GCM"""
        aesgcm = AESGCM(key)
        nonce = ciphertext_with_nonce[:12]
        cipher_text = ciphertext_with_nonce[12:]
        return aesgcm.decrypt(nonce, cipher_text, associated_data)