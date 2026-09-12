// The model's answers arrive with **bold** and "- " bullets; showing those literally makes a
// reply read like a config file. These pin the small formatter that handles them.
import 'package:agent_os/answer_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _style = TextStyle(fontSize: 15);

void main() {
  group('parseAnswer', () {
    test('a blank line becomes one gap, however many there are', () {
      final blocks = parseAnswer('first\n\n\n\nsecond');
      expect(blocks, [
        const AnswerBlock(AnswerBlockKind.paragraph, 'first'),
        const AnswerBlock(AnswerBlockKind.gap, ''),
        const AnswerBlock(AnswerBlockKind.paragraph, 'second'),
      ]);
    });

    test('recognises the bullet markers the model actually uses', () {
      final blocks = parseAnswer('- one\n* two\n• three');
      expect(blocks.map((b) => b.kind), everyElement(AnswerBlockKind.bullet));
      expect(blocks.map((b) => b.text), ['one', 'two', 'three']);
    });

    test('leading and trailing blank lines do not create stray gaps', () {
      expect(parseAnswer('\n\nonly\n\n'), [
        const AnswerBlock(AnswerBlockKind.paragraph, 'only'),
      ]);
    });

    test('a real answer keeps its shape', () {
      final blocks = parseAnswer(
        'Based on the DATED ITEMS section, you have two deadlines:\n'
        '\n'
        '- **Overdue**: Assignment submission (due 2026-09-08)\n'
        '- **Soon**: Online assessment (due 2026-09-14)\n',
      );
      expect(blocks.map((b) => b.kind), [
        AnswerBlockKind.paragraph,
        AnswerBlockKind.gap,
        AnswerBlockKind.bullet,
        AnswerBlockKind.bullet,
      ]);
    });
  });

  group('boldSpans', () {
    test('splits **bold** out of the surrounding text', () {
      final spans = boldSpans('a **b** c', _style);
      expect(spans.map((s) => s.text), ['a ', 'b', ' c']);
      expect(spans[1].style?.fontWeight, FontWeight.w700);
      expect(spans[0].style?.fontWeight, isNot(FontWeight.w700));
    });

    test('an unclosed marker is left alone rather than eating the answer', () {
      final spans = boldSpans('a **b c', _style);
      expect(spans.single.text, 'a **b c');
    });

    test('plain text yields one span', () {
      expect(boldSpans('nothing special', _style).single.text, 'nothing special');
    });
  });

  testWidgets('AnswerText shows the words, never the asterisks', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AnswerText(text: '- **Overdue**: submission', style: _style),
        ),
      ),
    );

    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('Overdue'), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
  });
}
