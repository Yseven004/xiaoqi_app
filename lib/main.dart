import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'config/colors.dart';
import 'features/capabilities/data/capability_cloud_sync.dart';
import 'pages/email_login_page.dart';
import 'pages/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '笔记',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh')],
      localizationsDelegates: const [
        quill.FlutterQuillLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.accent),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Colors.black,
          selectionColor: Color(0x33202124),
          selectionHandleColor: Colors.black,
        ),
        scaffoldBackgroundColor: AppColors.notebookPaper,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
          ),
        ),
      ),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _checking = true;
  bool _authenticated = false;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final cloud = CapabilityCloudSync.instance;
    if (!await cloud.hasLocalEmailSession) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    try {
      final valid = await cloud.validateEmailSession();
      if (mounted) {
        setState(() {
          _authenticated = valid;
          _checking = false;
        });
      }
    } catch (_) {
      // A previously authenticated user can still open local content offline.
      if (mounted) {
        setState(() {
          _authenticated = true;
          _checking = false;
        });
      }
    }
  }

  void _onAuthenticated() {
    if (mounted) setState(() => _authenticated = true);
  }

  void _onSignedOut() {
    if (mounted) setState(() => _authenticated = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(
          child: Text(
            '小七',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    if (!_authenticated) {
      return EmailLoginPage(onAuthenticated: _onAuthenticated);
    }
    return HomePage(onSignOut: _onSignedOut);
  }
}
