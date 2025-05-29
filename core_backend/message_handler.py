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
            raise ValueError("Sender not found")
            
        # For now, we'll skip the full encryption and just create a simple message
        message = EncryptedMessage(
            id=secrets.token_hex(16),
            sender_id=sender_id,
            recipient_id=recipient_id,
            encrypted_content=content.encode('utf-8'),  # Simplified
            ephemeral_public_key=None,
            previous_chain_length=0,
            message_number=0,
            timestamp=time.time(),
            self_destruct_time=self_destruct_seconds,
            message_type="text"
        )
        
        delivered = await self._deliver_message(message, content)
        
        if not delivered:
            await self._store_offline_message(message, content)
        
        if self_destruct_seconds:
            await self._schedule_self_destruct(message.id, self_destruct_seconds)
        
        return message
    
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
    
    async def _deliver_message(self, message: EncryptedMessage, content: str) -> bool:
        if await self.connection_manager.is_user_online(message.recipient_id):
            ws_message = WebSocketMessage(
                type='message',
                data={
                    'id': message.id,
                    'sender_id': message.sender_id,
                    'content': content,  # Send plain content for now
                    'timestamp': message.timestamp,
                    'is_me': False
                }
            )
            success = await self.connection_manager.send_to_user(message.recipient_id, ws_message)
            
            if success:
                await self.redis.setex(
                    f"message_meta:{message.id}",
                    86400,  # 24 hour TTL
                    json.dumps({
                        'sender_id': message.sender_id,
                        'recipient_id': message.recipient_id,
                        'timestamp': message.timestamp
                    })
                )
                
                return True
        
        return False
    
    async def _store_offline_message(self, message: EncryptedMessage, content: str):
        message_data = {
            'id': message.id,
            'sender_id': message.sender_id,
            'content': content,  # Store plain content
            'timestamp': message.timestamp,
            'is_me': False
        }
        
        await self.redis.zadd(
            f"offline_messages:{message.recipient_id}",
            {json.dumps(message_data): message.timestamp}
        )
        print(f"Stored offline message for {message.recipient_id}: {content}")
    
    async def deliver_offline_messages(self, user_id: str):
        messages = await self.redis.zrange(f"offline_messages:{user_id}", 0, -1)
        
        if messages:
            print(f"Delivering {len(messages)} offline messages to {user_id}")
            for msg_data in messages:
                try:
                    msg = json.loads(msg_data)
                    ws_message = WebSocketMessage(type='message', data=msg)
                    success = await self.connection_manager.send_to_user(user_id, ws_message)
                    if success:
                        print(f"Delivered offline message to {user_id}: {msg.get('content', 'N/A')}")
                except Exception as e:
                    print(f"Error delivering offline message: {e}")
            
            # Clear offline messages after delivery
            await self.redis.delete(f"offline_messages:{user_id}")
    
    async def _schedule_self_destruct(self, message_id: str, seconds: int):
        expiry_time = time.time() + seconds
        await self.redis.zadd("self_destruct_messages", {message_id: expiry_time})