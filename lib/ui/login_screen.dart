import "package:flutter/material.dart";

import "package:reel_change/auth/auth_service.dart";
import "package:reel_change/core/api_client.dart";
import "package:reel_change/core/certificates.dart";
import "package:reel_change/ui/theme.dart";

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

    await auth.login(_server.text, _username.text, _password.text);

    // The password is only kept while the user decides whether to trust the
    // server's certificate (so they do not have to type it again)
    if (auth.pendingCertificate == null) _password.clear();
  }

  Future<void> _trustCertificate() async {
    final CertificateInfo? cert = auth.pendingCertificate;
    if (cert == null) return;

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(
          Icons.gpp_maybe,
          color: StatusColors.warning,
          size: 48,
        ),
        title: const Text("Trust this certificate?"),
        content: Text(
          "The app will accept this exact certificate for ${cert.host}:${cert.port}. "
          "You will be asked again if the server presents any other certificate.",
          style: const TextStyle(fontSize: 17),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("CANCEL"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: StatusColors.warning,
              minimumSize: const Size(120, 48),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("TRUST"),
          ),
        ],
      ),
    );

    if (ok != true || !await auth.trustPendingCertificate()) return;

    // Carry on with what was interrupted
    if (_password.text.isNotEmpty) {
      await _login();
    } else {
      await auth.retry();
    }
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
      appBar: AppBar(title: const Text("Reel Change")),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              mfa ? "Two-factor authentication" : "Log in to InvenTree",
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 24),
            if (auth.pendingCertificate != null && !mfa) ...[
              _CertificatePanel(
                certificate: auth.pendingCertificate!,
                changed: auth.certificateChanged,
                message: auth.message,
                busy: auth.busy,
                onTrust: _trustCertificate,
                onReject: () {
                  _password.clear();
                  auth.rejectPendingCertificate();
                },
              ),
              const SizedBox(height: 24),
            ] else if (auth.message.isNotEmpty) ...[
              _MessageBanner(
                message: auth.message,
                isError: auth.messageIsError,
              ),
              const SizedBox(height: 16),
            ],
            if (auth.canRetry && !mfa && auth.pendingCertificate == null) ...[
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

/// An untrusted (or changed) server certificate, with the details the user
/// needs to decide whether to trust it.
class _CertificatePanel extends StatelessWidget {
  const _CertificatePanel({
    required this.certificate,
    required this.changed,
    required this.message,
    required this.busy,
    required this.onTrust,
    required this.onReject,
  });

  final CertificateInfo certificate;
  final bool changed;
  final String message;
  final bool busy;
  final VoidCallback onTrust;
  final VoidCallback onReject;

  String _date(DateTime? d) => d == null
      ? "?"
      : "${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}";

  @override
  Widget build(BuildContext context) {
    final Color color = changed ? StatusColors.error : StatusColors.warning;

    Widget row(
      String label,
      String value, {
      bool mono = false,
      Color? valueColor,
    }) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: Colors.black54),
          ),
          SelectableText(
            value,
            style: TextStyle(
              fontSize: mono ? 14 : 16,
              fontFamily: mono ? "monospace" : null,
              color: valueColor ?? Colors.black87,
            ),
          ),
        ],
      ),
    );

    return Container(
      key: const Key("certificate-panel"),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: color,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  changed ? Icons.gpp_bad : Icons.gpp_maybe,
                  color: Colors.white,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    changed ? "CERTIFICATE CHANGED" : "UNTRUSTED CERTIFICATE",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: const TextStyle(fontSize: 17, color: Colors.black87),
                ),
                row("Server", "${certificate.host}:${certificate.port}"),
                row("Issued to", certificate.subject),
                row("Issued by", certificate.issuer),
                row(
                  "Valid",
                  "${_date(certificate.validFrom)} to ${_date(certificate.validTo)}"
                      "${certificate.isExpired ? "  (EXPIRED)" : ""}",
                  valueColor: certificate.isExpired ? StatusColors.error : null,
                ),
                row("SHA-256 fingerprint", certificate.fingerprint, mono: true),
                const SizedBox(height: 12),
                const Text(
                  "Only trust this certificate if your InvenTree server is known to use a "
                  "self-signed certificate, and the fingerprint matches the one from your "
                  "administrator.",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : onReject,
                  child: const Text("DON'T TRUST"),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key("trust-certificate"),
                  style: OutlinedButton.styleFrom(foregroundColor: color),
                  onPressed: busy ? null : onTrust,
                  icon: const Icon(Icons.verified_user),
                  label: const Text("TRUST THIS CERTIFICATE"),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
