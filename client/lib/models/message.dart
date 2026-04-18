enum MessageSender { me, ai }

/// 聊天消息数据模型。
class ChatMessage {
  final String id;
  final String content;
  final MessageSender sender;
  final DateTime time;
  final bool isTyping; // AI 正在输入中的占位
  final bool isSelected; // 是否被选中（用于多选）
  final Map<String, dynamic>? extra; // 附件/扩展元数据

  ChatMessage({
    required this.id,
    required this.content,
    required this.sender,
    required this.time,
    this.isTyping = false,
    this.isSelected = false,
    this.extra,
  });

  ChatMessage copyWith({
    String? content,
    bool? isTyping,
    bool? isSelected,
    Map<String, dynamic>? extra,
  }) {
    // 不可变更新：仅替换传入字段，其他字段保持原值。
    return ChatMessage(
      id: id,
      content: content ?? this.content,
      sender: sender,
      time: time,
      isTyping: isTyping ?? this.isTyping,
      isSelected: isSelected ?? this.isSelected,
      extra: extra ?? this.extra,
    );
  }
}
