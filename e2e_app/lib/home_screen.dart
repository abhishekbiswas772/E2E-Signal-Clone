import 'dart:convert';
import 'dart:io';

import 'package:e2e_app/chat_state.dart';
import 'package:e2e_app/models.dart';
import 'package:e2e_app/service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<User> _users = [];
  bool _isLoading = true;
  String? _loadError;
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
    _connectWebSocket();
  }
  
  Future<void> _loadData() async {
    print('🔄 Loading users...');
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    
    try {
      final users = await ApiService.getAllUsers();
      print('📊 Loaded ${users.length} users: ${users.map((u) => u['user_id']).join(', ')}');
      
      if (mounted) {
        setState(() {
          _users = users.map((u) => User.fromJson(u)).toList();
          _isLoading = false;
        });
        print('✅ Users set in state: ${_users.map((u) => u.userId).join(', ')}');
      }
    } catch (e) {
      print('❌ Error loading users: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadError = e.toString();
        });
      }
    }
  }
  
  void _connectWebSocket() {
    final wsUrl = kIsWeb ? 'ws://localhost:8000/ws' : (Platform.isIOS) ? 'ws://localhost:8000/ws' :'ws://10.0.2.2:8000/ws';
    print('🔌 Connecting to WebSocket: $wsUrl for user: ${ChatState().currentUserId}');
    
    try {
      ChatState().channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      
      // Send authentication message
      ChatState().channel!.sink.add(jsonEncode({
        'type': 'auth',
        'user_id': ChatState().currentUserId,
      }));
      
      ChatState().channel!.stream.listen(
        (data) {
          print('📨 WebSocket received: $data');
          try {
            final message = jsonDecode(data);
            _handleWebSocketMessage(message);
          } catch (e) {
            print('❌ Error parsing WebSocket message: $e');
          }
        },
        onError: (error) {
          print('❌ WebSocket error: $error');
          _reconnectWebSocket();
        },
        onDone: () {
          print('🔌 WebSocket connection closed');
          _reconnectWebSocket();
        },
      );
    } catch (e) {
      print('❌ Error connecting to WebSocket: $e');
      _reconnectWebSocket();
    }
  }
  
  void _handleWebSocketMessage(Map<String, dynamic> message) {
    if (!mounted) return;
    
    final type = message['type'];
    print('📨 Handling WebSocket message type: $type');
    
    try {
      switch (type) {
        case 'auth_success':
          print('🔐 Authentication successful - Encryption enabled');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.security, color: Colors.white),
                    SizedBox(width: 8),
                    Text('🔐 Connected & Encrypted'),
                  ],
                ),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 2),
              ),
            );
          }
          break;
          
        case 'encrypted_message':
          // Received an encrypted message - request decryption
          final data = message['data'];
          print('📨 Encrypted message received from ${data['sender_id']}');
          
          // Check if we're currently in chat with this sender
          final currentRoute = ModalRoute.of(context)?.settings.name;
          final routeArgs = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
          final isInChatWithSender = currentRoute == '/chat' && routeArgs?['chatId'] == data['sender_id'];
          
          // Only decrypt if not in chat (chat screen will handle its own decryption)
          if (!isInChatWithSender) {
            _requestMessageDecryption(data);
          }
          break;
          
        case 'decrypted_message':
          // Received decrypted message content
          final data = message['data'];
          final chatMessage = Message(
            id: data['id'],
            senderId: data['sender_id'],
            content: '🔐 ${data['content']}', // Add lock emoji to show it was encrypted
            timestamp: DateTime.fromMillisecondsSinceEpoch((data['timestamp'] * 1000).round()),
            isMe: data['is_me'] ?? false,
          );
          print('🔓 Message decrypted from ${data['sender_id']}: ${data['content']}');
          
          // Add message to chat state
          ChatState().addMessage(data['sender_id'], chatMessage);
          
          // Only show notification if not currently in that chat
          final currentRoute = ModalRoute.of(context)?.settings.name;
          final routeArgs = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
          final isInChatWithSender = currentRoute == '/chat' && routeArgs?['chatId'] == data['sender_id'];
          
          if (!isInChatWithSender && mounted) {
            // Show notification for new message
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.message, color: Colors.white),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'New message from ${data['sender_id']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                backgroundColor: Colors.blue,
                duration: Duration(seconds: 2),
                action: SnackBarAction(
                  label: 'View',
                  textColor: Colors.white,
                  onPressed: () {
                    // Find the user to get display name
                    final user = _users.firstWhere(
                      (u) => u.userId == data['sender_id'],
                      orElse: () => User(userId: data['sender_id'], displayName: data['sender_id'], isOnline: false),
                    );
                    
                    Navigator.pushNamed(
                      context,
                      '/chat',
                      arguments: {
                        'chatId': data['sender_id'],
                        'title': user.displayName,
                        'isGroup': false,
                      },
                    );
                  },
                ),
              ),
            );
          }
          break;
          
        case 'presence':
          final data = message['data'];
          print('👤 Presence update: ${data['user_id']} is ${data['status']}');
          ChatState().updateOnlineUsers(data['user_id'], data['status'] == 'online');
          if (mounted) {
            setState(() {
              // Force rebuild to update UI
            });
          }
          break;
          
        case 'typing':
          final data = message['data'];
          ChatState().updateTypingUser(data['sender_id'], data['sender_id'], data['is_typing']);
          break;
          
        case 'message_sent':
          print('✅ Encrypted message sent successfully');
          break;
          
        case 'error':
          print('❌ WebSocket error: ${message['message']}');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('❌ Error: ${message['message']}'),
                backgroundColor: Colors.red,
              ),
            );
          }
          break;
          
        case 'decryption_error':
          print('🔐❌ Decryption error: ${message['data']['message']}');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('🔐 Decryption failed'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          break;
          
        default:
          print('❓ Unknown message type: $type');
      }
    } catch (e) {
      print('❌ Error handling WebSocket message: $e');
    }
  }
  
  void _requestMessageDecryption(Map<String, dynamic> encryptedData) {
    // Request the backend to decrypt the message
    if (ChatState().channel != null) {
      try {
        // Check if this is the first message from this sender
        final senderId = encryptedData['sender_id'];
        final isFirstMessage = encryptedData['is_first_message'] ?? false;
        
        ChatState().channel!.sink.add(jsonEncode({
          'type': 'decrypt_message',
          'message_id': encryptedData['id'],
          'sender_id': senderId,
          'encrypted_content': encryptedData['encrypted_content'],
          'ephemeral_public_key': encryptedData['ephemeral_public_key'],
          'message_number': encryptedData['message_number'],
          'timestamp': encryptedData['timestamp'],
          'is_first_message': isFirstMessage,
        }));
        print('🔓 Requesting decryption for message from ${encryptedData['sender_id']} (first: $isFirstMessage)');
      } catch (e) {
        print('❌ Error requesting decryption: $e');
      }
    }
  }
  
  void _reconnectWebSocket() {
    if (!mounted) return;
    
    Future.delayed(Duration(seconds: 3), () {
      if (mounted) {
        print('🔄 Attempting to reconnect WebSocket...');
        _connectWebSocket();
      }
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.security, size: 20),
            SizedBox(width: 8),
            Text('Signal Chat E2E'),
            SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: (ChatState().channel != null) ? Colors.green : Colors.red,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          tabs: [
            Tab(text: 'Chats', icon: Icon(Icons.chat)),
            Tab(text: 'Groups', icon: Icon(Icons.group)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _loadData,
          ),
          IconButton(
            icon: Icon(Icons.person),
            onPressed: () => Navigator.pushNamed(context, '/profile'),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Chats Tab
          _buildChatsTab(),
          
          // Groups Tab
          _buildGroupsTab(),
        ],
      ),
      floatingActionButton: _tabController.index == 0
          ? FloatingActionButton(
              child: Icon(Icons.security),
              onPressed: () {
                _showUserSelectionDialog();
              },
            )
          : null,
    );
  }
  
  Widget _buildChatsTab() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading users...'),
          ],
        ),
      );
    }
    
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red),
            SizedBox(height: 16),
            Text('Failed to load users'),
            SizedBox(height: 8),
            Text(_loadError!, style: TextStyle(color: Colors.grey)),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadData,
              child: Text('Retry'),
            ),
          ],
        ),
      );
    }
    
    if (_users.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No other users found'),
            SizedBox(height: 8),
            Text('Register more users to start chatting'),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadData,
              child: Text('Refresh'),
            ),
          ],
        ),
      );
    }
    
    print('🏗️ Building chat list with ${_users.length} users');
    
    return RefreshIndicator(
      onRefresh: _loadData,
      child: StreamBuilder<Set<String>>(
        stream: ChatState().onlineUsersStream,
        builder: (context, onlineSnapshot) {
          print('👥 Online users: ${onlineSnapshot.data?.join(', ') ?? 'none'}');
          
          return ListView.builder(
            itemCount: _users.length,
            itemBuilder: (context, index) {
              final user = _users[index];
              print('👤 Building tile for user: ${user.userId}, current user: ${ChatState().currentUserId}');
              
              if (user.userId == ChatState().currentUserId) {
                print('⏭️ Skipping current user: ${user.userId}');
                return SizedBox.shrink();
              }
              
              final isOnline = onlineSnapshot.data?.contains(user.userId) ?? false;
              print('📱 User ${user.userId} online status: $isOnline');
              
              return ListTile(
                leading: Stack(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.blue,
                      child: Text(user.displayName[0].toUpperCase()),
                    ),
                    if (isOnline)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    // Encryption indicator
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: Colors.green[800],
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.lock,
                          size: 10,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                title: Row(
                  children: [
                    Text(user.displayName),
                    SizedBox(width: 4),
                    Icon(Icons.security, size: 12, color: Colors.green[700]),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          isOnline ? 'Online' : 'Offline',
                          style: TextStyle(
                            color: isOnline ? Colors.green : Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '• End-to-end encrypted',
                          style: TextStyle(
                            color: Colors.green[600],
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    // Show last message preview
                    StreamBuilder<Message>(
                      stream: ChatState().messageStream,
                      builder: (context, msgSnapshot) {
                        final messages = ChatState().getMessages(user.userId);
                        if (messages.isNotEmpty) {
                          final lastMessage = messages.last;
                          return Text(
                            lastMessage.content,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          );
                        }
                        return SizedBox.shrink();
                      },
                    ),
                  ],
                ),
                trailing: StreamBuilder<Message>(
                  stream: ChatState().messageStream,
                  builder: (context, msgSnapshot) {
                    final messageCount = ChatState().getMessages(user.userId).length;
                    if (messageCount > 0) {
                      return Container(
                        padding: EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          messageCount.toString(),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      );
                    }
                    return Icon(Icons.chevron_right, color: Colors.grey);
                  },
                ),
                onTap: () {
                  print('💬 Opening chat with: ${user.userId}');
                  Navigator.pushNamed(
                    context,
                    '/chat',
                    arguments: {
                      'chatId': user.userId,
                      'title': user.displayName,
                      'isGroup': false,
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
  
  Widget _buildGroupsTab() {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: Column(
        children: [
          Container(
            margin: EdgeInsets.all(16),
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green[200]!),
            ),
            child: Row(
              children: [
                Icon(Icons.security, color: Colors.green[700]),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'End-to-End Encryption',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.green[800],
                        ),
                      ),
                      Text(
                        'All messages are encrypted using Double Ratchet algorithm with X3DH key exchange',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.green[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: () async {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('🔐 Encrypted group creation not implemented yet')),
                );
              },
              icon: Icon(Icons.group_add),
              label: Text('Create Encrypted Group'),
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 48),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  void _showUserSelectionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.security, color: Colors.green),
            SizedBox(width: 8),
            Text('Start Encrypted Chat'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: _users.isEmpty 
            ? Text('No users available')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: _users.length,
                itemBuilder: (context, index) {
                  final user = _users[index];
                  if (user.userId == ChatState().currentUserId) {
                    return SizedBox.shrink();
                  }
                  
                  return ListTile(
                    leading: Stack(
                      children: [
                        CircleAvatar(
                          child: Text(user.displayName[0].toUpperCase()),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Icon(Icons.lock, size: 12, color: Colors.green),
                        ),
                      ],
                    ),
                    title: Text(user.displayName),
                    subtitle: Text('End-to-end encrypted', style: TextStyle(fontSize: 10)),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.pushNamed(
                        context,
                        '/chat',
                        arguments: {
                          'chatId': user.userId,
                          'title': user.displayName,
                          'isGroup': false,
                        },
                      );
                    },
                  );
                },
              ),
        ),
      ),
    );
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}