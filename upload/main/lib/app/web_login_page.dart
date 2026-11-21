import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/models.dart';

/// Real discord.com login inside a WebView. Once the page reaches /channels,
/// the token Discord keeps in its web storage is read and returned to the
/// caller (Navigator.pop with the token). It never leaves the device.
class WebLoginPage extends StatefulWidget {
  const WebLoginPage({super.key});

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
  // Discord removes window.localStorage, so a fresh iframe's copy is read.
  // Same idea as the reference APK's embedded script.
  static const String _js = '''
(function(){try{var f=document.createElement('iframe');document.body.appendChild(f);var t=f.contentWindow.localStorage.getItem('token');f.remove();return t;}catch(e){return null;}})()
''';

  late final WebViewController _controller;
  Timer? _poll;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse('https://discord.com/login'));
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      final url = await _controller.currentUrl();
      if (url == null || !url.contains('/channels')) return;
      final res = await _controller.runJavaScriptReturningResult(_js);
      final token = normalizeCapturedToken(res.toString());
      if (token != null && mounted) {
        _poll?.cancel();
        Navigator.of(context).pop(token);
      }
    } catch (_) {
      // Page not ready or script blocked: try again on the next tick.
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Discord login')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Log in normally. The token is captured automatically once '
              'your channel list opens.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
