import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Result of a conditional GET.
///
/// [notModified] is true when the server answered 304 (our cached ETag matched),
/// meaning the caller should keep whatever it already has and do no work.
@immutable
class FetchResult {
  final bool notModified;
  final Map<String, dynamic>? json;
  final String? etag;

  const FetchResult.notModified()
      : notModified = true,
        json = null,
        etag = null;

  const FetchResult.data(this.json, this.etag) : notModified = false;
}

/// Thin HTTP layer for polling the backend's JSON artifacts.
///
/// Two habits from the plan's guardrails are baked in here:
///  - ETag conditional requests, so an unchanged artifact costs ~one round-trip
///    and no parsing.
///  - Jittered intervals, so a fleet of dashboards doesn't thundering-herd the
///    origin on the same tick.
class BackendClient {
  final http.Client _http;
  final Random _rng = Random();

  /// Per-URL ETag memory for conditional GETs.
  final Map<String, String> _etags = {};

  BackendClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// GET [uri] as JSON, sending `If-None-Match` when we have a prior ETag.
  ///
  /// Throws on network/HTTP failure — callers are expected to catch and fall
  /// back to their last-good state (a wall display never shows a stack trace).
  ///
  /// [bypassCache] is for the manual refresh button, where "no change" is the
  /// wrong answer: it drops the conditional header and adds a throwaway query
  /// param so neither our ETag nor the CDN's `max-age` can hand back the copy
  /// we already have. The ETag itself is still keyed on the clean URL, so
  /// ordinary polling keeps its 304s afterwards.
  Future<FetchResult> getJson(Uri uri, {bool bypassCache = false}) async {
    final key = uri.toString();
    final headers = <String, String>{'Accept': 'application/json'};
    final priorEtag = _etags[key];
    if (priorEtag != null && !bypassCache) headers['If-None-Match'] = priorEtag;

    var target = uri;
    if (bypassCache) {
      headers['Cache-Control'] = 'no-cache';
      target = uri.replace(queryParameters: {
        ...uri.queryParameters,
        '_': DateTime.now().millisecondsSinceEpoch.toString(),
      });
    }

    final resp = await _http
        .get(target, headers: headers)
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 304) {
      return const FetchResult.notModified();
    }
    if (resp.statusCode != 200) {
      throw http.ClientException('HTTP ${resp.statusCode} for $uri', uri);
    }

    final etag = resp.headers['etag'];
    if (etag != null) _etags[key] = etag;

    // utf8.decode(bodyBytes), NOT resp.body. `body` picks its codec from the
    // response's content-type charset, and package:http's fallback when there
    // is none is LATIN-1. The worker labels these `application/json` with no
    // charset, so the only reason non-ASCII text survives today is that http
    // >=1.4 carves out application/json and uses utf8 for it -- and our
    // constraint is ^1.2.2, which still admits versions without that carve-out.
    // JSON is UTF-8 by spec (RFC 8259 s8.1), so decoding the bytes directly is
    // correct regardless of the http version or what the origin labels them.
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object at top level');
    }
    return FetchResult.data(decoded, etag);
  }

  /// POST to one of the backend's `/admin/*` sync triggers, telling it to
  /// re-read its upstream source now instead of waiting for its cron.
  ///
  /// The only write the device ever makes. Given a longer timeout than a plain
  /// GET because the backend does real work here — a Sheets or Calendar API
  /// round-trip — before it answers. Throws on failure.
  ///
  /// Sent without a credential, so the backend runs each trigger for anonymous
  /// callers at most once a minute and answers 429 in between
  /// (worker/src/admin.js). That throws like any other failure, and every
  /// caller pulls the artifact afterwards regardless, so a second tap inside
  /// the minute still shows whatever the first one produced.
  Future<void> post(Uri uri) async {
    final resp = await _http.post(uri).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw http.ClientException('HTTP ${resp.statusCode} for $uri', uri);
    }
  }

  /// Download raw bytes (used for photos). Throws on failure.
  Future<Uint8List> getBytes(Uri uri) async {
    final resp = await _http.get(uri).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw http.ClientException('HTTP ${resp.statusCode} for $uri', uri);
    }
    return resp.bodyBytes;
  }

  /// A [base] interval with ±20% jitter, so many devices spread their load.
  Duration jittered(Duration base) {
    final spread = (base.inMilliseconds * 0.2).round();
    final delta = _rng.nextInt(2 * spread + 1) - spread;
    return Duration(milliseconds: base.inMilliseconds + delta);
  }

  void close() => _http.close();
}
