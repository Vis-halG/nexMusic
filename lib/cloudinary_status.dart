import 'dart:async';
import 'dart:convert';
import 'dart:io';

class CloudinaryMetric {
  const CloudinaryMetric({this.usage, this.limit, this.usedPercent});
  final double? usage, limit, usedPercent;
  double? get remaining => usage != null && limit != null
      ? (limit! - usage!).clamp(0, double.infinity)
      : null;
  double? get fraction => usage != null && limit != null && limit! > 0
      ? usage! / limit!
      : usedPercent == null
      ? null
      : usedPercent! / 100;
  factory CloudinaryMetric.fromJson(dynamic value) {
    final row = value is Map ? value : const {};
    return CloudinaryMetric(
      usage: _number(row['usage']),
      limit: _number(row['limit']),
      usedPercent: _number(row['usedPercent']),
    );
  }
}

double? _number(dynamic value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

class CloudinaryStatus {
  CloudinaryStatus.fromJson(Map<String, dynamic> json)
    : cloudName = json['cloudName'] as String? ?? '',
      plan = json['plan'] as String?,
      lastUpdated = json['lastUpdated'] as String?,
      fetchedAt = DateTime.tryParse('${json['fetchedAt']}'),
      cached = json['cached'] == true,
      cacheExpiresAt = DateTime.tryParse('${json['cacheExpiresAt']}'),
      manualRefreshAfter = DateTime.tryParse('${json['manualRefreshAfter']}'),
      mediaCount = _number(json['mediaCount'])?.toInt(),
      songCount = _number(json['songCount'])?.toInt(),
      otherMediaCount = _number(json['otherMediaCount'])?.toInt(),
      accountResources = _number(json['accountResources'])?.toInt(),
      requests = _number(json['requests'])?.toInt(),
      storage = CloudinaryMetric.fromJson(json['storage']),
      bandwidth = CloudinaryMetric.fromJson(json['bandwidth']),
      credits = CloudinaryMetric.fromJson(json['credits']),
      transformations = CloudinaryMetric.fromJson(json['transformations']),
      adminApi = CloudinaryMetric.fromJson(_adminMetric(json['adminApi'])),
      adminResetAt = json['adminApi'] is Map
          ? DateTime.tryParse('${json['adminApi']['resetAt']}')
          : null;

  final String cloudName;
  final String? plan, lastUpdated;
  final DateTime? fetchedAt, adminResetAt;
  final bool cached;
  final DateTime? cacheExpiresAt, manualRefreshAfter;
  final int? mediaCount, songCount, otherMediaCount, accountResources, requests;
  final CloudinaryMetric storage, bandwidth, credits, transformations, adminApi;

  static Map<String, double?> _adminMetric(dynamic value) {
    final row = value is Map ? value : const {};
    final limit = _number(row['limit']), remaining = _number(row['remaining']);
    return {
      'limit': limit,
      'usage': limit != null && remaining != null
          ? (limit - remaining).clamp(0, double.infinity)
          : null,
    };
  }
}

class CloudinaryStatusException implements Exception {
  const CloudinaryStatusException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CloudinaryStatusService {
  Future<CloudinaryStatus> load({
    required String workerUrl,
    required String token,
    bool refresh = false,
  }) async {
    final base = Uri.tryParse(workerUrl);
    if (base == null || base.scheme != 'https' || base.host.isEmpty) {
      throw const CloudinaryStatusException(
        'Cloudinary account reporting is not connected yet.',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final request = await client.getUrl(
          base
              .resolve('/cloudinary/status')
              .replace(queryParameters: refresh ? {'refresh': '1'} : null),
        );
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        if (response.statusCode == 401) {
          throw const CloudinaryStatusException(
            'Sign in again to view Cloudinary account usage.',
          );
        }
        if (response.statusCode == 404 ||
            response.statusCode == 405 ||
            response.statusCode == 503) {
          throw const CloudinaryStatusException(
            'Cloudinary account reporting has not been connected yet.',
          );
        }
        if (response.statusCode != 200) {
          throw const CloudinaryStatusException(
            'Cloudinary usage is unavailable. Try refreshing later.',
          );
        }
        final json = jsonDecode(body);
        if (json is! Map<String, dynamic> ||
            json['cloudName'] is! String ||
            json['storage'] is! Map) {
          throw const FormatException('Invalid Cloudinary report');
        }
        return CloudinaryStatus.fromJson(json);
      })().timeout(const Duration(seconds: 25));
    } on CloudinaryStatusException {
      rethrow;
    } catch (_) {
      throw const CloudinaryStatusException(
        'Could not load Cloudinary usage. Check your connection and retry.',
      );
    } finally {
      client.close(force: true);
    }
  }
}
