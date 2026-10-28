import 'dart:ui';
import 'package:flutter/material.dart';

class UserQuestionDialog extends StatefulWidget {
  final Map<String, dynamic> request;
  final Function(List<Map<String, dynamic>> answers) onSubmit;
  final VoidCallback onCancel;

  const UserQuestionDialog({
    super.key,
    required this.request,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<UserQuestionDialog> createState() => _UserQuestionDialogState();
}

class _UserQuestionDialogState extends State<UserQuestionDialog> {
  int _currentIndex = 0;
  List<Map<String, dynamic>> _questions = [];

  // 记录每个问题的勾选项：questionId -> Set<String>
  final Map<String, Set<String>> _selectedOptions = {};
  // 记录每个问题的自定义输入：questionId -> TextEditingController
  final Map<String, TextEditingController> _customControllers = {};
  // 记录是否选中了 "Other" 自定义项：questionId -> bool
  final Map<String, bool> _otherSelected = {};

  @override
  void initState() {
    super.initState();
    final payload = widget.request['payload'] as Map<String, dynamic>? ?? {};
    final rawQuestions = payload['questions'] as List<dynamic>? ?? [];
    _questions = rawQuestions
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    for (int i = 0; i < _questions.length; i++) {
      final q = _questions[i];
      final qId = (q['id'] as String?)?.isNotEmpty == true ? q['id'] as String : 'q$i';
      _selectedOptions[qId] = <String>{};
      _customControllers[qId] = TextEditingController();
      _otherSelected[qId] = false;

      // 默认选中推荐项 (如果有 Recommended 且为单选)
      final options = (q['options'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
      final isMulti = q['is_multi_select'] == true;
      if (!isMulti && options.isNotEmpty) {
        final recommended = options.firstWhere(
          (o) => o.contains('(Recommended)'),
          orElse: () => options.first,
        );
        _selectedOptions[qId]!.add(recommended);
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _customControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submitAll() {
    final List<Map<String, dynamic>> result = [];
    for (int i = 0; i < _questions.length; i++) {
      final q = _questions[i];
      final qId = (q['id'] as String?)?.isNotEmpty == true ? q['id'] as String : 'q$i';
      final selected = _selectedOptions[qId]?.toList() ?? [];
      final custom = _customControllers[qId]?.text.trim() ?? '';
      final isOther = _otherSelected[qId] == true;

      final item = <String, dynamic>{
        'id': qId,
        'selected': selected,
      };
      if (isOther && custom.isNotEmpty) {
        item['custom'] = custom;
        if (!selected.contains(custom)) {
          selected.add(custom);
        }
      }
      result.add(item);
    }
    widget.onSubmit(result);
  }

  @override
  Widget build(BuildContext context) {
    if (_questions.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final currentQ = _questions[_currentIndex];
    final qId = (currentQ['id'] as String?)?.isNotEmpty == true ? currentQ['id'] as String : 'q$_currentIndex';
    final questionText = currentQ['question'] as String? ?? '请选择操作';
    final isMulti = currentQ['is_multi_select'] == true;
    final options = (currentQ['options'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final selectedSet = _selectedOptions[qId] ?? {};
    final isOtherActive = _otherSelected[qId] == true;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 580),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 36,
                spreadRadius: 4,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部导航栏：图标 + 题目进度 + 关闭按钮
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.help_outline_rounded,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _questions.length > 1
                            ? '交互式决策问答 (${_currentIndex + 1}/${_questions.length})'
                            : '交互式决策问答',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (_questions.length > 1) ...[
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_rounded, size: 16),
                        tooltip: '上一题',
                        onPressed: _currentIndex > 0
                            ? () => setState(() => _currentIndex--)
                            : null,
                      ),
                      Text(
                        '${_currentIndex + 1} of ${_questions.length}',
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                        tooltip: '下一题',
                        onPressed: _currentIndex < _questions.length - 1
                            ? () => setState(() => _currentIndex++)
                            : null,
                      ),
                    ],
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: widget.onCancel,
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // 问题文本
                Text(
                  questionText,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),

                // 选项列表
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < options.length; i++) ...[
                          _buildOptionTile(
                            index: i + 1,
                            text: options[i],
                            isSelected: selectedSet.contains(options[i]),
                            isMulti: isMulti,
                            theme: theme,
                            onTap: () {
                              setState(() {
                                if (isMulti) {
                                  if (selectedSet.contains(options[i])) {
                                    selectedSet.remove(options[i]);
                                  } else {
                                    selectedSet.add(options[i]);
                                  }
                                } else {
                                  selectedSet.clear();
                                  selectedSet.add(options[i]);
                                  _otherSelected[qId] = false;
                                }
                              });
                            },
                          ),
                          const SizedBox(height: 10),
                        ],

                        // 自定义 "Other" 选项
                        _buildOtherTile(
                          index: options.length + 1,
                          qId: qId,
                          isSelected: isOtherActive,
                          isMulti: isMulti,
                          theme: theme,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // 底部操作按钮
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        if (_currentIndex < _questions.length - 1) {
                          setState(() => _currentIndex++);
                        } else {
                          _submitAll();
                        }
                      },
                      child: const Text('Skip / 跳过'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        if (_currentIndex < _questions.length - 1) {
                          setState(() => _currentIndex++);
                        } else {
                          _submitAll();
                        }
                      },
                      child: Text(
                        _currentIndex < _questions.length - 1 ? 'Continue →' : '确认并继续',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOptionTile({
    required int index,
    required String text,
    required bool isSelected,
    required bool isMulti,
    required ThemeData theme,
    required VoidCallback onTap,
  }) {
    final isRecommended = text.contains('(Recommended)');
    final cleanText = text.replaceAll('(Recommended)', '').trim();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? theme.colorScheme.primary.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.6)
                  : Colors.white.withValues(alpha: 0.08),
              width: isSelected ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 序号徽章
              Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.only(top: 2),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? Colors.white : Colors.grey,
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // 选项正文与推荐标签
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isRecommended) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.amber.withValues(alpha: 0.4), width: 0.8),
                        ),
                        child: const Text(
                          'Recommended',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber),
                        ),
                      ),
                    ],
                    Text(
                      cleanText,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        color: isSelected ? theme.colorScheme.primary : null,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),

              // 单选/多选状态指示
              Icon(
                isMulti
                    ? (isSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded)
                    : (isSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded),
                color: isSelected ? theme.colorScheme.primary : Colors.grey.withValues(alpha: 0.5),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOtherTile({
    required int index,
    required String qId,
    required bool isSelected,
    required bool isMulti,
    required ThemeData theme,
  }) {
    final controller = _customControllers[qId]!;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _otherSelected[qId] = !isSelected;
            if (!isMulti && _otherSelected[qId] == true) {
              _selectedOptions[qId]?.clear();
            }
          });
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? theme.colorScheme.primary.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.6)
                  : Colors.white.withValues(alpha: 0.08),
              width: isSelected ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$index',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? Colors.white : Colors.grey,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Other (write your answer)',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.grey,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                  Icon(
                    isMulti
                        ? (isSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded)
                        : (isSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded),
                    color: isSelected ? theme.colorScheme.primary : Colors.grey.withValues(alpha: 0.5),
                    size: 20,
                  ),
                ],
              ),
              if (isSelected) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: controller,
                  autofocus: true,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: '输入你的自定义要求或决定...',
                    hintStyle: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                    isDense: true,
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: 0.2),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: theme.colorScheme.primary),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
