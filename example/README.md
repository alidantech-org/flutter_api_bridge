# Flutter API Bridge Example

This directory contains example code demonstrating how to use the `flutter_api_bridge` package.

## Running the Example

```bash
cd example
flutter run
```

## Features Demonstrated

- **Basic API Client Setup** - Configuring and initializing the API client
- **Making Requests** - Performing HTTP requests with automatic caching
- **Cookie Management** - Automatic cookie handling and persistence
- **State Management** - Using Riverpod providers for state
- **Error Handling** - Proper error handling for failed requests
- **File Uploads** - Uploading files with progress tracking
- **Authentication** - Implementing custom authentication strategies

## Example Usage

```dart
import 'package:flutter_api_bridge/flutter_api_bridge.dart';

// Initialize the API client
final apiClient = ApiClient(
  serverConfig: ServerConfig(
    baseUrl: 'https://api.example.com',
  ),
);

// Make a GET request
final response = await apiClient.get('/users');

// Handle the response
if (response.isSuccess) {
  print('Success: ${response.data}');
} else {
  print('Error: ${response.error}');
}
```

For more detailed examples, see the files in this directory.
