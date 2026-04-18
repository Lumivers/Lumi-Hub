part of 'mcp_settings_screen.dart';

class _ServerCard extends StatelessWidget {
  final String name;
  final Map<String, dynamic> config;
  final LumiColors colors;
  final ColorScheme colorScheme;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ServerCard({
    required this.name,
    required this.config,
    required this.colors,
    required this.colorScheme,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final rawType = config['type'] as String? ?? '';
    final isHttp =
        rawType == 'http' ||
        rawType == 'sse' ||
        (config.containsKey('url') && !config.containsKey('command'));
    final typeLabel = isHttp ? 'HTTP / SSE' : 'Stdio';
    final typeColor = isHttp ? Colors.teal : Colors.deepPurple;

    final subtitle = isHttp
        ? (config['url'] as String? ?? '—')
        : '${config['command'] ?? ''} ${(config['args'] as List?)?.join(' ') ?? ''}'
              .trim();

    return Container(
      decoration: BoxDecoration(
        color: colors.inputBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isHttp ? Icons.cloud_rounded : Icons.terminal_rounded,
              color: colors.accent,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: typeColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        typeLabel,
                        style: TextStyle(color: typeColor, fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.edit_rounded, color: colors.subtext, size: 20),
            tooltip: '编辑',
            onPressed: onEdit,
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_rounded,
              color: Colors.redAccent,
              size: 20,
            ),
            tooltip: '删除',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

// ── Editor Dialog ────────────────────────────────────────────────────────────

class _TypeOption extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final LumiColors colors;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _TypeOption({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.colors,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? colors.accent.withValues(alpha: 0.12)
                : colors.inputBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? colors.accent : colors.divider,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? colors.accent : colors.subtext,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: selected ? colors.accent : colorScheme.onSurface,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(color: colors.subtext, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A simple text field that reports changes via [onChanged].
/// Uses an internal controller so it can be pre-filled.
class _KvField extends StatefulWidget {
  final String initial;
  final String hint;
  final bool obscureText;
  final LumiColors colors;
  final ColorScheme colorScheme;
  final ValueChanged<String> onChanged;

  const _KvField({
    required this.initial,
    required this.hint,
    required this.colors,
    required this.colorScheme,
    required this.onChanged,
    this.obscureText = false,
  });

  @override
  State<_KvField> createState() => _KvFieldState();
}

class _KvFieldState extends State<_KvField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final colorScheme = widget.colorScheme;
    return TextField(
      controller: _ctrl,
      obscureText: widget.obscureText,
      onChanged: widget.onChanged,
      style: TextStyle(color: colorScheme.onSurface, fontSize: 12),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: TextStyle(color: colors.subtext, fontSize: 11),
        filled: true,
        fillColor: colors.inputBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: colors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: colors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: colors.accent),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        isDense: true,
      ),
    );
  }
}
