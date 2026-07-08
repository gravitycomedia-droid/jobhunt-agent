import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/health_status.dart';
import '../models/resume_profile.dart';

/// Golden Rule 1 (see CLAUDE.md): the phone never talks to Gemini/Supabase/etc
/// directly — it only ever talks to OUR FastAPI server. This class is the one
/// place that knows the server's base URL and how to call it. Every screen
/// goes through here instead of calling `http` directly, so when Brick 9 adds
/// auth headers, there's exactly one file to touch.
class ApiClient {
  /// Emulators/simulators can't see "localhost" the way your laptop does —
  /// each points somewhere different to reach the machine running this code:
  ///   - Android emulator: 10.0.2.2 (a special alias back to the host)
  ///   - iOS simulator / web / desktop: localhost works directly
  /// A physical device would need your laptop's LAN IP instead — not handled
  /// here, that's a later-brick concern once we deploy to Render.
  static String get _baseUrl {
    if (kIsWeb) return 'http://localhost:8000';
    if (Platform.isAndroid) return 'http://10.0.2.2:8000';
    return 'http://localhost:8000';
  }

  /// `Future<HealthStatus>` means "a HealthStatus that isn't ready yet, but
  /// will be" — Dart's version of a Promise. `async` marks this function as
  /// one that can `await` other Futures without blocking the UI thread; while
  /// we're waiting on the network, Flutter keeps rendering frames normally.
  /// This is the FlutterFlow "API Call" action node, hand-written.
  Future<HealthStatus> fetchHealth() async {
    final uri = Uri.parse('$_baseUrl/health');

    // `await` pauses THIS function (not the whole app) until the response
    // arrives, then resumes with the result assigned to `response`.
    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('Server returned ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['error'] != null) {
      throw Exception(body['error'].toString());
    }

    return HealthStatus.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Uploads a resume PDF for parsing. `MultipartRequest` is Dart's way of
  /// building a multipart/form-data POST — the same wire format a browser
  /// uses for a file-upload `<form>`, just constructed in code instead of
  /// dragged onto a FlutterFlow upload widget.
  Future<ResumeProfile> parseResume(List<int> pdfBytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/resume/parse');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        pdfBytes,
        filename: filename,
        contentType: MediaType('application', 'pdf'),
      ));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ResumeProfile.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// PATCHes the (possibly hand-edited) profile back to the server.
  Future<ResumeProfile> updateProfile(ResumeProfile profile) async {
    final uri = Uri.parse('$_baseUrl/resume/profile/${profile.id}');
    final response = await http.patch(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(profile.toJson()),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ResumeProfile.fromJson(body['data'] as Map<String, dynamic>);
  }

  String _extractErrorDetail(String responseBody, int statusCode) {
    try {
      final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
      return decoded['detail']?.toString() ?? 'Server returned $statusCode';
    } catch (_) {
      return 'Server returned $statusCode';
    }
  }
}
