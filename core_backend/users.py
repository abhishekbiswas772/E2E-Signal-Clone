
from core_backend.crypto_utils import CryptoUtils
from core_backend.double_ratchet_algorithm import X3DH
from typing import Dict, Optional
from core_backend.double_ratchet_algorithm import DoubleRatchetAlgoImpl
import secrets
import time
from websockets.server import WebSocketServerProtocol


class User:
    def __init__(self, user_id: str):
        self.user_id = user_id
        self.identity_key_pair = CryptoUtils.generate_key_pair()
        self.prekey_bundle = X3DH.generate_prekey_bundle(self.identity_key_pair)
        self.sessions: Dict[str, DoubleRatchetAlgoImpl] = {}
        self.device_id = secrets.token_hex(8)
        self.registration_id = secrets.randbits(32)
        self.websocket: Optional[WebSocketServerProtocol] = None
        self.last_seen = time.time()