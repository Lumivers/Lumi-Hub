part of 'mcp_settings_screen.dart';

class _McpServerEditorDialog extends StatefulWidget {
  final McpServerDraft draft;
  final Set<String> existingNames;

  const _McpServerEditorDialog({
    required this.draft,
    required this.existingNames,
  });

  @override
  State<_McpServerEditorDialog> createState() => _McpServerEditorDialogState();
}

class _McpServerEditorDialogState extends State<_McpServerEditorDialog> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameCtrl;
  late McpServerType _type;

  // Stdio
  late TextEditingController _commandCtrl;
  late TextEditingController _argsCtrl;
  late List<MapEntry<String, String>> _env;

  // HTTP
  late TextEditingController _urlCtrl;
  late List<MapEntry<String, String>> _headers;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    _nameCtrl = TextEditingController(text: d.name);
    _type = d.type;
    _commandCtrl = TextEditingController(text: d.command);
    _argsCtrl = TextEditingController(text: d.args);
    _env = List<MapEntry<String, String>>.from(d.env);
    _urlCtrl = TextEditingController(text: d.url);
    _headers = List<MapEntry<String, String>>.from(d.headers);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _commandCtrl.dispose();
    _argsCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _addKvPair(List<MapEntry<String, String>> list) {
    setState(() => list.add(const MapEntry('', '')));
  }

  void _removeKvPair(List<MapEntry<String, String>> list, int idx) {
    setState(() => list.removeAt(idx));
  }

  void _updateKvKey(List<MapEntry<String, String>> list, int idx, String key) {
    setState(() => list[idx] = MapEntry(key, list[idx].value));
  }

  void _updateKvValue(
    List<MapEntry<String, String>> list,
    int idx,
    String val,
  ) {
    setState(() => list[idx] = MapEntry(list[idx].key, val));
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final result = McpServerDraft(
      name: _nameCtrl.text.trim(),
      type: _type,
      command: _commandCtrl.text,
      args: _argsCtrl.text,
      env: List.from(_env),
      url: _urlCtrl.text,
      headers: List.from(_headers),
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final colorScheme = Theme.of(context).colorScheme;
    final isEdit = widget.draft.name.isNotEmpty;

    return Dialog(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                isEdit ? '编辑 Server' : '添加 MCP Server',
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),

              // Form
              Expanded(
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Name
                        _buildField(
                          colors: colors,
                          colorScheme: colorScheme,
                          label: 'Server 名称',
                          controller: _nameCtrl,
                          hint: '例如：filesystem、notion',
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return '名称不能为空';
                            }
                            if (widget.existingNames.contains(v.trim())) {
                              return '名称已存在';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // Type selector
                        Text(
                          '接入方式',
                          style: TextStyle(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w500,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildTypeSelector(colors, colorScheme),
                        const SizedBox(height: 20),

                        // Type-specific fields
                        if (_type == McpServerType.stdio) ...[
                          _buildField(
                            colors: colors,
                            colorScheme: colorScheme,
                            label: '启动命令 (command)',
                            controller: _commandCtrl,
                            hint: '例如：npx 或 uvx',
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? '命令不能为空'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _buildField(
                            colors: colors,
                            colorScheme: colorScheme,
                            label: '参数 args（逗号分隔）',
                            controller: _argsCtrl,
                            hint:
                                '例如：-y, @modelcontextprotocol/server-filesystem, /path',
                          ),
                          const SizedBox(height: 16),
                          _buildKvSection(
                            colors: colors,
                            colorScheme: colorScheme,
                            title: '环境变量 (env)',
                            list: _env,
                            keyHint: 'VARIABLE_NAME',
                            valueHint: 'value',
                            obscureValue: true,
                          ),
                        ] else ...[
                          _buildField(
                            colors: colors,
                            colorScheme: colorScheme,
                            label: '服务器地址 (url)',
                            controller: _urlCtrl,
                            hint: '例如：https://mcp.example.com/sse',
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'URL 不能为空'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _buildKvSection(
                            colors: colors,
                            colorScheme: colorScheme,
                            title: '请求头 Headers（可选）',
                            list: _headers,
                            keyHint: 'Authorization',
                            valueHint: 'Bearer token...',
                            obscureValue: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),
              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('取消', style: TextStyle(color: colors.subtext)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(isEdit ? '保存并热重载' : '添加并热重载'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTypeSelector(LumiColors colors, ColorScheme colorScheme) {
    return Row(
      children: [
        _TypeOption(
          label: 'Stdio（本地命令）',
          subtitle: 'npx / uvx / python',
          icon: Icons.terminal_rounded,
          selected: _type == McpServerType.stdio,
          colors: colors,
          colorScheme: colorScheme,
          onTap: () => setState(() => _type = McpServerType.stdio),
        ),
        const SizedBox(width: 10),
        _TypeOption(
          label: 'HTTP / SSE（远程）',
          subtitle: 'HTTPS endpoint',
          icon: Icons.cloud_rounded,
          selected: _type == McpServerType.http,
          colors: colors,
          colorScheme: colorScheme,
          onTap: () => setState(() => _type = McpServerType.http),
        ),
      ],
    );
  }

  Widget _buildField({
    required LumiColors colors,
    required ColorScheme colorScheme,
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscureText = false,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscureText,
          validator: validator,
          style: TextStyle(color: colorScheme.onSurface, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: colors.subtext, fontSize: 12),
            filled: true,
            fillColor: colors.inputBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.divider),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.divider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.accent),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.redAccent),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKvSection({
    required LumiColors colors,
    required ColorScheme colorScheme,
    required String title,
    required List<MapEntry<String, String>> list,
    required String keyHint,
    required String valueHint,
    bool obscureValue = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _addKvPair(list),
              icon: Icon(Icons.add_rounded, size: 16, color: colors.accent),
              label: Text(
                '添加',
                style: TextStyle(color: colors.accent, fontSize: 12),
              ),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (list.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.inputBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.divider),
            ),
            child: Text(
              '（无）',
              style: TextStyle(color: colors.subtext, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          )
        else
          ...list.asMap().entries.map((entry) {
            final idx = entry.key;
            final kv = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _KvField(
                      initial: kv.key,
                      hint: keyHint,
                      colors: colors,
                      colorScheme: colorScheme,
                      onChanged: (v) => _updateKvKey(list, idx, v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: _KvField(
                      initial: kv.value,
                      hint: valueHint,
                      obscureText: obscureValue,
                      colors: colors,
                      colorScheme: colorScheme,
                      onChanged: (v) => _updateKvValue(list, idx, v),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.remove_circle_outline_rounded,
                      color: Colors.redAccent,
                      size: 18,
                    ),
                    onPressed: () => _removeKvPair(list, idx),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

// ── Helper Widgets ───────────────────────────────────────────────────────────
