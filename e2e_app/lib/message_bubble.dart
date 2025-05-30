import 'package:e2e_app/models.dart';
import 'package:flutter/material.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  
  const MessageBubble({super.key, required this.message});
  
  bool get _isEncrypted => message.content.startsWith('🔐');
  
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: message.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: message.isMe 
                    ? (_isEncrypted ? Colors.green[600] : Colors.blue[600])
                    : Colors.grey.shade200,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(message.isMe ? 16 : 4),
                  bottomRight: Radius.circular(message.isMe ? 4 : 16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 2,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!message.isMe && message.isGroup)
                    Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          if (_isEncrypted)
                            Icon(
                              Icons.security,
                              size: 12,
                              color: Colors.green[700],
                            ),
                          if (_isEncrypted) SizedBox(width: 4),
                          Text(
                            message.senderId,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: message.isMe ? Colors.white70 : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isEncrypted && !message.isMe)
                        Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Icon(
                            Icons.lock,
                            size: 14,
                            color: Colors.green[700],
                          ),
                        ),
                      Flexible(
                        child: Text(
                          message.content,
                          style: TextStyle(
                            color: message.isMe ? Colors.white : Colors.black87,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                  
                  SizedBox(height: 6),
                  
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isEncrypted)
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (message.isMe ? Colors.white : Colors.green[100])?.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.security,
                                size: 10,
                                color: message.isMe ? Colors.white70 : Colors.green[600],
                              ),
                              SizedBox(width: 2),
                              Text(
                                'E2E',
                                style: TextStyle(
                                  fontSize: 8,
                                  color: message.isMe ? Colors.white70 : Colors.green[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      
                      if (_isEncrypted) SizedBox(width: 8),
                      
                      // Timestamp
                      Text(
                        '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontSize: 11,
                          color: message.isMe ? Colors.white70 : Colors.black54,
                        ),
                      ),
                      
                      if (message.isMe) ...[
                        SizedBox(width: 4),
                        Icon(
                          Icons.done_all,
                          size: 12,
                          color: _isEncrypted ? Colors.white70 : Colors.blue[200],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            
            // Additional encryption info for encrypted messages
            if (_isEncrypted)
              Padding(
                padding: EdgeInsets.only(
                  top: 2,
                  left: message.isMe ? 0 : 16,
                  right: message.isMe ? 16 : 0,
                ),
                child: Text(
                  message.isMe ? 'Encrypted and sent' : 'Encrypted message',
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.green[600],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}