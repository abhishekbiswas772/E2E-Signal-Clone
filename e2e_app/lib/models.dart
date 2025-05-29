class User {
  final String userId;
  final String displayName;
  final bool isOnline;
  final String? lastSeen;
  
  User({
    required this.userId,
    required this.displayName,
    required this.isOnline,
    this.lastSeen,
  });
  
  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      userId: json['user_id'],
      displayName: json['display_name'],
      isOnline: json['is_online'],
      lastSeen: json['last_seen'],
    );
  }
}

class Message {
  final String id;
  final String senderId;
  final String content;
  final DateTime timestamp;
  final bool isMe;
  final bool isGroup;
  final String? groupId;
  
  Message({
    required this.id,
    required this.senderId,
    required this.content,
    required this.timestamp,
    required this.isMe,
    this.isGroup = false,
    this.groupId,
  });
}


