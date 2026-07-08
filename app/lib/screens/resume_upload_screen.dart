import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import 'profile_review_screen.dart';

/// Roughly the FlutterFlow "Upload File" action + a button, hand-written.
class ResumeUploadScreen extends StatefulWidget {
  const ResumeUploadScreen({super.key});

  @override
  State<ResumeUploadScreen> createState() => _ResumeUploadScreenState();
}

class _ResumeUploadScreenState extends State<ResumeUploadScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isUploading = false;
  String? _errorMessage;

  Future<void> _pickAndUpload() async {
    // `withData: true` is required on web (there's no real filesystem path
    // to read from later), and it's simplest to just always ask for bytes.
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );

    // `result` is nullable (`FilePickerResult?`) because the user might
    // cancel the picker instead of choosing a file — that's a normal case,
    // not an error, so we just return quietly.
    if (result == null) return;

    final bytes = result.files.single.bytes;
    if (bytes == null) {
      setState(() => _errorMessage = 'Could not read the selected file.');
      return;
    }

    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      final profile = await _apiClient.parseResume(bytes, result.files.single.name);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProfileReviewScreen(profile: profile)),
      );
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upload Resume')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_as_pdf_outlined, size: 64),
            const SizedBox(height: 16),
            const Text('Upload your resume as a PDF to get started.'),
            const SizedBox(height: 24),
            if (_isUploading)
              const CircularProgressIndicator()
            else
              ElevatedButton.icon(
                onPressed: _pickAndUpload,
                icon: const Icon(Icons.upload_file),
                label: const Text('Choose PDF'),
              ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
