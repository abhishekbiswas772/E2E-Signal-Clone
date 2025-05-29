import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;


class ApiService {
  static final String baseUrl = kIsWeb ? 'http://localhost:8000' : (Platform.isIOS) ? 'http://localhost:8000' :'http://10.0.2.2:8000';
  
  static Future<Map<String, dynamic>> register(String username, String displayName) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'display_name': displayName,
      }),
    );
    
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else if (response.statusCode == 400) {
      final userResponse = await http.get(
        Uri.parse('$baseUrl/api/users/$username'),
      );
      if (userResponse.statusCode == 200) {
        return jsonDecode(userResponse.body);
      }
    }
    throw Exception('Failed to register user');
  }
  
  static Future<List<dynamic>> getAllUsers() async {
    final response = await http.get(Uri.parse('$baseUrl/api/users'));
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    throw Exception('Failed to load users');
  }
}