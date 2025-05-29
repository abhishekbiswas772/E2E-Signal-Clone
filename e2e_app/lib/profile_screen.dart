import 'package:e2e_app/chat_state.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    try {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Logging out...'),
            ],
          ),
        ),
      );

      // Close WebSocket connection first
      ChatState().closeWebSocket();
      
      // Clear shared preferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      
      // Dispose ChatState completely (only on logout)
      ChatState().dispose();
      
      // Close loading dialog
      Navigator.of(context).pop();
      
      // Navigate to auth screen and clear navigation stack
      Navigator.pushNamedAndRemoveUntil(context, '/auth', (route) => false);
    } catch (e) {
      // Close loading dialog if there's an error
      Navigator.of(context).pop();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error logging out: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Profile'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 50,
              backgroundColor: Colors.blue,
              child: Text(
                ChatState().currentUserDisplayName?[0].toUpperCase() ?? '?',
                style: TextStyle(
                  fontSize: 36,
                  color: Colors.white,
                ),
              ),
            ),
            SizedBox(height: 16),
            Text(
              ChatState().currentUserDisplayName ?? 'Unknown User',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '@${ChatState().currentUserId ?? 'unknown'}',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
            SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () => _logout(context),
              icon: Icon(Icons.logout),
              label: Text('Logout'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                minimumSize: Size(120, 48),
              ),
            ),
          ],
        ),
      ),
    );
  }
}