import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api_service.dart';
import 'local_db.dart';

// ── Update this URL to your actual website / sign-up page ──
const _subscribeUrl = 'https://blueskysmog.net/invoicing-app';

class LoginPage extends StatefulWidget {
  final ApiService api;
  final VoidCallback onLoggedIn;
  const LoginPage({super.key, required this.api, required this.onLoggedIn});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _loginFormKey    = GlobalKey<FormState>();
  final _registerFormKey = GlobalKey<FormState>();

  final _loginUserCtl    = TextEditingController();
  final _loginPassCtl    = TextEditingController();
  final _regUserCtl      = TextEditingController();
  final _regPassCtl      = TextEditingController();
  final _regPass2Ctl     = TextEditingController();
  final _regCompanyCtl   = TextEditingController();
  final _regAddressCtl  = TextEditingController();

  bool _loading       = false;
  bool _obscureLogin  = true;
  bool _obscureReg    = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _loginUserCtl.dispose(); _loginPassCtl.dispose();
    _regUserCtl.dispose();   _regPassCtl.dispose();
    _regPass2Ctl.dispose();  _regCompanyCtl.dispose();
    _regAddressCtl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_loginFormKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });
    try {
      final username = _loginUserCtl.text.trim().toLowerCase();
      final password = _loginPassCtl.text;
      final res = await widget.api.login(username, password);
      final token = res['token'] ?? '';
      widget.api.setCredentials(username, password, token: token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username',     username);
      await prefs.setString('password',     password);
      await prefs.setString('auth_token',   token);
      await prefs.setString('company_id',   res['company_id']   ?? '');
      await prefs.setString('company_name', res['company_name'] ?? '');
      // Clear stale outbox and reset sync seq for fresh session
      final deviceId = prefs.getString('device_id') ?? '';
      if (deviceId.isNotEmpty) await LocalDb.instance.clearAllLocalData(deviceId);
      await prefs.setInt('since_seq', 0);
      widget.onLoggedIn();
    } catch (e) {
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _register() async {
    if (!_registerFormKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });
    try {
      final username    = _regUserCtl.text.trim().toLowerCase();
      final password    = _regPassCtl.text;
      final companyName = _regCompanyCtl.text.trim();
      final address     = _regAddressCtl.text.trim();
      final registerRes = await widget.api.register(
          username: username, password: password, companyName: companyName,
          address: address);
      final token = registerRes['token'] ?? '';
      widget.api.setCredentials(username, password, token: token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username',     username);
      await prefs.setString('password',     password);
      await prefs.setString('auth_token',   token);
      await prefs.setString('company_id',   registerRes['company_id']   ?? '');
      await prefs.setString('company_name', registerRes['company_name'] ?? '');
      widget.onLoggedIn();
    } catch (e) {
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('401') || s.contains('Invalid username')) {
      return 'Incorrect username or password.';
    }
    if (s.contains('409') || s.contains('already taken')) {
      return 'That username is already taken. Choose another.';
    }
    if (s.contains('SocketException') || s.contains('connection')) {
      return 'Cannot reach server. Check your internet connection.';
    }
    return 'Error: $s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 48),
          // Logo / title
          Icon(Icons.cloud_sync_outlined,
              size: 64, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 8),
          Text('Blue Sky Smog',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Invoice Manager',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(height: 16),

          // Subscription notice
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                border: Border.all(color: Colors.blue.shade200),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline,
                    size: 16, color: Colors.blue.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Blue Sky Smog Invoice Manager',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: Colors.blue.shade800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Sign in with an existing account, or tap '
                        '"Create Account" to get started with a free trial. '
                        'A \$40/month subscription is required to continue.',
                        style: TextStyle(
                            fontSize: 11, color: Colors.blue.shade700),
                      ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: () => launchUrl(Uri.parse(_subscribeUrl),
                            mode: LaunchMode.externalApplication),
                        child: Text(
                          'Learn more at blueskysmog.net →',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.blue.shade800,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline),
                        ),
                      ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),

          // Tab bar
          TabBar(
            controller: _tabs,
            tabs: const [Tab(text: 'Sign In'), Tab(text: 'Create Account')],
          ),

          // Error banner
          if (_error != null)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red.shade200),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.error_outline,
                    color: Colors.red.shade700, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!,
                    style: TextStyle(
                        color: Colors.red.shade800, fontSize: 13))),
              ]),
            ),

          Expanded(child: TabBarView(controller: _tabs, children: [
            _loginTab(),
            _registerTab(),
          ])),
        ]),
      ),
    );
  }

  Widget _loginTab() => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Form(key: _loginFormKey, child: Column(children: [
      Text(
        'Sign in to your Blue Sky account. New? Use the Create Account tab.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _loginUserCtl,
        decoration: const InputDecoration(
          labelText: 'Username',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.person_outline),
        ),
        textInputAction: TextInputAction.next,
        autocorrect: false,
        validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _loginPassCtl,
        obscureText: _obscureLogin,
        decoration: InputDecoration(
          labelText: 'Password',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            icon: Icon(_obscureLogin
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined),
            onPressed: () => setState(() => _obscureLogin = !_obscureLogin),
          ),
        ),
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _login(),
        validator: (v) => (v?.isEmpty ?? true) ? 'Required' : null,
      ),
      const SizedBox(height: 24),
      SizedBox(width: double.infinity, height: 48,
        child: FilledButton(
          onPressed: _loading ? null : _login,
          child: _loading
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Sign In',
                  style: TextStyle(fontSize: 15)),
        ),
      ),
    ])),
  );

  Widget _registerTab() => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Form(key: _registerFormKey, child: Column(children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          border: Border.all(color: Colors.green.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.check_circle_outline,
                size: 15, color: Colors.green.shade800),
            const SizedBox(width: 6),
            Text('Free trial included',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Colors.green.shade900)),
          ]),
          const SizedBox(height: 4),
          Text(
            'Create a new Blue Sky account to get started. A \$40/month '
            'subscription is required to continue after your trial. '
            'You can also use this to add an additional device to an '
            'existing account.',
            style: TextStyle(fontSize: 11, color: Colors.green.shade900),
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => launchUrl(Uri.parse(_subscribeUrl),
                mode: LaunchMode.externalApplication),
            child: Text(
              'Learn more at blueskysmog.net →',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.green.shade900,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _regCompanyCtl,
        decoration: const InputDecoration(
          labelText: 'Company Name',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.business_outlined),
        ),
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        validator: (v) =>
            (v?.trim().isEmpty ?? true) ? 'Required' : null,
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _regAddressCtl,
        decoration: const InputDecoration(
          labelText: 'Business Address (optional)',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.location_on_outlined),
        ),
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _regUserCtl,
        decoration: const InputDecoration(
          labelText: 'Username',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.person_outline),
          helperText: 'Lowercase letters and numbers only',
        ),
        autocorrect: false,
        textInputAction: TextInputAction.next,
        validator: (v) {
          if (v == null || v.trim().length < 3) {
            return 'At least 3 characters';
          }
          return null;
        },
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _regPassCtl,
        obscureText: _obscureReg,
        decoration: InputDecoration(
          labelText: 'Password',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.lock_outline),
          helperText: 'At least 6 characters',
          suffixIcon: IconButton(
            icon: Icon(_obscureReg
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined),
            onPressed: () => setState(() => _obscureReg = !_obscureReg),
          ),
        ),
        textInputAction: TextInputAction.next,
        validator: (v) =>
            (v == null || v.length < 6) ? 'At least 6 characters' : null,
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _regPass2Ctl,
        obscureText: _obscureReg,
        decoration: const InputDecoration(
          labelText: 'Confirm Password',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.lock_outline),
        ),
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _register(),
        validator: (v) => v != _regPassCtl.text ? 'Passwords do not match' : null,
      ),
      const SizedBox(height: 24),
      SizedBox(width: double.infinity, height: 48,
        child: FilledButton(
          onPressed: _loading ? null : _register,
          child: _loading
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Create Account',
                  style: TextStyle(fontSize: 15)),
        ),
      ),
    ])),
  );
}
