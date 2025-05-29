from pydantic import BaseModel
from typing import Optional

class UserRegister(BaseModel):
    username: str
    display_name: Optional[str] = None

class UserResponse(BaseModel):
    user_id: str
    device_id: str
    registration_id: int
    display_name: str
    created_at: str

class MessageSend(BaseModel):
    recipient_id: str
    content: str
    message_type: str = "text" 
    is_group: bool = False
    self_destruct_seconds: Optional[int] = None

class UserInfo(BaseModel):
    user_id: str
    display_name: str
    is_online: bool
    last_seen: Optional[str]
