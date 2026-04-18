part of 'mcp_settings_screen.dart';

enum McpServerType { stdio, http }

class McpServerDraft {
  String name;
  McpServerType type;

  // Stdio fields
  String command;
  String args; // comma-separated raw string
  List<MapEntry<String, String>> env;

  // HTTP fields
  String url;
  List<MapEntry<String, String>> headers;

  McpServerDraft({
    this.name = '',
    this.type = McpServerType.stdio,
    this.command = '',
    this.args = '',
    List<MapEntry<String, String>>? env,
    this.url = '',
    List<MapEntry<String, String>>? headers,
  }) : env = env ?? [],
       headers = headers ?? [];

  /// Build the JSON config map for this server.
  Map<String, dynamic> toConfig() {
    if (type == McpServerType.http) {
      return {
        'type': 'http',
        'url': url.trim(),
        if (headers.isNotEmpty)
          'headers': {for (final e in headers) e.key: e.value},
      };
    } else {
      final argList = args
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return {
        'type': 'stdio',
        'command': command.trim(),
        if (argList.isNotEmpty) 'args': argList,
        if (env.isNotEmpty) 'env': {for (final e in env) e.key: e.value},
      };
    }
  }

  /// Build from existing config map.
  factory McpServerDraft.fromConfig(String name, Map<String, dynamic> cfg) {
    final rawType = cfg['type'] as String? ?? '';
    final isHttp =
        rawType == 'http' ||
        rawType == 'sse' ||
        (cfg.containsKey('url') && !cfg.containsKey('command'));

    if (isHttp) {
      final rawHeaders = cfg['headers'] as Map<String, dynamic>? ?? {};
      return McpServerDraft(
        name: name,
        type: McpServerType.http,
        url: cfg['url'] as String? ?? '',
        headers: rawHeaders.entries
            .map((e) => MapEntry(e.key, e.value.toString()))
            .toList(),
      );
    } else {
      final rawArgs = cfg['args'] as List<dynamic>? ?? [];
      final rawEnv = cfg['env'] as Map<String, dynamic>? ?? {};
      return McpServerDraft(
        name: name,
        type: McpServerType.stdio,
        command: cfg['command'] as String? ?? '',
        args: rawArgs.join(', '),
        env: rawEnv.entries
            .map((e) => MapEntry(e.key, e.value.toString()))
            .toList(),
      );
    }
  }
}
