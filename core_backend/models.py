from dataclasses import dataclass, field
from typing import Optional, Dict, Any
import time
import json


@dataclass
class PublicPreKey:
    identity_key: bytes
    signed_prekey: bytes
    signed_prekey_signature: bytes
    one_time_prekey: Optional[bytes]
    device_id: str
    registration_id: int


@dataclass
class EncryptedMessage:
    id: str
    sender_id: str
    recipient_id: str
    encrypted_content: bytes
    ephemeral_public_key: Optional[bytes]
    previous_chain_length: int
    message_number: int 
    timestamp: float
    self_destruct_time: Optional[int]
    message_type: str = "text"


@dataclass
class WebSocketMessage:
    type: str 
    data: Dict[str, Any]
    timestamp: float = field(default_factory=time.time)

    def to_json(self) -> str:
        return json.dumps({
            "type": self.type,
            "data": self.data,
            "timestamp": self.timestamp
        })