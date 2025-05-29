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
        self.remote_public_key: Optional[bytes] = None  # Track remote public key
        self.skipped_message_keys: Dict[Tuple[bytes, int], bytes] = {}


class DoubleRatchetAlgoImpl:
    def __init__(self, state: RatchetState):
        self.state = state

    def _dh_ratchet_send(self, remotes_public_key: bytes):
        """Perform DH ratchet for sending (creates new sending chain)"""
        print(f"DH Ratchet SEND with remote key: {base64.b64encode(remotes_public_key[:8]).decode()}...")
        
        # Save current sending chain length
        self.state.previous_chain_length = self.state.message_number_send
        self.state.message_number_send = 0
        
        # Generate new key pair
        self.state.ratchet_private_key, self.state.ratchet_public_key = CryptoUtils.generate_key_pair()
        
        # Perform DH with remote public key
        dh_send = CryptoUtils.preform_diff_hellman_agreement(self.state.ratchet_private_key, remotes_public_key)
        
        # Derive new root key and sending chain key
        kdf_rk_input = self.state.root_key + dh_send
        kdf_output = CryptoUtils.perform_key_derivation_using_hkdf(kdf_rk_input, b'RatchetStep', 64)
        
        self.state.root_key = kdf_output[:32]
        self.state.chain_key_send = kdf_output[32:]
        
        print(f"DH Ratchet SEND completed: new root_key and chain_key_send")

    def _dh_ratchet_receive(self, remotes_public_key: bytes):
        """Perform DH ratchet for receiving (creates new receiving chain)"""
        print(f"DH Ratchet RECEIVE with remote key: {base64.b64encode(remotes_public_key[:8]).decode()}...")
        
        # Reset receiving chain
        self.state.message_number_recv = 0
        self.state.remote_public_key = remotes_public_key
        
        # Perform DH with remote public key using our current private key
        dh_recv = CryptoUtils.preform_diff_hellman_agreement(self.state.ratchet_private_key, remotes_public_key)
        
        # Derive new root key and receiving chain key
        kdf_rk_input = self.state.root_key + dh_recv
        kdf_output = CryptoUtils.perform_key_derivation_using_hkdf(kdf_rk_input, b'RatchetStep', 64)
        
        self.state.root_key = kdf_output[:32]
        self.state.chain_key_recv = kdf_output[32:]
        
        print(f"DH Ratchet RECEIVE completed: new root_key and chain_key_recv")
        
    def init_alice(self, shared_secret: bytes, bob_signed_prekey: bytes):
        """Initialize as Alice (sender of first message)"""
        print(f"Alice init: shared_secret={len(shared_secret)} bytes")
        
        # Derive initial root key
        self.state.root_key = CryptoUtils.perform_key_derivation_using_hkdf(shared_secret, b'RootKey', ROOT_KEY_LENGTH)
        
        # Store Bob's public key
        self.state.remote_public_key = bob_signed_prekey
        
        # Alice performs a sending DH ratchet to get her first sending chain
        self._dh_ratchet_send(bob_signed_prekey)
        
        print(f"Alice initialized with first sending chain")

    def init_bob(self, shared_secret: bytes, bob_key_pair: Tuple[x25519.X25519PrivateKey, bytes], 
                 alice_ratchet_public_key: Optional[bytes] = None):
        """Initialize as Bob (receiver of first message)"""
        print(f"Bob init: shared_secret={len(shared_secret)} bytes")
        
        # Derive initial root key
        self.state.root_key = CryptoUtils.perform_key_derivation_using_hkdf(shared_secret, b'RootKey', ROOT_KEY_LENGTH)
        
        # Bob's signed prekey is his initial ratchet key
        self.state.ratchet_private_key = bob_key_pair[0]
        self.state.ratchet_public_key = bob_key_pair[1]
        
        # If we have Alice's ratchet public key, set up receiving chain
        if alice_ratchet_public_key:
            print(f"Bob setting up receiving chain with Alice's key")
            self.state.remote_public_key = alice_ratchet_public_key
            self._dh_ratchet_receive(alice_ratchet_public_key)
        
        print(f"Bob initialized, ready to receive")

    def _symmetric_ratchet(self, chain_key: bytes) -> Tuple[bytes, bytes]:
        """Advance the symmetric ratchet"""
        if not isinstance(chain_key, bytes):
            raise ValueError(f"Chain key must be bytes, got {type(chain_key)}")
        
        print(f"Symmetric ratchet: chain_key={len(chain_key)} bytes")
        
        # Derive message key and next chain key
        message_key = CryptoUtils.perform_key_derivation_using_hkdf(chain_key + b'\x01', b'MessageKey', 32)
        next_chain_key = CryptoUtils.perform_key_derivation_using_hkdf(chain_key + b'\x02', b'ChainKey', CHAIN_KEY_LENGTH)
        
        print(f"Symmetric ratchet output: message_key={len(message_key)} bytes, next_chain_key={len(next_chain_key)} bytes")
        
        return message_key, next_chain_key
    
    def encrypt(self, plaintext: bytes) -> Tuple[bytes, bytes, int]:
        """Encrypt a message"""
        # If we don't have a sending chain, we need to do a sending DH ratchet
        if self.state.chain_key_send is None:
            print("No sending chain key, performing DH ratchet for sending")
            if self.state.remote_public_key is None:
                raise Exception("Cannot encrypt: no remote public key")
            
            self._dh_ratchet_send(self.state.remote_public_key)
        
        print(f"Encrypting with chain_key_send={len(self.state.chain_key_send)} bytes")
        
        # Advance sending chain
        message_key, self.state.chain_key_send = self._symmetric_ratchet(self.state.chain_key_send)
        
        # Encrypt the message
        ciphertext = CryptoUtils.encrypt(message_key, plaintext)
        
        # Get current message number and increment
        current_number = self.state.message_number_send
        self.state.message_number_send += 1
        
        print(f"Message encrypted, number: {current_number}, ratchet_key: {base64.b64encode(self.state.ratchet_public_key[:8]).decode()}...")
        
        return ciphertext, self.state.ratchet_public_key, current_number

    def decrypt(self, ciphertext: bytes, remote_public_key: bytes, message_number: int) -> bytes:
        """Decrypt a message"""
        print(f"Decrypting message {message_number} with remote_key: {base64.b64encode(remote_public_key[:8]).decode()}...")
        
        # Check if we have a skipped message key
        key_id = (remote_public_key, message_number)
        if key_id in self.state.skipped_message_keys:
            message_key = self.state.skipped_message_keys.pop(key_id)
            print(f"Using skipped message key")
            return CryptoUtils.decrypt(message_key, ciphertext)
        
        # Check if this is a new ratchet public key
        if self.state.remote_public_key != remote_public_key:
            print(f"New ratchet public key detected")
            
            # Skip any remaining messages in current receiving chain
            if self.state.chain_key_recv is not None and self.state.remote_public_key is not None:
                # Skip remaining messages in the old chain
                max_skip = self.state.previous_chain_length if hasattr(self.state, 'previous_chain_length') else 1000
                self._skip_message_keys(self.state.remote_public_key, 
                                      self.state.message_number_recv, 
                                      max_skip)
            
            # Perform receiving DH ratchet
            self._dh_ratchet_receive(remote_public_key)
        
        # Skip any messages we missed in this chain
        self._skip_message_keys(remote_public_key, self.state.message_number_recv, message_number)
        
        # Derive message key
        if self.state.chain_key_recv is None:
            raise Exception("No receiving chain key")
            
        message_key, self.state.chain_key_recv = self._symmetric_ratchet(self.state.chain_key_recv)
        self.state.message_number_recv = message_number + 1
        
        # Decrypt
        plaintext = CryptoUtils.decrypt(message_key, ciphertext)
        print(f"Message decrypted successfully")
        
        return plaintext

    def _skip_message_keys(self, public_key: Optional[bytes], start: int, until: int):
        """Skip message keys for messages we haven't received yet"""
        if self.state.chain_key_recv is None:
            print(f"No receive chain to skip")
            return
            
        if public_key is None:
            print(f"No public key to skip with")
            return
            
        if start + 1000 < until:
            raise Exception("Too many messages to skip")
        
        if until <= start:
            return
            
        print(f"Skipping messages {start} to {until-1}")
        
        chain_key = self.state.chain_key_recv
        for i in range(start, until):
            message_key, chain_key = self._symmetric_ratchet(chain_key)
            self.state.skipped_message_keys[(public_key, i)] = message_key
            
        self.state.chain_key_recv = chain_key


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
    ) -> bytes:
        """Calculate X3DH shared secret as Alice (sender)"""
        print("Calculating X3DH agreement (Alice side)")
        
        # DH calculations
        dh1 = CryptoUtils.preform_diff_hellman_agreement(alice_identity_key, bob_bundle.signed_prekey)
        dh2 = CryptoUtils.preform_diff_hellman_agreement(alice_ephemeral_key, bob_bundle.identity_key)
        dh3 = CryptoUtils.preform_diff_hellman_agreement(alice_ephemeral_key, bob_bundle.signed_prekey)
        
        # Concatenate DH outputs
        diff_hellman_concat = dh1 + dh2 + dh3
        
        if bob_bundle.one_time_prekey:
            dh4 = CryptoUtils.preform_diff_hellman_agreement(alice_ephemeral_key, bob_bundle.one_time_prekey)
            diff_hellman_concat += dh4
            
        # Derive shared secret
        shared_secret = CryptoUtils.perform_key_derivation_using_hkdf(diff_hellman_concat, b'X3DHSharedSecret', 32)
        print(f"X3DH shared secret (Alice): {len(shared_secret)} bytes")
        return shared_secret
    
    @staticmethod
    def calculate_agreement_bob(
        bob_identity_key: x25519.X25519PrivateKey,
        bob_signed_prekey: x25519.X25519PrivateKey,
        bob_one_time_prekey: Optional[x25519.X25519PrivateKey],
        alice_identity_key: bytes,
        alice_ephemeral_key: bytes
    ) -> bytes:
        """Calculate X3DH shared secret as Bob (receiver)"""
        print("Calculating X3DH agreement (Bob side)")
        
        # DH calculations (same as Alice but with Bob's private keys)
        dh1 = CryptoUtils.preform_diff_hellman_agreement(bob_signed_prekey, alice_identity_key)
        dh2 = CryptoUtils.preform_diff_hellman_agreement(bob_identity_key, alice_ephemeral_key)
        dh3 = CryptoUtils.preform_diff_hellman_agreement(bob_signed_prekey, alice_ephemeral_key)

        # Concatenate DH outputs
        diff_hellman_concat = dh1 + dh2 + dh3
        
        if bob_one_time_prekey:
            dh4 = CryptoUtils.preform_diff_hellman_agreement(bob_one_time_prekey, alice_ephemeral_key)
            diff_hellman_concat += dh4
            
        # Derive shared secret
        shared_secret = CryptoUtils.perform_key_derivation_using_hkdf(diff_hellman_concat, b'X3DHSharedSecret', 32)
        print(f"X3DH shared secret (Bob): {len(shared_secret)} bytes")
        return shared_secret