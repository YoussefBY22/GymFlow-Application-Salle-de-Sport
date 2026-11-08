import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/config.dart';

class CloudAIService {
  CloudAIService({required this.client, required this.apiKey});

  final http.Client client;
  final String apiKey;

  static const String _model = 'gemini-3.8-flash';
  static const Duration _timeout = Duration(seconds: 30);

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<String> generateText({
    required String system,
    required String prompt,
  }) async {
    if (!isConfigured) {
      throw StateError('La clé Gemini est absente.');
    }

    CloudAIException? unsupportedModelError;
    final models = {_model, ...AppConfig.geminiModels};
    for (final model in models) {
      final http.Response response;
      try {
        response = await client
            .post(
              Uri.parse('${AppConfig.geminiBaseUrl}/$model:generateContent'),
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': apiKey.trim(),
              },
              body: jsonEncode({
                'systemInstruction': {
                  'parts': [
                    {'text': system},
                  ],
                },
                'contents': [
                  {
                    'role': 'user',
                    'parts': [
                      {'text': prompt},
                    ],
                  },
                ],
                'generationConfig': {
                  'temperature': 0.2,
                  'maxOutputTokens': 180,
                },
              }),
            )
            .timeout(_timeout);
      } on TimeoutException {
        throw const CloudAIException(
          'Gemini ne répond pas. Vérifiez la connexion puis réessayez.',
        );
      }

      if (_isModelUnavailable(response.statusCode, response.body)) {
        final message = _apiErrorMessage(response.body);
        unsupportedModelError = CloudAIException(
          'Le modèle Gemini « $model » est indisponible '
          '(${response.statusCode})'
          '${message == null ? '.' : ' : $message'}',
          statusCode: response.statusCode,
        );
        continue;
      }
      if (response.statusCode != 200) {
        final message = _apiErrorMessage(response.body);
        throw CloudAIException(
          'Gemini a refusé la demande (${response.statusCode})'
          '${message == null ? '.' : ' : $message'}',
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) {
        throw const FormatException('Réponse Gemini invalide.');
      }
      final candidates = decoded['candidates'];
      final parts =
          candidates is List && candidates.isNotEmpty && candidates.first is Map
          ? (candidates.first as Map)['content'] is Map
                ? ((candidates.first as Map)['content'] as Map)['parts']
                : null
          : null;
      final text = parts is List
          ? parts
                .whereType<Map>()
                .map((part) => part['text'])
                .whereType<String>()
                .join()
                .trim()
          : '';
      if (text.isEmpty) {
        throw const FormatException('Gemini n’a retourné aucun brouillon.');
      }
      return text;
    }
    throw unsupportedModelError ??
        const CloudAIException('Aucun modèle Gemini n’est disponible.');
  }

  String? _apiErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final message = (decoded['error'] as Map)['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  bool _isModelUnavailable(int statusCode, String body) {
    if (statusCode == 404) return true;
    if (statusCode != 400) return false;
    final message = _apiErrorMessage(body)?.toLowerCase() ?? '';
    return message.contains('model') &&
        (message.contains('not found') ||
            message.contains('not supported') ||
            message.contains('not available') ||
            message.contains('unsupported'));
  }
}

class CloudAIException implements Exception {
  const CloudAIException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
