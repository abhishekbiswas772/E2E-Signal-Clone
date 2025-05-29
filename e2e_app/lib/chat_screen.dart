import 'dart:async';
import 'dart:convert';
import 'package:e2e_app/chat_state.dart';
import 'package:e2e_app/message_bubble.dart';
import 'package:e2e_app/models.dart';
import 'package:flutter/material.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  late String chatId;
  late String title;
  late bool isGroup;
  List<String>? members;
  Timer? _typingTimer;
  StreamSubscription? _messageSubscription;
  List<Message> _messages = [];
  
  @override
  void initState() {
    super.initState();
    // Listen to new messages and update local state
    _messageSubscription = ChatState().messageStream.listen((message) {
      if (mounted) {
        setState(() {
          _messages = ChatState().getMessages(chatId);
        });
      }
    });
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
    chatId = args['chatId'];
    title = args['title'];
    isGroup = args['isGroup'] ?? false;
    members = args['members'];
    
    // Load existing messages
    setState(() {
      _messages = ChatState().getMessages(chatId);
    });
  }
  
  void _sendMessage() {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;
    
    final message = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: ChatState().currentUserId!,
      content: content,
      timestamp: DateTime.now(),
      isMe: true,
      isGroup: isGroup,
      groupId: isGroup ? chatId : null,
    );
    
    // Add message to local state immediately for better UX
    try {
      ChatState().addMessage(chatId, message);
      setState(() {
        _messages = ChatState().getMessages(chatId);
      });
    } catch (e) {
      print('Error adding message locally: $e');
    }
    
    // Send message via WebSocket
    if (ChatState().channel != null) {
      try {
        ChatState().channel!.sink.add(jsonEncode({
          'type': 'send_message',
          'recipient_id': chatId,
          'content': content,
          'is_group': isGroup,
        }));
        print('Message sent via WebSocket: $content');
      } catch (e) {
        print('Error sending message via WebSocket: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to send message'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } else {
      print('WebSocket not connected');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Not connected. Please check your connection.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
    
    _messageController.clear();
  }
  
  void _handleTyping(String value) {
    _typingTimer?.cancel();
    
    if (value.isNotEmpty && ChatState().channel != null) {
      try {
        ChatState().channel!.sink.add(jsonEncode({
          'type': 'typing',
          'recipient_id': chatId,
          'is_typing': true,
        }));
        
        _typingTimer = Timer(Duration(seconds: 2), () {
          if (ChatState().channel != null) {
            try {
              ChatState().channel!.sink.add(jsonEncode({
                'type': 'typing',
                'recipient_id': chatId,
                'is_typing': false,
              }));
            } catch (e) {
              print('Error sending typing false indicator: $e');
            }
          }
        });
      } catch (e) {
        print('Error sending typing indicator: $e');
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: (ChatState().channel != null) ? Colors.green : Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: 4),
                Text(
                  (ChatState().channel != null) ? 'Connected' : 'Disconnected',
                  style: TextStyle(fontSize: 10),
                ),
                if (isGroup && members != null) ...[
                  Text(' • ', style: TextStyle(fontSize: 10)),
                  Text(
                    '${members!.length} members',
                    style: TextStyle(fontSize: 10),
                  ),
                ],
              ],
            ),
          ],
        ),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          if (isGroup)
            IconButton(
              icon: Icon(Icons.group_add),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Add members not implemented yet')),
                );
              },
            ),
          IconButton(
            icon: Icon(Icons.info_outline),
            onPressed: () {
              _showChatInfo();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: Colors.grey,
                        ),
                        SizedBox(height: 16),
                        Text(
                          'No messages yet. Say hello!',
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[_messages.length - 1 - index];
                      return Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: MessageBubble(message: message),
                      );
                    },
                  ),
          ),
          
          // Typing indicator
          StreamBuilder<Map<String, Set<String>>>(
            stream: ChatState().typingUsersStream,
            builder: (context, snapshot) {
              final typingUsers = snapshot.data?[chatId] ?? {};
              if (typingUsers.isNotEmpty && !typingUsers.contains(ChatState().currentUserId)) {
                return Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
                        ),
                      ),
                      SizedBox(width: 8),
                      Text(
                        '${typingUsers.join(', ')} ${typingUsers.length > 1 ? 'are' : 'is'} typing...',
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                );
              }
              return SizedBox.shrink();
            },
          ),
          
          // Message input
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 4,
                  offset: Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                      ),
                      onChanged: _handleTyping,
                      onSubmitted: (_) => _sendMessage(),
                      maxLines: null,
                    ),
                  ),
                  SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: Colors.blue,
                    child: IconButton(
                      icon: Icon(Icons.send, color: Colors.white),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  void _showChatInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Chat Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Chat with: $title'),
            Text('Chat ID: $chatId'),
            Text('Is Group: ${isGroup ? 'Yes' : 'No'}'),
            if (members != null)
              Text('Members: ${members!.length}'),
            SizedBox(height: 16),
            Text('Messages: ${_messages.length}'),
            Text('Connection: ${(ChatState().channel != null) ? 'Connected' : 'Disconnected'}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }
  
  @override
  void dispose() {
    _typingTimer?.cancel();
    _messageSubscription?.cancel();
    _messageController.dispose();
    super.dispose();
  }
}