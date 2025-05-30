import 'dart:async';
import 'package:e2e_app/models.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class ChatState {
  static final ChatState _instance = ChatState._internal();
  factory ChatState() => _instance;
  ChatState._internal();
  
  String? currentUserId;
  String? currentUserDisplayName;
  WebSocketChannel? channel;
  StreamController<Message>? _messageController;
  StreamController<Set<String>>? _onlineUsersController;
  StreamController<Map<String, Set<String>>>? _typingUsersController;
  
  Stream<Message> get messageStream {
    _messageController??= StreamController<Message>.broadcast();
    return _messageController!.stream;
  }
  
  Stream<Set<String>> get onlineUsersStream {
    _onlineUsersController ??= StreamController<Set<String>>.broadcast();
    return _onlineUsersController!.stream;
  }
  
  Stream<Map<String, Set<String>>> get typingUsersStream {
    _typingUsersController ??= StreamController<Map<String, Set<String>>>.broadcast();
    return _typingUsersController!.stream;
  }
  
  final Map<String, List<Message>> _messages = {};
  final Set<String> _onlineUsers = {};
  final Map<String, Set<String>> _typingUsers = {};
  
  void addMessage(String chatId, Message message) {
    if (!_messages.containsKey(chatId)) {
      _messages[chatId] = [];
    }
    _messages[chatId]!.add(message);
    
    if (_messageController?.isClosed != false) {
      _messageController = StreamController<Message>.broadcast();
    }
    _messageController!.add(message);
  }
  
  List<Message> getMessages(String chatId) {
    return _messages[chatId] ?? [];
  }
  
  void updateOnlineUsers(String userId, bool isOnline) {
    if (isOnline) {
      _onlineUsers.add(userId);
    } else {
      _onlineUsers.remove(userId);
    }
    
    if (_onlineUsersController?.isClosed != false) {
      _onlineUsersController = StreamController<Set<String>>.broadcast();
    }
    _onlineUsersController!.add(Set.from(_onlineUsers));
  }
  
  void updateTypingUser(String chatId, String userId, bool isTyping) {
    if (!_typingUsers.containsKey(chatId)) {
      _typingUsers[chatId] = {};
    }
    
    if (isTyping) {
      _typingUsers[chatId]!.add(userId);
    } else {
      _typingUsers[chatId]!.remove(userId);
    }
    
    if (_typingUsersController?.isClosed != false) {
      _typingUsersController = StreamController<Map<String, Set<String>>>.broadcast();
    }
    _typingUsersController!.add(Map.from(_typingUsers));
  }
  
  void closeWebSocket() {
    channel?.sink.close();
    channel = null;
  }
  
  void dispose() {
    _messageController?.close();
    _onlineUsersController?.close();
    _typingUsersController?.close();
    closeWebSocket();
    
    _messages.clear();
    _onlineUsers.clear();
    _typingUsers.clear();
    currentUserId = null;
    currentUserDisplayName = null;
  }
  
  void resetControllers() {
    if (_messageController?.isClosed == true) {
      _messageController = StreamController<Message>.broadcast();
    }
    if (_onlineUsersController?.isClosed == true) {
      _onlineUsersController = StreamController<Set<String>>.broadcast();
    }
    if (_typingUsersController?.isClosed == true) {
      _typingUsersController = StreamController<Map<String, Set<String>>>.broadcast();
    }
  }
}