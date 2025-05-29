from typing import Optional, Dict, Tuple
from cryptography.hazmat.primitives.asymmetric import x25519
from core_backend.crypto_utils import CryptoUtils
from core_backend.constants import *
from core_backend.models import *
import base64


class RatchetState:
    def __init__(self):
        self.root_key: Optional[bytes] = None 
        self.chain_key_send: Optional[bytes] = None 
        self.chain_key_recv: Optional[bytes] = None 
        self.next_header_key_send: Optional[bytes] = None 
        self.next_header_key_recv: Optional[bytes] = None 
        self.message_number_send: int = 0
        self.message_number_recv: int = 0
        self.previous_chain_length: int = 0
        self.ratchet_private_key: Optional[x25519.X25519PrivateKey] = None 
        self.ratchet_public_key: Optional[bytes] = None 
        self.skipped_message_keys: Dict[Tuple[bytes, int], bytes] = {}


class DoubleRatchetAlgoImpl:
    def __init__(self, state: RatchetState):
        self.state = state

    def _dh_ratchet_step(self, remotes_public_key: bytes):
        self.state.previous_chain_length = self.state.message_number_send
        self.state.message_number_send = 0
        self.state.message_number_recv = 0
        self.state.ratchet_private_key, self.state.ratchet_public_key = CryptoUtils.generate_key_pair()
        dh_output = CryptoUtils.preform_diff_hellman_agreement(self.state.ratchet_private_key, remotes_public_key)
        kdf_output = CryptoUtils.perform_key_derivation_using_hkdf(self.state.root_key + dh_output, b'RatchetStep', 64)
        self.state.root_key = kdf_output[:32]
        self.state.chain_key_send = kdf_output[32:]
        
    def init_alice(self, shared_secret: bytes, remote_public_key: bytes):
        self.state.root_key = CryptoUtils.perform_key_derivation_using_hkdf(shared_secret, b'RootKey', ROOT_KEY_LENGTH)
        self._dh_ratchet_step(remote_public_key)

    def init_bob(self, shared_secret: bytes, local_key_pair: Tuple[x25519.X25519PrivateKey, bytes]):
        self.state.root_key = CryptoUtils.perform_key_derivation_using_hkdf(shared_secret, b'RootKey', ROOT_KEY_LENGTH)
        self.state.ratchet_private_key, self.state.ratchet_public_key = local_key_pair

    def _symmetric_ratchet(self, chain_key: bytes):
        message_key = CryptoUtils.perform_key_derivation_using_hkdf(chain_key, b'MessageKey', 32)
        next_chain_key = CryptoUtils.perform_key_derivation_using_hkdf(chain_key, b'ChainKey', CHAIN_KEY_LENGTH)
        return next_chain_key, message_key
    
    def encrypt(self, plaintext: bytes) -> Tuple[bytes, bytes, int]:
        if self.state.chain_key_send is None:
            raise Exception("Chain key not initialized")
            
        self.state.chain_key_send, message_key = self._symmetric_ratchet(self.state.chain_key_send)
        ciphertext = CryptoUtils.encrypt(message_key, plaintext)
        current_number = self.state.message_number_send
        self.state.message_number_send += 1 
        return ciphertext, self.state.ratchet_public_key, current_number

    def decrypt(self, ciphertext: bytes, remote_public_key: bytes, message_number: int) -> bytes:
        # Check if we have a skipped message key for this message
        key_id = (remote_public_key, message_number)
        if key_id in self.state.skipped_message_keys:
            message_key = self.state.skipped_message_keys[key_id]
            del self.state.skipped_message_keys[key_id]
            return CryptoUtils.decrypt(message_key, ciphertext)
        
        if remote_public_key != self.state.ratchet_public_key:
            self._skip_message_keys(self.state.message_number_recv)
            self._dh_ratchet_step(remote_public_key)

        self._skip_message_keys(message_number)
        self.state.chain_key_recv, message_key = self._symmetric_ratchet(self.state.chain_key_recv)
        self.state.message_number_recv += 1
        return CryptoUtils.decrypt(message_key, ciphertext)

    def _skip_message_keys(self, until: int):
        if self.state.chain_key_recv is None:
            return
            
        if self.state.message_number_recv + 1000 < until:
            raise Exception("Too many messages to skip")
        
        while self.state.message_number_recv < until:
            self.state.chain_key_recv, message_key = self._symmetric_ratchet(self.state.chain_key_recv)
            key_id = (self.state.ratchet_public_key, self.state.message_number_recv)
            self.state.skipped_message_keys[key_id] = message_key
            self.state.message_number_recv += 1


class X3DH:
    @staticmethod
    def generate_prekey_bundle(identity_key_pair: Tuple[x25519.X25519PrivateKey, bytes]):
        signed_prekey_pair = CryptoUtils.generate_key_pair()
        one_time_prekeys = []
        for _ in range(PREKEY_BATCH_SIZE):
            otpk_pair = CryptoUtils.generate_key_pair()
            one_time_prekeys.append({
                "public": base64.b64encode(otpk_pair[1]).decode(),
                "private": base64.b64encode(otpk_pair[0].private_bytes_raw()).decode()
            })
        
        signature = CryptoUtils.perform_key_derivation_using_hkdf(
            identity_key_pair[0].private_bytes_raw() + signed_prekey_pair[1],
            b'SignedPreKey',
            64
        )
        
        return {
            "identity_key": base64.b64encode(identity_key_pair[1]).decode(),
            "signed_prekey": {
                "public": base64.b64encode(signed_prekey_pair[1]).decode(),
                "private": base64.b64encode(signed_prekey_pair[0].private_bytes_raw()).decode(),
                "signature": base64.b64encode(signature).decode()
            },
            "one_time_prekeys": one_time_prekeys
        }
    
    @staticmethod
    def calculate_agreement_alice(
        alice_identity_key: x25519.X25519PrivateKey,
        alice_ephemeral_key: x25519.X25519PrivateKey,
        bob_bundle: PublicPreKey
    ):
        dh1 = CryptoUtils.preform_diff_hellman_agreement(alice_identity_key, bob_bundle.signed_prekey)
        dh2 = CryptoUtils.preform_diff_hellman_agreement(alice_ephemeral_key, bob_bundle.identity_key)
        dh3 = CryptoUtils.preform_diff_hellman_agreement(alice_ephemeral_key, bob_bundle.signed_prekey)
        diff_hellman_concat = dh1 + dh2 + dh3
        
        if bob_bundle.one_time_prekey:
            dh4 = CryptoUtils.preform_diff_hellman_agreement(alice_ephemeral_key, bob_bundle.one_time_prekey)
            diff_hellman_concat += dh4
            
        return CryptoUtils.perform_key_derivation_using_hkdf(diff_hellman_concat, b'X3DHSharedSecret', 32)
    
    @staticmethod
    def calculate_agreement_bob(
        bob_identity_key: x25519.X25519PrivateKey,
        bob_signed_prekey: x25519.X25519PrivateKey,
        bob_one_time_prekey: Optional[x25519.X25519PrivateKey],
        alice_identity_key: bytes,
        alice_ephemeral_key: bytes
    ):
        dh1 = CryptoUtils.preform_diff_hellman_agreement(bob_signed_prekey, alice_identity_key)
        dh2 = CryptoUtils.preform_diff_hellman_agreement(bob_identity_key, alice_ephemeral_key)
        dh3 = CryptoUtils.preform_diff_hellman_agreement(bob_signed_prekey, alice_ephemeral_key)

        diff_hellman_concat = dh1 + dh2 + dh3
        if bob_one_time_prekey:
            dh4 = CryptoUtils.preform_diff_hellman_agreement(bob_one_time_prekey, alice_ephemeral_key)
            diff_hellman_concat += dh4
            
        return CryptoUtils.perform_key_derivation_using_hkdf(diff_hellman_concat, b'X3DHSharedSecret', 32)