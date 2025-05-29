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
        print(f"📝 Registering user: {user_data.username}")
        
        # Check if user already exists
        if user_data.username in backend.message_handler.users:
            print(f"👤 User {user_data.username} already exists, returning existing info")
            # User exists, return existing user info
            user_info = await backend.redis.hgetall(f"user_info:{user_data.username}")
            existing_user = backend.message_handler.users[user_data.username]
            return UserResponse(
                user_id=user_data.username,
                device_id=existing_user.device_id,
                registration_id=existing_user.registration_id,
                display_name=user_info.get('display_name', user_data.username),
                created_at=user_info.get('created_at', datetime.utcnow().isoformat())
            )
            
        # Register new user
        result = await backend.register_user(user_data.username)
        display_name = user_data.display_name or user_data.username
        
        # Store user info in Redis
        await backend.redis.hset(
            f"user_info:{user_data.username}",
            mapping={
                "display_name": display_name,
                "created_at": datetime.utcnow().isoformat()
            }
        )
        
        print(f"✅ User {user_data.username} registered successfully")
        
        return UserResponse(
            user_id=result['user_id'],
            device_id=result['device_id'],
            registration_id=result['registration_id'],
            display_name=display_name,
            created_at=datetime.utcnow().isoformat()
        )
    except ValueError as e:
        print(f"❌ Registration error: {e}")
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        print(f"❌ Unexpected registration error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/users", response_model=List[UserInfo])
async def get_all_users():
    try:
        print(f"📊 Getting all users...")
        users = []
        
        # Get all registered users
        registered_users = list(backend.message_handler.users.keys())
        print(f"👥 Found {len(registered_users)} registered users: {registered_users}")
        
        for user_id in registered_users:
            try:
                # Get user info from Redis
                user_info = await backend.redis.hgetall(f"user_info:{user_id}")
                is_online = await backend.connection_manager.is_user_online(user_id)
                
                user_data = UserInfo(
                    user_id=user_id,
                    display_name=user_info.get('display_name', user_id),
                    is_online=is_online,
                    last_seen=user_info.get('last_seen')
                )
                users.append(user_data)
                print(f"👤 User {user_id}: {user_data.display_name}, online: {is_online}")
                
            except Exception as e:
                print(f"❌ Error getting info for user {user_id}: {e}")
                # Still add the user with basic info
                users.append(UserInfo(
                    user_id=user_id,
                    display_name=user_id,
                    is_online=False,
                    last_seen=None
                ))
        
        print(f"📊 Returning {len(users)} users to client")
        return users
        
    except Exception as e:
        print(f"❌ Error getting all users: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get users: {str(e)}")

@app.get("/api/users/{user_id}", response_model=UserInfo)
async def get_user(user_id: str):
    try:
        print(f"👤 Getting user: {user_id}")
        
        if user_id not in backend.message_handler.users:
            print(f"❌ User {user_id} not found")
            raise HTTPException(status_code=404, detail="User not found")
        
        user_info = await backend.redis.hgetall(f"user_info:{user_id}")
        is_online = await backend.connection_manager.is_user_online(user_id)
        
        result = UserInfo(
            user_id=user_id,
            display_name=user_info.get('display_name', user_id),
            is_online=is_online,
            last_seen=user_info.get('last_seen')
        )
        
        print(f"✅ Found user {user_id}: {result.display_name}, online: {is_online}")
        return result
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Error getting user {user_id}: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get user: {str(e)}")

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    print("🔌 WebSocket connection accepted")
    
    try:
        await backend.handle_websocket(websocket)
    except WebSocketDisconnect:
        print("🔌 WebSocket disconnected")
    except Exception as e:
        print(f"❌ WebSocket error: {e}")

@app.post("/api/messages/send")
async def send_message_rest(message: MessageSend, current_user: str = "user"):
    try:
        print(f"📤 REST API message send: {current_user} -> {message.recipient_id}: {message.content}")
        
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
        print(f"❌ REST API message send error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    try:
        redis_status = await backend.redis.ping() if backend.redis else False
        user_count = len(backend.message_handler.users) if backend.message_handler else 0
        
        return {
            "status": "healthy",
            "backend": "connected",
            "redis": redis_status,
            "registered_users": user_count,
            "online_users": len(backend.connection_manager.user_connections) if backend.connection_manager else 0
        }
    except Exception as e:
        print(f"❌ Health check error: {e}")
        return {
            "status": "unhealthy",
            "error": str(e)
        }

if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        log_level="info"
    )