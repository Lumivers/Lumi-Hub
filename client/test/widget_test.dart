import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:lumi_client/screens/chat_screen.dart';

void main() {
  testWidgets('CodeElementBuilder renders inline code pill cleanly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: MarkdownBody(
              data: '正在开发 `robocon-fsm` 机器人',
              builders: {'code': CodeElementBuilder()},
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final finder = find.text('robocon-fsm');
    expect(finder, findsOneWidget);

    final textWidget = tester.widget<Text>(finder);
    expect(textWidget.data, 'robocon-fsm');
    final renderParagraph = tester.renderObject<RenderParagraph>(find.descendant(of: finder, matching: find.byType(RichText)));
    expect(renderParagraph.text.toPlainText(), 'robocon-fsm');
  });
}

