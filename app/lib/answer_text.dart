import 'package:flutter/material.dart';

/// Renders the small amount of Markdown the model actually emits.
///
/// Answers routinely come back with `**bold**` and `- ` bullets — the mail prompt asks for
/// summaries and lists — and showing those literally makes the reply look like a config file
/// rather than an answer. This handles exactly the three things that show up in practice, in
/// about eighty lines, rather than adding a Markdown package and a second text pipeline for a
/// feature set nothing here uses (no tables, images, links or code blocks).
///
/// Anything it does not understand is shown verbatim, which is the right failure: a stray
/// asterisk is a blemish, a thrown exception is a broken screen.
enum AnswerBlockKind { paragraph, bullet, gap }

@immutable
class AnswerBlock {
  const AnswerBlock(this.kind, this.text);

  final AnswerBlockKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is AnswerBlock && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => '${kind.name}("$text")';
}

/// Splits an answer into paragraphs, bullets and the gaps between them.
List<AnswerBlock> parseAnswer(String answer) {
  final blocks = <AnswerBlock>[];
  var pendingGap = false;

  for (final raw in answer.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      // Collapse runs of blank lines: one gap is a paragraph break, three is a hole.
      if (blocks.isNotEmpty) pendingGap = true;
      continue;
    }
    if (pendingGap) {
      blocks.add(const AnswerBlock(AnswerBlockKind.gap, ''));
      pendingGap = false;
    }
    final bullet = RegExp(r'^\s*[-*•]\s+').firstMatch(line);
    if (bullet != null) {
      blocks.add(AnswerBlock(AnswerBlockKind.bullet, line.substring(bullet.end)));
    } else {
      blocks.add(AnswerBlock(AnswerBlockKind.paragraph, line.trim()));
    }
  }
  return blocks;
}

/// Splits one line on `**bold**`, keeping the text in order.
///
/// An unclosed `**` is left as written rather than swallowing the rest of the answer.
List<TextSpan> boldSpans(String line, TextStyle base) {
  final spans = <TextSpan>[];
  final pattern = RegExp(r'\*\*(.+?)\*\*');
  var index = 0;

  for (final match in pattern.allMatches(line)) {
    if (match.start > index) {
      spans.add(TextSpan(text: line.substring(index, match.start), style: base));
    }
    spans.add(TextSpan(
      text: match.group(1),
      style: base.copyWith(fontWeight: FontWeight.w700),
    ));
    index = match.end;
  }
  if (index < line.length) {
    spans.add(TextSpan(text: line.substring(index), style: base));
  }
  return spans.isEmpty ? [TextSpan(text: line, style: base)] : spans;
}

/// An assistant answer, formatted.
class AnswerText extends StatelessWidget {
  const AnswerText({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final blocks = parseAnswer(text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks)
          switch (block.kind) {
            AnswerBlockKind.gap => const SizedBox(height: 12),
            AnswerBlockKind.bullet => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 2, right: 10, top: 1),
                      child: Text('•', style: style),
                    ),
                    Expanded(
                      child: SelectableText.rich(
                        TextSpan(children: boldSpans(block.text, style)),
                      ),
                    ),
                  ],
                ),
              ),
            AnswerBlockKind.paragraph => SelectableText.rich(
                TextSpan(children: boldSpans(block.text, style)),
              ),
          },
      ],
    );
  }
}
