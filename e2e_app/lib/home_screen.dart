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
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
    _connectWebSocket();
  }
  
  Future<void> _loadData() async {
    try {
      final users = await ApiService.getAllUsers();
      
      if (mounted) {
        setState(() {
          _users = users.map((u) => User.fromJson(u)).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error loading data: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
  
  void _connectWebSocket() {
    final wsUrl = kIsWeb ? 'ws://localhost:8000/ws' : (Platform.isIOS) ? 'ws://localhost:8000/ws' :'ws://10.0.2.2:8000/ws';
    print('Connecting to WebSocket: $wsUrl');
    
    try {
      ChatState().channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      
      // Send authentication message
      ChatState().channel!.sink.add(jsonEncode({
        'type': 'auth',
        'user_id': ChatState().currentUserId,
      }));
      
      ChatState().channel!.stream.listen(
        (data) {
          print('WebSocket received: $data');
          try {
            final message = jsonDecode(data);
            _handleWebSocketMessage(message);
          } catch (e) {
            print('Error parsing WebSocket message: $e');
          }
        },
        onError: (error) {
          print('WebSocket error: $error');
          _reconnectWebSocket();
        },
        onDone: () {
          print('WebSocket connection closed');
          _reconnectWebSocket();
        },
      );
    } catch (e) {
      print('Error connecting to WebSocket: $e');
      _reconnectWebSocket();
    }
  }
  
  void _handleWebSocketMessage(Map<String, dynamic> message) {
    if (!mounted) return;
    
    final type = message['type'];
    print('Handling WebSocket message type: $type');
    
    try {
      switch (type) {
        case 'auth_success':
          print('Authentication successful');
          break;
          
        case 'message':
          final data = message['data'];
          // Only process messages with content (not encrypted ones)
          if (data.containsKey('content')) {
            final chatMessage = Message(
              id: data['id'],
              senderId: data['sender_id'],
              content: data['content'],
              timestamp: DateTime.fromMillisecondsSinceEpoch((data['timestamp'] * 1000).round()),
              isMe: data['is_me'] ?? false,
            );
            print('Adding message from ${data['sender_id']}: ${data['content']}');
            ChatState().addMessage(data['sender_id'], chatMessage);
          }
          break;
          
        case 'presence':
          final data = message['data'];
          print('Presence update: ${data['user_id']} is ${data['status']}');
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
          print('Message sent successfully');
          break;
          
        case 'error':
          print('WebSocket error: ${message['message']}');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error: ${message['message']}'),
                backgroundColor: Colors.red,
              ),
            );
          }
          break;
          
        default:
          print('Unknown message type: $type');
      }
    } catch (e) {
      print('Error handling WebSocket message: $e');
    }
  }
  
  void _reconnectWebSocket() {
    if (!mounted) return;
    
    Future.delayed(Duration(seconds: 3), () {
      if (mounted) {
        print('Attempting to reconnect WebSocket...');
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
            Text('Signal Chat'),
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
            icon: Icon(Icons.person),
            onPressed: () => Navigator.pushNamed(context, '/profile'),
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                // Chats Tab
                RefreshIndicator(
                  onRefresh: _loadData,
                  child: StreamBuilder<Set<String>>(
                    stream: ChatState().onlineUsersStream,
                    builder: (context, onlineSnapshot) {
                      return ListView.builder(
                        itemCount: _users.length,
                        itemBuilder: (context, index) {
                          final user = _users[index];
                          if (user.userId == ChatState().currentUserId) {
                            return SizedBox.shrink();
                          }
                          
                          final isOnline = onlineSnapshot.data?.contains(user.userId) ?? false;
                          
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
                              ],
                            ),
                            title: Text(user.displayName),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isOnline ? 'Online' : 'Offline',
                                  style: TextStyle(
                                    color: isOnline ? Colors.green : Colors.grey,
                                    fontSize: 12,
                                  ),
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
                                    padding: EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.blue,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      messageCount.toString(),
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                      ),
                                    ),
                                  );
                                }
                                return SizedBox.shrink();
                              },
                            ),
                            onTap: () {
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
                ),
                
                // Groups Tab
                RefreshIndicator(
                  onRefresh: _loadData,
                  child: Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.all(16),
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            // Placeholder for group creation
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Group creation not implemented yet')),
                            );
                          },
                          icon: Icon(Icons.add),
                          label: Text('Create New Group'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: Size(double.infinity, 48),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      floatingActionButton: _tabController.index == 0
          ? FloatingActionButton(
              child: Icon(Icons.message),
              onPressed: () {
                _showUserSelectionDialog();
              },
            )
          : null,
    );
  }
  
  void _showUserSelectionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Start New Chat'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _users.length,
            itemBuilder: (context, index) {
              final user = _users[index];
              if (user.userId == ChatState().currentUserId) {
                return SizedBox.shrink();
              }
              
              return ListTile(
                leading: CircleAvatar(
                  child: Text(user.displayName[0].toUpperCase()),
                ),
                title: Text(user.displayName),
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