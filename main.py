from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from typing import Dict, List, Set
from datetime import datetime
import uvicorn
from core_backend.message_backend import MessagingBackend
from response_model import MessageSend, UserInfo, UserRegister, UserResponse
from contextlib import asynccontextmanager

# Create backend instance
backend = MessagingBackend()

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    await backend.initialize()
    print("Backend initialized")
    yield
    # Shutdown
    await backend.shutdown()
    print("Backend shutdown")

app = FastAPI(title="Chat API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

groups: Dict[str, Dict] = {}
user_groups: Dict[str, Set[str]] = {}

@app.post("/api/register", response_model=UserResponse)
async def register_user(user_data: UserRegister):
    try:
        print(f"Registering user: {user_data.username}")
        if user_data.username in backend.message_handler.users:
            # User exists, return existing user info
            user_info = await backend.redis.hgetall(f"user_info:{user_data.username}")
            return UserResponse(
                user_id=user_data.username,
                device_id=backend.message_handler.users[user_data.username].device_id,
                registration_id=backend.message_handler.users[user_data.username].registration_id,
                display_name=user_info.get('display_name', user_data.username),
                created_at=user_info.get('created_at', datetime.utcnow().isoformat())
            )
            
        result = await backend.register_user(user_data.username)
        display_name = user_data.display_name or user_data.username
        await backend.redis.hset(
            f"user_info:{user_data.username}",
            mapping={
                "display_name": display_name,
                "created_at": datetime.utcnow().isoformat()
            }
        )
        return UserResponse(
            user_id=result['user_id'],
            device_id=result['device_id'],
            registration_id=result['registration_id'],
            display_name=display_name,
            created_at=datetime.utcnow().isoformat()
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/users", response_model=List[UserInfo])
async def get_all_users():
    users = []
    
    for user_id in backend.message_handler.users.keys():
        user_info = await backend.redis.hgetall(f"user_info:{user_id}")
        is_online = await backend.connection_manager.is_user_online(user_id)
        users.append(UserInfo(
            user_id=user_id,
            display_name=user_info.get('display_name', user_id),
            is_online=is_online,
            last_seen=user_info.get('last_seen')
        ))
    
    return users

@app.get("/api/users/{user_id}", response_model=UserInfo)
async def get_user(user_id: str):
    if user_id not in backend.message_handler.users:
        raise HTTPException(status_code=404, detail="User not found")
    
    user_info = await backend.redis.hgetall(f"user_info:{user_id}")
    is_online = await backend.connection_manager.is_user_online(user_id)
    return UserInfo(
        user_id=user_id,
        display_name=user_info.get('display_name', user_id),
        is_online=is_online,
        last_seen=user_info.get('last_seen')
    )

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    print("WebSocket connection accepted")
    
    try:
        await backend.handle_websocket(websocket)
    except WebSocketDisconnect:
        print("WebSocket disconnected")
    except Exception as e:
        print(f"WebSocket error: {e}")

@app.post("/api/messages/send")
async def send_message_rest(message: MessageSend, current_user: str = "user"):
    try:
        if message.is_group:
            if message.recipient_id not in groups:
                raise HTTPException(status_code=404, detail="Group not found")
            
            for member in groups[message.recipient_id]["members"]:
                if member != current_user:
                    await backend.message_handler.handle_text_message(
                        sender_id=current_user,
                        recipient_id=member,
                        content=message.content,
                        self_destruct_seconds=message.self_destruct_seconds
                    )
        else:
            await backend.message_handler.handle_text_message(
                sender_id=current_user,
                recipient_id=message.recipient_id,
                content=message.content,
                self_destruct_seconds=message.self_destruct_seconds
            )
        
        return {"message": "Message sent successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "backend": "connected",
        "redis": await backend.redis.ping() if backend.redis else False
    }

if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        log_level="info"
    )