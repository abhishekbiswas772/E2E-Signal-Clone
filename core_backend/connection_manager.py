from core_backend.models import WebSocketMessage
import time
import redis.asyncio as redis
from typing import Dict
import secrets
from core_backend.constants import *
import json
from fastapi import WebSocket

class ConnectionManager:    
    def __init__(self, redis_client: redis.Redis):
        self.redis = redis_client
        self.active_connections: Dict[str, WebSocket] = {}
        self.user_connections: Dict[str, str] = {}  
        
    async def connect(self, websocket: WebSocket, user_id: str):
        connection_id = secrets.token_hex(8)
        self.active_connections[connection_id] = websocket
        self.user_connections[user_id] = connection_id
        
        await self.redis.publish(PRESENCE_CHANNEL, json.dumps({
            'user_id': user_id,
            'status': 'online',
            'timestamp': time.time()
        }))
        await self.redis.setex(f"presence:{user_id}", 300, "online") 
        print(f"User {user_id} connected with connection {connection_id}")
        
    async def disconnect(self, user_id: str):
        if user_id in self.user_connections:
            connection_id = self.user_connections[user_id]
            if connection_id in self.active_connections:
                del self.active_connections[connection_id]
            del self.user_connections[user_id]
            
            await self.redis.publish(PRESENCE_CHANNEL, json.dumps({
                'user_id': user_id,
                'status': 'offline',
                'timestamp': time.time()
            }))
            await self.redis.delete(f"presence:{user_id}")
            print(f"User {user_id} disconnected")
    
    async def send_to_user(self, user_id: str, message: WebSocketMessage) -> bool:
        if user_id in self.user_connections:
            connection_id = self.user_connections[user_id]
            websocket = self.active_connections.get(connection_id)
            if websocket:
                try:
                    await websocket.send_text(message.to_json())
                    return True
                except Exception as e:
                    print(f"Failed to send message to {user_id}: {e}")
                    await self.disconnect(user_id)
        return False
    
    async def is_user_online(self, user_id: str) -> bool:
        status = await self.redis.get(f"presence:{user_id}")
        return status is not None