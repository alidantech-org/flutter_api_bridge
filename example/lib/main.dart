import 'package:flutter/material.dart';
import 'package:flutter_api_bridge/flutter_api_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Server.init(
    baseUrl: 'https://jsonplaceholder.typicode.com',
    authStrategy: const CookieStrategy(),
    logging: const ApiLoggingConfig(
      level: ApiLoggingLevel.basic,
      showDuration: true,
      showRequestId: false,
    ),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter API Bridge Example',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'API Bridge Example'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _responseText = 'Press the button to make a request';
  bool _isLoading = false;

  Future<void> _makeRequest() async {
    setState(() {
      _isLoading = true;
      _responseText = 'Loading...';
    });

    try {
      // Example: Fetch a todo from the JSON Placeholder API
      final response = await ApiClient.instance('').get('/todos/1');

      setState(() {
        _isLoading = false;
        _responseText = 'Response: ${response.data}';
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _responseText = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                _responseText,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isLoading ? null : _makeRequest,
        tooltip: 'Make API Request',
        child: const Icon(Icons.api),
      ),
    );
  }
}
