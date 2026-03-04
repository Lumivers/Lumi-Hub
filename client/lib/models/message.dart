enum MessageSender { me, ai }

class ChatMessage {
  final String id;
  final String content;
  final MessageSender sender;
  final DateTime time;
  final bool isTyping; // AI 正在输入中的占位

  ChatMessage({
    required this.id,
    required this.content,
    required this.sender,
    required this.time,
    this.isTyping = false,
  });

  ChatMessage copyWith({String? content, bool? isTyping}) {
    return ChatMessage(
      id: id,
      content: content ?? this.content,
      sender: sender,
      time: time,
      isTyping: isTyping ?? this.isTyping,
    );
  }
}
