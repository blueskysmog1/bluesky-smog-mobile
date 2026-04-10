import 'dart:typed_data';
import 'package:dio/dio.dart';

class ApiService {
  static const _base = 'https://api.blueskysmog.net';

  // Singleton — every ApiService() call returns the same instance
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;

  late final Dio _dio;
  String _username = '';
  String _password = '';
  String _token    = '';

  ApiService._internal() : _dio = Dio(BaseOptions(
    baseUrl: _base,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout:    const Duration(seconds: 60),
  ));

  void setCredentials(String username, String password, {String token = ''}) {
    _username = username;
    _password = password;
    _token    = token;
  }

  void setToken(String token) => _token = token;

  /// Auth headers — prefer token, fall back to user/pass
  Map<String, String> get _authHeaders {
    if (_token.isNotEmpty) return {'x-token': _token};
    return {'x-username': _username, 'x-password': _password};
  }

  // ── Auth ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> login(String username, String password) async {
    final res = await _dio.get('/v1/auth/login',
        options: Options(headers: {
          'x-username': username,
          'x-password': password,
        }));
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<Map<String, dynamic>> refreshToken(String token) async {
    final res = await _dio.get('/v1/auth/refresh',
        options: Options(headers: {'x-token': token}));
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required String companyName,
    String address = '',
  }) async {
    final res = await _dio.post('/v1/auth/register', data: {
      'username':     username,
      'password':     password,
      'company_name': companyName,
      'address':      address,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  // ── Sync ──────────────────────────────────────────────────────────

  Future<void> push({
    required String deviceId,
    required List<Map<String, dynamic>> events,
  }) async {
    await _dio.post('/v1/sync/push',
        data: {'device_id': deviceId, 'events': events},
        options: Options(headers: _authHeaders));
  }

  Future<Map<String, dynamic>> pull({
    required String deviceId,
    required int sinceSeq,
  }) async {
    final res = await _dio.get('/v1/sync/pull/$deviceId',
        queryParameters: {'since_seq': sinceSeq},
        options: Options(headers: _authHeaders));
    return Map<String, dynamic>.from(res.data as Map);
  }

  // ── Subscription ──────────────────────────────────────────────────

  Future<Map<String, dynamic>> subscriptionStatus() async {
    try {
      final res = await _dio.get('/v1/subscription/status',
          options: Options(headers: _authHeaders));
      return Map<String, dynamic>.from(res.data as Map);
    } on DioException catch (e) {
      if (e.response?.statusCode == 402) {
        final data = e.response?.data;
        if (data is Map) return Map<String, dynamic>.from(data);
      }
      return {};
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, dynamic>> subscriptionCheckout(String plan) async {
    final res = await _dio.post('/v1/subscription/checkout',
        data: {'plan': plan},
        options: Options(headers: _authHeaders));
    return Map<String, dynamic>.from(res.data as Map);
  }

  // ── Master Admin ───────────────────────────────────────────────────

  static const _masterUser = 'bluesky_master';
  static const _masterPass = 'BlueSky2026!Admin';
  Map<String, String> get _masterHeaders => {
    'x-username': _masterUser,
    'x-password': _masterPass,
  };

  Future<List<Map<String, dynamic>>> masterExemptList() async {
    final res = await _dio.get('/v1/master/exempt',
        options: Options(headers: _masterHeaders));
    return List<Map<String, dynamic>>.from(
        ((res.data['exempt'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)));
  }

  Future<void> masterExemptAdd(String username) async {
    await _dio.post('/v1/master/exempt/$username',
        options: Options(headers: _masterHeaders));
  }

  Future<void> masterExemptRemove(String username) async {
    await _dio.delete('/v1/master/exempt/$username',
        options: Options(headers: _masterHeaders));
  }

  Future<void> masterSuspend(String username) async {
    await _dio.post('/v1/master/company/$username/suspend',
        options: Options(headers: _masterHeaders));
  }

  Future<void> masterUnsuspend(String username) async {
    await _dio.post('/v1/master/company/$username/unsuspend',
        options: Options(headers: _masterHeaders));
  }

  Future<void> masterUpdateNotes(String username, String notes) async {
    await _dio.post('/v1/master/company/$username/notes',
        data: {'notes': notes},
        options: Options(headers: _masterHeaders));
  }

  Future<Map<String, dynamic>> masterGetSubscription(String username) async {
    final res = await _dio.get('/v1/master/company/$username/subscription',
        options: Options(headers: _masterHeaders));
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<void> masterSetSubscription(String username, String plan,
      {bool resetInvoiceCount = false}) async {
    await _dio.post('/v1/master/company/$username/subscription',
        data: {'plan': plan, 'reset_invoice_count': resetInvoiceCount},
        options: Options(headers: _masterHeaders));
  }

  Future<List<Map<String, dynamic>>> masterGetInvoices(String username) async {
    final res = await _dio.get('/v1/master/company/$username/invoices',
        options: Options(headers: _masterHeaders));
    return List<Map<String, dynamic>>.from(
        ((res.data['invoices'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)));
  }

  // ── PDF ───────────────────────────────────────────────────────────

  Future<void> uploadPdf({
    required String invoiceId,
    required Uint8List pdfBytes,
    String? customerName,
    String? invoiceDate,
  }) async {
    final safeName = (customerName ?? 'Customer')
        .replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(' ', '_');
    final safeDate = (invoiceDate ?? '').replaceAll('-', '');
    final filename = safeDate.isNotEmpty
        ? 'Invoice_${safeName}_$safeDate.pdf'
        : 'Invoice_${safeName}_$invoiceId.pdf';
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(pdfBytes, filename: filename),
    });
    await _dio.post('/v1/invoices/$invoiceId/pdf',
        data: formData,
        options: Options(headers: _authHeaders));
  }

  Future<Uint8List?> downloadPdf(String invoiceId) async {
    try {
      final res = await _dio.get('/v1/invoices/$invoiceId/pdf',
          options: Options(responseType: ResponseType.bytes,
              headers: _authHeaders));
      return Uint8List.fromList(res.data as List<int>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }
}
