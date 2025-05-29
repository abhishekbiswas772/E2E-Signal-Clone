from typing import Dict, Optional
import json
from core_backend.connection_manager import ConnectionManager
from core_backend.crypto_utils import CryptoUtils
from core_backend.models import EncryptedMessage, PublicPreKey, WebSocketMessage
from core_backend.users import User
import redis.asyncio as redis
import time
from core_backend.constants import *
import secrets
import base64
from core_backend.double_ratchet_algorithm import X3DH, DoubleRatchetAlgoImpl, RatchetState


class MessageHandler:    
    def __init__(self, redis_client: redis.Redis, connection_manager: ConnectionManager):
        self.redis = redis_client
        self.connection_manager = connection_manager
        self.users: Dict[str, User] = {}
        
    async def handle_text_message(self, sender_id: str, recipient_id: str, content: str, 
                                 self_destruct_seconds: Optional[int] = None) -> EncryptedMessage:
        sender = self.users.get(sender_id)
        if not sender:
            raise ValueError(f"Sender {sender_id} not found")
            
        recipient = self.users.get(recipient_id)
        if not recipient:
            raise ValueError(f"Recipient {recipient_id} not found")
            
        print(f"🔐 Processing message: {sender_id} -> {recipient_id}: {content}")
        
        # Check if this is the first message (no session exists)
        is_first_message = recipient_id not in sender.sessions
        
        # Check if sender has a session with recipient
        if is_first_message:
            print(f"📝 No session found, establishing new session {sender_id} -> {recipient_id}")
            await self._establish_sender_session(sender_id, recipient_id)
        
        # Get the sender's session with recipient
        if recipient_id not in sender.sessions:
            raise ValueError(f"Failed to establish session for {sender_id} -> {recipient_id}")
            
        ratchet = sender.sessions[recipient_id]
        
        # Create the plaintext message
        plaintext = json.dumps({
            'type': 'text',
            'content': content,
            'timestamp': time.time(),
            'sender_id': sender_id
        }).encode('utf-8')
        
        print(f"🔒 Encrypting message from {sender_id} to {recipient_id}: {content}")
        
        # Encrypt the message using Double Ratchet
        try:
            ciphertext, ratchet_public_key, message_number = ratchet.encrypt(plaintext)
            print(f"✅ Message encrypted successfully. Message number: {message_number}")
        except Exception as e:
            print(f"❌ Encryption failed: {e}")
            raise ValueError(f"Failed to encrypt message: {e}")
        
        # Create encrypted message
        message = EncryptedMessage(
            id=secrets.token_hex(16),
            sender_id=sender_id,
            recipient_id=recipient_id,
            encrypted_content=ciphertext,
            ephemeral_public_key=ratchet_public_key,  # This is the ratchet public key
            previous_chain_length=ratchet.state.previous_chain_length,
            message_number=message_number,
            timestamp=time.time(),
            self_destruct_time=self_destruct_seconds,
            message_type="text"
        )
        
        # Try to deliver the message
        delivered = await self._deliver_encrypted_message(message, content, is_first_message)
        
        if not delivered:
            await self._store_offline_encrypted_message(message, content)
            print(f"📦 Message stored offline for {recipient_id}")
        
        if self_destruct_seconds:
            await self._schedule_self_destruct(message.id, self_destruct_seconds)
        
        return message
    
    async def _establish_sender_session(self, sender_id: str, recipient_id: str):
        """Establish a session for sender to send to recipient"""
        print(f"🔐 Establishing session: {sender_id} -> {recipient_id}")
        
        sender = self.users.get(sender_id)
        recipient = self.users.get(recipient_id)
        
        if not sender or not recipient:
            raise ValueError("One or both users not found")

        # Get recipient's prekey bundle
        recipient_bundle_data = await self.redis.get(f"prekey_bundle:{recipient_id}")
        
        if not recipient_bundle_data:
            raise ValueError(f"Missing prekey bundle for {recipient_id}")
        
        recipient_bundle_dict = json.loads(recipient_bundle_data)
        
        # Create recipient's bundle
        recipient_bundle = PublicPreKey(
            identity_key=base64.b64decode(recipient_bundle_dict['identity_key']),
            signed_prekey=base64.b64decode(recipient_bundle_dict['signed_prekey']['public']),
            signed_prekey_signature=base64.b64decode(recipient_bundle_dict['signed_prekey']['signature']),
            one_time_prekey=None,
            device_id=recipient.device_id,
            registration_id=recipient.registration_id
        )
        
        # Generate sender's ephemeral key for X3DH
        sender_ephemeral = CryptoUtils.generate_key_pair()
        
        # X3DH: Sender -> Recipient
        shared_secret = X3DH.calculate_agreement_alice(
            sender.identity_key_pair[0],
            sender_ephemeral[0],
            recipient_bundle
        )
        
        # Initialize sender's ratchet as Alice (sender always starts as Alice)
        sender_ratchet = DoubleRatchetAlgoImpl(RatchetState())
        sender_ratchet.init_alice(shared_secret, recipient_bundle.signed_prekey)
        sender.sessions[recipient_id] = sender_ratchet
        
        # Store the X3DH ephemeral key for recipient to use
        await self.redis.setex(
            f"x3dh_ephemeral:{sender_id}:{recipient_id}",
            86400,  # 24 hour TTL
            base64.b64encode(sender_ephemeral[1]).decode()
        )
        
        print(f"✅ Sender session established: {sender_id} -> {recipient_id}")
    
    async def _deliver_encrypted_message(self, message: EncryptedMessage, original_content: str, 
                                        is_first_message: bool = False) -> bool:
        """Deliver encrypted message to recipient"""
        if await self.connection_manager.is_user_online(message.recipient_id):
            # Send the encrypted message data
            message_data = {
                'id': message.id,
                'sender_id': message.sender_id,
                'encrypted_content': base64.b64encode(message.encrypted_content).decode(),
                'ephemeral_public_key': base64.b64encode(message.ephemeral_public_key).decode() if message.ephemeral_public_key else None,
                'previous_chain_length': message.previous_chain_length,
                'message_number': message.message_number,
                'timestamp': message.timestamp,
                'self_destruct_time': message.self_destruct_time,
                'is_first_message': is_first_message  # Include this flag
            }
            
            encrypted_ws_message = WebSocketMessage(
                type='encrypted_message',
                data=message_data
            )
            
            success = await self.connection_manager.send_to_user(message.recipient_id, encrypted_ws_message)
            
            if success:
                # Store message metadata
                await self.redis.setex(
                    f"message_meta:{message.id}",
                    86400,  # 24 hour TTL
                    json.dumps({
                        'sender_id': message.sender_id,
                        'recipient_id': message.recipient_id,
                        'timestamp': message.timestamp,
                        'original_content': original_content  # For debugging
                    })
                )
                print(f"📨 Encrypted message delivered to {message.recipient_id}")
                return True
        
        return False
    
    async def _store_offline_encrypted_message(self, message: EncryptedMessage, original_content: str):
        """Store encrypted message for offline delivery"""
        message_data = {
            'id': message.id,
            'sender_id': message.sender_id,
            'encrypted_content': base64.b64encode(message.encrypted_content).decode(),
            'ephemeral_public_key': base64.b64encode(message.ephemeral_public_key).decode() if message.ephemeral_public_key else None,
            'previous_chain_length': message.previous_chain_length,
            'message_number': message.message_number,
            'timestamp': message.timestamp,
            'self_destruct_time': message.self_destruct_time,
            'type': 'encrypted_message'
        }
        
        await self.redis.zadd(
            f"offline_messages:{message.recipient_id}",
            {json.dumps(message_data): message.timestamp}
        )
        print(f"📦 Stored encrypted offline message for {message.recipient_id}")
    
    async def handle_typing_indicator(self, sender_id: str, recipient_id: str, is_typing: bool):
        await self.redis.publish(f"{TYPING_CHANNEL_PREFIX}{recipient_id}", json.dumps({
            'sender_id': sender_id,
            'is_typing': is_typing,
            'timestamp': time.time()
        }))
        
        ws_message = WebSocketMessage(
            type='typing',
            data={
                'sender_id': sender_id,
                'is_typing': is_typing
            }
        )
        await self.connection_manager.send_to_user(recipient_id, ws_message)
    
    async def handle_message_status(self, message_id: str, status: str, user_id: str):
        message_data = await self.redis.get(f"message_meta:{message_id}")
        if message_data:
            meta = json.loads(message_data)
            sender_id = meta['sender_id']
            
            ws_message = WebSocketMessage(
                type=status, 
                data={
                    'message_id': message_id,
                    'user_id': user_id,
                    'timestamp': time.time()
                }
            )
            await self.connection_manager.send_to_user(sender_id, ws_message)
    
    async def decrypt_message(self, user_id: str, sender_id: str, encrypted_content: bytes, 
                            ephemeral_public_key: bytes, message_number: int, 
                            is_first_message: bool = False) -> str:
        """Decrypt a message for the recipient"""
        print(f"🔓 Decrypting message for {user_id} from {sender_id} (first_message: {is_first_message})")
        
        # Get recipient user
        recipient = self.users.get(user_id)
        if not recipient:
            raise ValueError(f"Recipient {user_id} not found")
        
        # Check if recipient has a session with sender
        if sender_id not in recipient.sessions:
            if is_first_message:
                print(f"📝 First message received, establishing receiver session as Bob")
                # ephemeral_public_key is Alice's ratchet public key for the first message
                alice_ratchet_public_key = ephemeral_public_key
                await self._establish_receiver_session(user_id, sender_id, alice_ratchet_public_key)
            else:
                print(f"❌ No session found and not first message")
                raise ValueError(f"No session found for {user_id} <- {sender_id}")
        
        if sender_id not in recipient.sessions:
            raise ValueError(f"Failed to establish receiving session for {user_id} <- {sender_id}")
        
        ratchet = recipient.sessions[sender_id]
        
        try:
            # Decrypt the message
            decrypted_data = ratchet.decrypt(encrypted_content, ephemeral_public_key, message_number)
            message_data = json.loads(decrypted_data.decode('utf-8'))
            
            print(f"✅ Message decrypted successfully: {message_data['content']}")
            return message_data['content']
            
        except Exception as e:
            print(f"❌ Decryption failed: {e}")
            raise ValueError(f"Decryption failed: {e}")
    
    async def _establish_receiver_session(self, receiver_id: str, sender_id: str, 
                                         alice_ratchet_public_key: bytes):
        """Establish a session for receiver (Bob) to receive from sender (Alice)"""
        print(f"🔐 Establishing receiver session: {receiver_id} <- {sender_id}")
        
        receiver = self.users.get(receiver_id)
        sender = self.users.get(sender_id)
        
        if not receiver or not sender:
            raise ValueError("One or both users not found")
        
        # Get X3DH ephemeral key
        x3dh_ephemeral_data = await self.redis.get(f"x3dh_ephemeral:{sender_id}:{receiver_id}")
        if not x3dh_ephemeral_data:
            raise ValueError(f"Missing X3DH ephemeral key")
        
        alice_x3dh_ephemeral_key = base64.b64decode(x3dh_ephemeral_data)
        
        # Get sender's bundle for X3DH
        sender_bundle_data = await self.redis.get(f"prekey_bundle:{sender_id}")
        if not sender_bundle_data:
            raise ValueError(f"Missing prekey bundle for {sender_id}")
        
        sender_bundle_dict = json.loads(sender_bundle_data)
        
        # Calculate shared secret as Bob
        shared_secret = X3DH.calculate_agreement_bob(
            receiver.identity_key_pair[0],
            receiver.signed_prekey_private,  # Bob's signed prekey private key object
            None,  # No one-time prekey for simplicity
            base64.b64decode(sender_bundle_dict['identity_key']),  # Alice's identity key
            alice_x3dh_ephemeral_key  # Alice's X3DH ephemeral public key
        )
        
        # Initialize receiver's ratchet as Bob
        receiver_ratchet = DoubleRatchetAlgoImpl(RatchetState())
        
        # Get Bob's signed prekey pair for initialization
        signed_prekey_public = base64.b64decode(receiver.prekey_bundle['signed_prekey']['public'])
        
        # Initialize Bob with Alice's ratchet public key
        receiver_ratchet.init_bob(shared_secret, (receiver.signed_prekey_private, signed_prekey_public), 
                                 alice_ratchet_public_key)
        receiver.sessions[sender_id] = receiver_ratchet
        
        print(f"✅ Receiver session established: {receiver_id} <- {sender_id}")
    
    async def deliver_offline_messages(self, user_id: str):
        """Deliver offline encrypted messages"""
        messages = await self.redis.zrange(f"offline_messages:{user_id}", 0, -1)
        
        if messages:
            print(f"📦 Delivering {len(messages)} offline encrypted messages to {user_id}")
            for msg_data in messages:
                try:
                    msg = json.loads(msg_data)
                    ws_message = WebSocketMessage(type=msg.get('type', 'encrypted_message'), data=msg)
                    success = await self.connection_manager.send_to_user(user_id, ws_message)
                    if success:
                        print(f"📨 Delivered offline encrypted message to {user_id}")
                except Exception as e:
                    print(f"❌ Error delivering offline encrypted message: {e}")
            
            # Clear offline messages after delivery
            await self.redis.delete(f"offline_messages:{user_id}")
    
    async def _schedule_self_destruct(self, message_id: str, seconds: int):
        expiry_time = time.time() + seconds
        await self.redis.zadd("self_destruct_messages", {message_id: expiry_time})