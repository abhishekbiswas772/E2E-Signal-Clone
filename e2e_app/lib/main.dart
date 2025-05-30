import 'package:e2e_app/auth_screen.dart';
import 'package:e2e_app/chat_screen.dart';
import 'package:e2e_app/chat_state.dart';
import 'package:e2e_app/home_screen.dart';
import 'package:e2e_app/profile_screen.dart';
import 'package:e2e_app/splash_screen.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(SignalChatApp());
}

class SignalChatApp extends StatefulWidget {
  const SignalChatApp({super.key});

  @override
  State<SignalChatApp> createState() => _SignalChatAppState();
}

class _SignalChatAppState extends State<SignalChatApp> with WidgetsBindingObserver {
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ChatState().dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        ChatState().closeWebSocket();
        break;
      case AppLifecycleState.resumed:
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Signal Chat',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => SplashScreen(),
        '/auth': (context) => AuthScreen(),
        '/home': (context) => HomeScreen(),
        '/chat': (context) => ChatScreen(),
        '/profile': (context) => ProfileScreen(),
      },
      debugShowCheckedModeBanner: false,
    );
  }
}