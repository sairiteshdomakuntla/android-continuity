import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bridge App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Bridge App Home Page'),
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
  int _counter = 0;
  socket_io.Socket? _socket;

  @override
  void initState() {
    super.initState();
    _initSocket();
  }

  void _initSocket() {
    debugPrint('[Socket.IO] Initializing connection to http://192.168.0.112:4000 ...');
    _socket = socket_io.io(
      'http://192.168.0.112:4000',
      socket_io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .build(),
    );

    _socket?.onConnect((_) {
      debugPrint('[Socket.IO] Connected to server: ${_socket?.id}');
    });

    _socket?.onConnectError((data) {
      debugPrint('[Socket.IO] Connection Error: $data');
    });

    _socket?.onError((data) {
      debugPrint('[Socket.IO] Error: $data');
    });

    _socket?.onDisconnect((reason) {
      debugPrint('[Socket.IO] Disconnected from server: $reason');
    });
  }

  void _sendTestMessage() {
    if (_socket != null) {
      debugPrint('[Socket.IO] Emitting test-message: hello from phone');
      _socket!.emit('test-message', 'hello from phone');
    } else {
      debugPrint('[Socket.IO] Socket is not initialized.');
    }
  }

  @override
  void dispose() {
    _socket?.dispose();
    super.dispose();
  }

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _sendTestMessage,
              child: const Text('Send Test Message'),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}

