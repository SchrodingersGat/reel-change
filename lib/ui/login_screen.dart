import "package:flutter/material.dart";

import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/api_client.dart";
import "package:inventree_smt/ui/theme.dart";

/// Login form (server, username, password), plus the MFA code step.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _server;
  late final TextEditingController _username;
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();

  bool _showPassword = false;
  bool _trustDevice = false;

  AuthService get auth => widget.auth;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: auth.profile?.server ?? "");
    _username = TextEditingController(text: auth.profile?.username ?? "");
    _server.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();

    final String password = _password.text;

    // The password is only held for the duration of the request
    _password.clear();

    await auth.login(_server.text, _username.text, password);
  }

  Future<void> _submitCode() async {
    FocusScope.of(context).unfocus();
    final String code = _code.text;
    _code.clear();
    await auth.submitMfa(code, trustDevice: _trustDevice);
  }

  @override
  Widget build(BuildContext context) {
    final bool mfa = auth.phase == AuthPhase.mfaRequired;

    return Scaffold(
      appBar: AppBar(title: const Text("SMT Reel Loader")),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              mfa ? "Two-factor authentication" : "Log in to InvenTree",
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 24),
            if (auth.message.isNotEmpty) ...[
              _MessageBanner(
                message: auth.message,
                isError: auth.messageIsError,
              ),
              const SizedBox(height: 16),
            ],
            if (auth.canRetry && !mfa) ...[
              OutlinedButton.icon(
                onPressed: auth.busy ? null : auth.retry,
                icon: const Icon(Icons.refresh),
                label: const Text("RETRY CONNECTION"),
              ),
              const SizedBox(height: 24),
            ],
            if (mfa) ..._mfaFields() else ..._loginFields(),
          ],
        ),
      ),
    );
  }

  List<Widget> _loginFields() {
    final String? normalised = normaliseServerUrl(_server.text);
    final bool insecure = normalised != null && isInsecureRemote(normalised);

    return [
      TextField(
        controller: _server,
        enabled: !auth.busy,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: "Server address",
          hintText: "https://inventree.example.com",
          prefixIcon: const Icon(Icons.dns),
          helperText: insecure
              ? "Unencrypted (http) connection - only use on a trusted network"
              : null,
          helperStyle: const TextStyle(
            color: StatusColors.warning,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _username,
        enabled: !auth.busy,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: "Username",
          prefixIcon: Icon(Icons.person),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _password,
        enabled: !auth.busy,
        obscureText: !_showPassword,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _login(),
        decoration: InputDecoration(
          labelText: "Password",
          prefixIcon: const Icon(Icons.lock),
          suffixIcon: IconButton(
            tooltip: _showPassword ? "Hide password" : "Show password",
            icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
        ),
      ),
      const SizedBox(height: 32),
      FilledButton(
        onPressed: auth.busy ? null : _login,
        child: auth.busy ? const _ButtonSpinner() : const Text("LOG IN"),
      ),
    ];
  }

  List<Widget> _mfaFields() {
    final bool recovery = auth.pendingFlow?.supportsRecoveryCodes ?? false;

    return [
      Text(
        recovery
            ? "Enter the code from your authenticator app, or a recovery code."
            : "Enter the code from your authenticator app.",
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _code,
        enabled: !auth.busy,
        autofocus: true,
        keyboardType: recovery ? TextInputType.text : TextInputType.number,
        autocorrect: false,
        enableSuggestions: false,
        autofillHints: const [AutofillHints.oneTimeCode],
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submitCode(),
        style: const TextStyle(fontSize: 28, letterSpacing: 4),
        decoration: const InputDecoration(
          labelText: "Code",
          prefixIcon: Icon(Icons.pin),
        ),
      ),
      const SizedBox(height: 8),
      CheckboxListTile(
        value: _trustDevice,
        onChanged: auth.busy
            ? null
            : (v) => setState(() => _trustDevice = v ?? false),
        title: const Text("Trust this device"),
        subtitle: const Text(
          "Skip two-factor codes on this device for a while",
        ),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: auth.busy ? null : _submitCode,
        child: auth.busy ? const _ButtonSpinner() : const Text("VERIFY"),
      ),
      const SizedBox(height: 16),
      OutlinedButton(
        onPressed: auth.busy ? null : auth.cancelMfa,
        child: const Text("CANCEL"),
      ),
    ];
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 28,
    width: 28,
    child: CircularProgressIndicator(strokeWidth: 3),
  );
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final Color color = isError
        ? StatusColors.error
        : Theme.of(context).colorScheme.primary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(isError ? Icons.error : Icons.info, color: color, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 18,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
