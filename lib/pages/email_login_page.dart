import 'dart:async';

import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../features/capabilities/data/capability_cloud_sync.dart';

class EmailLoginPage extends StatefulWidget {
  const EmailLoginPage({required this.onAuthenticated, super.key});

  final VoidCallback onAuthenticated;

  @override
  State<EmailLoginPage> createState() => _EmailLoginPageState();
}

class _EmailLoginPageState extends State<EmailLoginPage> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  Timer? _cooldownTimer;
  int _cooldownSeconds = 0;
  bool _sendingCode = false;
  bool _loggingIn = false;
  bool _codeRequested = false;
  String? _requestedEmail;
  String? _message;
  bool _messageIsError = false;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  bool get _emailLooksValid {
    final email = _emailController.text.trim();
    final at = email.indexOf('@');
    return at > 0 && email.indexOf('.', at) > at + 1 && !email.contains(' ');
  }

  Future<void> _sendCode() async {
    if (!_emailLooksValid) {
      setState(() {
        _message = '请输入有效的邮箱地址';
        _messageIsError = true;
      });
      return;
    }
    setState(() {
      _sendingCode = true;
      _message = null;
    });
    try {
      await CapabilityCloudSync.instance.requestEmailLoginCode(
        _emailController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _message = '如果该邮箱已获准登录，验证码会发送到邮箱';
        _messageIsError = false;
        _cooldownSeconds = 60;
        _codeRequested = true;
        _requestedEmail = _emailController.text.trim();
      });
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || _cooldownSeconds <= 1) {
          timer.cancel();
          if (mounted) setState(() => _cooldownSeconds = 0);
          return;
        }
        setState(() => _cooldownSeconds--);
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error.toString().replaceFirst('Bad state: ', '');
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  void _onEmailChanged(String value) {
    if (_requestedEmail != null && value.trim() != _requestedEmail) {
      _cooldownTimer?.cancel();
      setState(() {
        _requestedEmail = null;
        _codeRequested = false;
        _cooldownSeconds = 0;
        _codeController.clear();
        _message = null;
      });
      return;
    }
    setState(() {});
  }

  Future<void> _signIn() async {
    final code = _codeController.text.trim();
    if (!_emailLooksValid || !RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() {
        _message = '请检查邮箱地址和 6 位验证码';
        _messageIsError = true;
      });
      return;
    }
    setState(() {
      _loggingIn = true;
      _message = null;
    });
    try {
      await CapabilityCloudSync.instance.signInWithEmailCode(
        email: _emailController.text.trim(),
        code: code,
      );
      if (mounted) widget.onAuthenticated();
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error.toString().replaceFirst('Bad state: ', '');
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 40, 28, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 32),
                  const Text(
                    '你好，LUCKY',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '登录个人账号，自动连接 Agent 与云同步',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 38),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: '邮箱',
                            hintText: '输入你的 QQ 邮箱',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: _onEmailChanged,
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 56,
                        child: OutlinedButton(
                          onPressed:
                              _sendingCode || _loggingIn || _cooldownSeconds > 0
                              ? null
                              : _sendCode,
                          child: _sendingCode
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  _cooldownSeconds > 0
                                      ? '重新发送 ${_cooldownSeconds}s'
                                      : '获取验证码',
                                ),
                        ),
                      ),
                    ],
                  ),
                  if (_codeRequested) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _codeController,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      maxLength: 6,
                      onSubmitted: (_) => _signIn(),
                      decoration: const InputDecoration(
                        labelText: '邮箱验证码',
                        counterText: '',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _messageIsError
                            ? colors.error
                            : colors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  if (_codeRequested) ...[
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _loggingIn || _sendingCode ? null : _signIn,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: _loggingIn
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('登录'),
                    ),
                  ],
                  const SizedBox(height: 14),
                  const Text(
                    '此设备登录一次后会保持登录；退出登录需要重新验证邮箱。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
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
