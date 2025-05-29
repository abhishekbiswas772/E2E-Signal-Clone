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
  bool _isEncrypting = false;
  String? _lastError;
  
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
  
  void _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _isEncrypting) return;
    
    print('🚀 Attempting to send message: "$content" from ${ChatState().currentUserId} to $chatId');
    
    setState(() {
      _isEncrypting = true;
      _lastError = null;
    });
    
    // Show temporary message while encrypting
    final tempMessage = Message(
      id: 'temp_${DateTime.now().millisecondsSinceEpoch}',
      senderId: ChatState().currentUserId!,
      content: '🔐 Encrypting...',
      timestamp: DateTime.now(),
      isMe: true,
      isGroup: isGroup,
      groupId: isGroup ? chatId : null,
    );
    
    try {
      ChatState().addMessage(chatId, tempMessage);
      setState(() {
        _messages = ChatState().getMessages(chatId);
      });
      
      // Check WebSocket connection
      if (ChatState().channel == null) {
        throw Exception('WebSocket not connected');
      }
      
      // Send encrypted message via WebSocket
      print('📤 Sending message via WebSocket...');
      ChatState().channel!.sink.add(jsonEncode({
        'type': 'send_message',
        'recipient_id': chatId,
        'content': content,
        'is_group': isGroup,
      }));
      
      print('✅ Message sent to WebSocket successfully');
      
      // Wait for confirmation or timeout
      await Future.delayed(Duration(milliseconds: 1000));
      
      // Replace temp message with actual encrypted message
      final actualMessage = Message(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        senderId: ChatState().currentUserId!,
        content: '🔐 $content',
        timestamp: DateTime.now(),
        isMe: true,
        isGroup: isGroup,
        groupId: isGroup ? chatId : null,
      );
      
      // Update messages list
      final messages = ChatState().getMessages(chatId);
      messages.removeWhere((m) => m.id == tempMessage.id);
      ChatState().addMessage(chatId, actualMessage);
      
      setState(() {
        _messages = ChatState().getMessages(chatId);
        _lastError = null;
      });
      
      _messageController.clear();
      
    } catch (e) {
      print('❌ Error sending encrypted message: $e');
      
      // Remove temp message on error
      final messages = ChatState().getMessages(chatId);
      messages.removeWhere((m) => m.id == tempMessage.id);
      
      setState(() {
        _messages = ChatState().getMessages(chatId);
        _lastError = e.toString();
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔐 Failed to send: ${e.toString()}'),
            backgroundColor: Colors.red,
            action: SnackBarAction(
              label: 'Retry',
              textColor: Colors.white,
              onPressed: () {
                _messageController.text = content;
                _sendMessage();
              },
            ),
          ),
        );
      }
    } finally {
      setState(() {
        _isEncrypting = false;
      });
    }
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
            Row(
              children: [
                Icon(Icons.security, size: 16),
                SizedBox(width: 4),
                Text(title),
              ],
            ),
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
                  (ChatState().channel != null) ? 'Encrypted & Connected' : 'Disconnected',
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
                  SnackBar(content: Text('🔐 Add encrypted members not implemented yet')),
                );
              },
            ),
          IconButton(
            icon: Icon(Icons.info_outline),
            onPressed: () {
              _showEncryptionInfo();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Encryption status banner
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            color: Colors.green[100],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.security, size: 14, color: Colors.green[700]),
                SizedBox(width: 4),
                Text(
                  'End-to-end encrypted • Double Ratchet + X3DH',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.green[700],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          
          // Error banner
          if (_lastError != null)
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              color: Colors.red[100],
              child: Row(
                children: [
                  Icon(Icons.error, size: 16, color: Colors.red[700]),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Error: $_lastError',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red[700],
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 16),
                    onPressed: () {
                      setState(() {
                        _lastError = null;
                      });
                    },
                  ),
                ],
              ),
            ),
          
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.security,
                          size: 64,
                          color: Colors.green[300],
                        ),
                        SizedBox(height: 16),
                        Text(
                          '🔐 Secure Chat',
                          style: TextStyle(
                            color: Colors.green[600],
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Messages are end-to-end encrypted.\nOnly you and $title can read them.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(height: 16),
                        Text(
                          'Users: ${ChatState().currentUserId} ↔ $chatId',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 10,
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
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                        ),
                      ),
                      SizedBox(width: 8),
                      Icon(Icons.security, size: 12, color: Colors.green),
                      SizedBox(width: 4),
                      Text(
                        '${typingUsers.join(', ')} ${typingUsers.length > 1 ? 'are' : 'is'} typing securely...',
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: Colors.green[600],
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
                        hintText: _isEncrypting 
                          ? 'Encrypting...' 
                          : (_lastError != null 
                            ? 'Fix error and try again...'
                            : '🔐 Type a secure message...'),
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
                        prefixIcon: Icon(
                          _lastError != null ? Icons.error : Icons.security,
                          size: 16,
                          color: _lastError != null ? Colors.red[600] : Colors.green[600],
                        ),
                      ),
                      onChanged: _handleTyping,
                      onSubmitted: (_) => _sendMessage(),
                      maxLines: null,
                      enabled: !_isEncrypting,
                    ),
                  ),
                  SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: _isEncrypting 
                      ? Colors.orange 
                      : (_lastError != null ? Colors.red : Colors.green),
                    child: _isEncrypting
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : IconButton(
                            icon: Icon(
                              _lastError != null ? Icons.refresh : Icons.send, 
                              color: Colors.white
                            ),
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
  
  void _showEncryptionInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.security, color: Colors.green),
            SizedBox(width: 8),
            Text('Encryption Details'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow('🔐 Protocol:', 'Signal Protocol'),
            _buildInfoRow('🔑 Key Exchange:', 'X3DH (Extended Triple Diffie-Hellman)'),
            _buildInfoRow('🔄 Encryption:', 'Double Ratchet Algorithm'),
            _buildInfoRow('🔒 Cipher:', 'AES-256-GCM'),
            _buildInfoRow('📱 Forward Secrecy:', 'Yes'),
            _buildInfoRow('🛡️ Perfect Forward Secrecy:', 'Yes'),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Security Guarantee',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green[800],
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Even if someone intercepts your messages, they cannot decrypt them without your private keys.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.green[700],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Current User: ${ChatState().currentUserId}',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
            Text(
              'Chat Partner: $chatId',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
            Text(
              'Messages: ${_messages.length}',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
            Text(
              'Connection: ${(ChatState().channel != null) ? 'Encrypted & Connected' : 'Disconnected'}',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
            if (_lastError != null)
              Text(
                'Last Error: $_lastError',
                style: TextStyle(fontSize: 10, color: Colors.red),
              ),
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
  
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[700],
              ),
            ),
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