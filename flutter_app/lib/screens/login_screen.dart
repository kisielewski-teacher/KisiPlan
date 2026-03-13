import 'package:flutter/material.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.onLogin,
    this.initialUsername,
    this.initialRole = 'teacher',
  });

  final Future<String?> Function(String username, String password, String role) onLogin;
  final String? initialUsername;
  final String initialRole;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;
  late String _role;

  @override
  void initState() {
    super.initState();
    _role = widget.initialRole;
    if (widget.initialUsername != null) {
      _usernameController.text = widget.initialUsername!;
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() { _error = null; });
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _loading = true; });

    final error = await widget.onLogin(
      _usernameController.text.trim(),
      _passwordController.text,
      _role,
    );

    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Logowanie')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Image(
                    image: AssetImage('assets/Mechanik.png'),
                    width: 180,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Zaloguj sie kontem Librus Synergia.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'teacher', label: Text('Nauczyciel'), icon: Icon(Icons.school)),
                      ButtonSegment(value: 'student', label: Text('Uczen'), icon: Icon(Icons.person)),
                    ],
                    selected: {_role},
                    onSelectionChanged: (s) => setState(() => _role = s.first),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _usernameController,
                    keyboardType: _role == 'teacher'
                        ? TextInputType.number
                        : TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: _role == 'teacher' ? 'ID nauczyciela' : 'Login (e-mail)',
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) return 'Podaj login';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Haslo',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) return 'Podaj haslo';
                      return null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _loading ? null : _submit,
                    icon: _loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: const Text('Zaloguj'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
