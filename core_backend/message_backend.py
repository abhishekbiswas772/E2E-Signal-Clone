import base64
import json
import time
from typing import Any, Dict, Optional, List
import asyncio
from core_backend.connection_manager import ConnectionManager
from core_backend.models import WebSocketMessage
from core_backend.users import User
from core_backend.message_handler import MessageHandler
import redis.asyncio as redis
from fastapi import WebSocket, WebSocketDisconnect
from core_backend.constants import *

class MessagingBackend:
    def __init__(self):
        self.redis: Optional[redis.Redis] = None
        self.connection_manager: Optional[ConnectionManager] = None
        self.message_handler: Optional[MessageHandler] = None
        self.pubsub_tasks: List[asyncio.Task] = []
        
    async def initialize(self):
        self.redis = await redis.from_url("redis://localhost:6380", decode_responses=True)
        self.connection_manager = ConnectionManager(self.redis)
        self.message_handler = MessageHandler(self.redis, self.connection_manager)
        self.pubsub_tasks.append(asyncio.create_task(self._handle_self_destruct()))
        self.pubsub_tasks.append(asyncio.create_task(self._handle_presence_updates()))
        print("Signal backend initialized")
    
    async def shutdown(self):
        for task in self.pubsub_tasks:
            task.cancel()
        if self.redis:
            await self.redis.close()
    
    async def register_user(self, user_id: str) -> Dict[str, Any]:
        if user_id in self.message_handler.users:
            raise ValueError("User already exists")
        
        user = User(user_id)
        self.message_handler.users[user_id] = user
        await self.redis.set(
            f"prekey_bundle:{user_id}",
            json.dumps(user.prekey_bundle)
        )
        
        return {
            'user_id': user_id,
            'device_id': user.device_id,
            'registration_id': user.registration_id,
            'identity_key': base64.b64encode(user.identity_key_pair[1]).decode()
        }
    
    async def handle_websocket(self, websocket: WebSocket):
        user_id = None
        try:
            # Wait for authentication message
            auth_msg = await websocket.receive_text()
            auth_data = json.loads(auth_msg)
            
            if auth_data['type'] != 'auth':
                await websocket.send_text(json.dumps({
                    'type': 'error',
                    'message': 'Authentication required'
                }))
                return
            
            user_id = auth_data['user_id']
            print(f"Authenticating user: {user_id}")
            
            # Connect user
            await self.connection_manager.connect(websocket, user_id)
            
            # Send auth success
            await websocket.send_text(json.dumps({
                'type': 'auth_success',
                'user_id': user_id
            }))
            
            # Broadcast this user's online status to all other connected users
            await self._broadcast_presence_to_all_users(user_id, 'online')
            
            # Send current online users to this user
            await self._send_current_online_users(user_id)
            
            # Deliver offline messages
            await self.message_handler.deliver_offline_messages(user_id)
            
            # Main message loop
            while True:
                try:
                    message = await websocket.receive_text()
                    data = json.loads(message)
                    await self._process_websocket_message(user_id, data)
                except WebSocketDisconnect:
                    break
                except json.JSONDecodeError:
                    print(f"Invalid JSON from {user_id}: {message}")
                except Exception as e:
                    print(f"Error processing message from {user_id}: {e}")
                    
        except WebSocketDisconnect:
            print(f"WebSocket disconnected for {user_id}")
        except Exception as e:
            print(f"WebSocket error for {user_id}: {e}")
        finally:
            if user_id:
                await self.connection_manager.disconnect(user_id)
                await self._broadcast_presence_to_all_users(user_id, 'offline')
    
    async def _send_current_online_users(self, user_id: str):
        """Send list of currently online users to the newly connected user"""
        for online_user_id in self.connection_manager.user_connections.keys():
            if online_user_id != user_id:
                presence_message = WebSocketMessage(
                    type='presence',
                    data={
                        'user_id': online_user_id,
                        'status': 'online'
                    }
                )
                await self.connection_manager.send_to_user(user_id, presence_message)
    
    async def _broadcast_presence_to_all_users(self, user_id: str, status: str):
        """Broadcast presence update to all connected users"""
        presence_message = WebSocketMessage(
            type='presence',
            data={
                'user_id': user_id,
                'status': status
            }
        )
        
        print(f"Broadcasting presence: {user_id} is {status}")
        
        # Get all connected users
        for connected_user_id in list(self.connection_manager.user_connections.keys()):
            if connected_user_id != user_id:  # Don't send to self
                success = await self.connection_manager.send_to_user(connected_user_id, presence_message)
                print(f"Sent presence to {connected_user_id}: {success}")
    
    async def _process_websocket_message(self, user_id: str, data: Dict[str, Any]):
        msg_type = data.get('type')
        print(f"Processing message type: {msg_type} from user: {user_id}")
        
        if msg_type == 'send_message':
            try:
                recipient_id = data['recipient_id']
                content = data['content']
                
                # Create a simple message (we're skipping encryption for now to debug)
                message_id = f"{int(time.time() * 1000)}{user_id}{recipient_id}"
                timestamp = time.time()
                
                # Send confirmation to sender
                await self.connection_manager.send_to_user(
                    user_id,
                    WebSocketMessage(
                        type='message_sent',
                        data={'message_id': message_id, 'timestamp': timestamp}
                    )
                )
                
                # Send message to recipient
                message_data = WebSocketMessage(
                    type='message',
                    data={
                        'id': message_id,
                        'sender_id': user_id,
                        'content': content,
                        'timestamp': timestamp,
                        'is_me': False
                    }
                )
                
                success = await self.connection_manager.send_to_user(recipient_id, message_data)
                print(f"Message sent to {recipient_id}: {success}")
                
                if not success:
                    # Store as offline message
                    await self.redis.zadd(
                        f"offline_messages:{recipient_id}",
                        {json.dumps(message_data.data): timestamp}
                    )
                    print(f"Stored offline message for {recipient_id}")
                
            except Exception as e:
                print(f"Error handling text message: {e}")
                await self.connection_manager.send_to_user(
                    user_id,
                    WebSocketMessage(
                        type='error',
                        data={'message': f'Failed to send message: {str(e)}'}
                    )
                )
                
        elif msg_type == 'typing':
            # Forward typing indicator to recipient
            typing_message = WebSocketMessage(
                type='typing',
                data={
                    'sender_id': user_id,
                    'is_typing': data['is_typing']
                }
            )
            await self.connection_manager.send_to_user(data['recipient_id'], typing_message)
            
        elif msg_type == 'delivered':
            # Handle delivery confirmation
            pass
            
        elif msg_type == 'read':
            # Handle read confirmation
            pass
            
        elif msg_type == 'get_prekeys':
            bundle = await self.redis.get(f"prekey_bundle:{data['user_id']}")
            if bundle:
                await self.connection_manager.send_to_user(
                    user_id,
                    WebSocketMessage(
                        type='prekey_bundle',
                        data=json.loads(bundle)
                    )
                )
    
    async def _handle_self_destruct(self):
        while True:
            try:
                current_time = time.time()
                expired = await self.redis.zrangebyscore(
                    "self_destruct_messages", 0, current_time
                )
                
                if expired:
                    for message_id in expired:
                        meta = await self.redis.get(f"message_meta:{message_id}")
                        if meta:
                            data = json.loads(meta)
                            destruction_msg = WebSocketMessage(
                                type='message_destroyed',
                                data={'message_id': message_id}
                            )
                            
                            await self.connection_manager.send_to_user(
                                data['sender_id'], destruction_msg
                            )
                            await self.connection_manager.send_to_user(
                                data['recipient_id'], destruction_msg
                            )
                        await self.redis.delete(f"message_meta:{message_id}")
                    await self.redis.zremrangebyscore(
                        "self_destruct_messages", 0, current_time
                    )
                await asyncio.sleep(1) 
                
            except Exception as e:
                print(f"Error in self-destruct handler: {e}")
                await asyncio.sleep(5)

    async def _handle_presence_updates(self):
        pubsub = self.redis.pubsub()
        await pubsub.subscribe(PRESENCE_CHANNEL)
        
        try:
            async for message in pubsub.listen():
                if message['type'] == 'message':
                    data = json.loads(message['data'])
                    print(f"Presence update: {data}")
        except Exception as e:
            print(f"Error in presence handler: {e}")