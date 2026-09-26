import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/desktop/apps/shortcuts.dart';

void main() {
  group('psQuote', () {
    test('doubles ASCII and typographic single quotes', () {
      expect(psQuote("L'app"), "L''app");
      expect(psQuote('L\u2019app'), 'L\u2019\u2019app');
      expect(psQuote('\u2018a\u201Ab\u201B'), '\u2018\u2018a\u201A\u201Ab\u201B\u201B');
      expect(psQuote('plain "double" quotes'), 'plain "double" quotes');
    });

    test('a hostile label cannot break out of the string', () {
      final quoted = psQuote('x\u2019;Remove-Item C:\\ -Recurse;\u2019');
      // Every quote-like character now comes in pairs, i.e. stays literal.
      final quotes = RegExp('[\'\u2018\u2019\u201A\u201B]+').allMatches(quoted).map((m) => m[0]!.length);
      expect(quotes.every((n) => n.isEven), isTrue);
    });
  });

  group('shortcutBaseName', () {
    test('strips forbidden characters', () {
      expect(shortcutBaseName(r'a\b/c:d*e?f"g<h>i|j'), 'abcdefghij');
    });

    test('trims trailing dots and spaces', () {
      expect(shortcutBaseName('Mon app. . '), 'Mon app');
      expect(shortcutBaseName('  Nom  '), 'Nom');
    });

    test('falls back to Application when nothing is left', () {
      expect(shortcutBaseName(''), 'Application');
      expect(shortcutBaseName('<>|...'), 'Application');
    });

    test('caps the length at 100 characters', () {
      expect(shortcutBaseName('a' * 250), hasLength(100));
      expect(shortcutBaseName('${'a' * 99}. b'), 'a' * 99);
    });
  });
}
