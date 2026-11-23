// Regression tests for the safe-JSON helpers (build 31 crash hunt).
//
// Every helper must return its default — never throw — on a value of
// the wrong type, and must behave exactly like the old `as X?` casts
// on well-typed data.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/storage/safe_json.dart';

void main() {
  group('jStr', () {
    test('string passes through, other types fall back', () {
      expect(jStr('a'), 'a');
      expect(jStr(123), '');
      expect(jStr(1.5), '');
      expect(jStr(true), '');
      expect(jStr(null), '');
      expect(jStr(['a']), '');
      expect(jStr({'a': 1}), '');
      expect(jStr(123, 'd'), 'd');
      expect(jStr(null, 'd'), 'd');
    });
  });

  group('jStrN', () {
    test('string passes through, other types are null', () {
      expect(jStrN('a'), 'a');
      expect(jStrN(123), isNull);
      expect(jStrN(null), isNull);
    });
  });

  group('jInt / jIntN', () {
    test('num converts, other types fall back', () {
      expect(jInt(5), 5);
      expect(jInt(5.9), 5);
      expect(jInt('5'), 0);
      expect(jInt('5', 7), 7);
      expect(jInt(true), 0);
      expect(jInt(null), 0);
      expect(jIntN(5), 5);
      expect(jIntN(5.9), 5);
      expect(jIntN('5'), isNull);
      expect(jIntN(null), isNull);
    });
  });

  group('jDouble / jDoubleN', () {
    test('num converts, other types fall back', () {
      expect(jDouble(5), 5.0);
      expect(jDouble(5.5), 5.5);
      expect(jDouble('5.5'), 0.0);
      expect(jDouble(null), 0.0);
      expect(jDoubleN(5), 5.0);
      expect(jDoubleN('5.5'), isNull);
    });
  });

  group('jBool / jBoolN', () {
    test('bool passes through, other types fall back', () {
      expect(jBool(true), isTrue);
      expect(jBool(false), isFalse);
      expect(jBool(1), isFalse);
      expect(jBool('true'), isFalse);
      expect(jBool(1, true), isTrue);
      expect(jBool(null), isFalse);
      expect(jBoolN(true), isTrue);
      expect(jBoolN(1), isNull);
    });
  });

  group('jList / jListN', () {
    test('list passes through, other types fall back', () {
      expect(jList([1, 2]), [1, 2]);
      expect(jList('x'), isEmpty);
      expect(jList(null), isEmpty);
      expect(jListN([1]), [1]);
      expect(jListN('x'), isNull);
    });
  });

  group('jMap / jMapN', () {
    test('map passes through, other types fall back', () {
      expect(jMap({'a': 1}), {'a': 1});
      expect(jMap('x'), isEmpty);
      expect(jMap(null), isEmpty);
      expect(jMapN({'a': 1}), {'a': 1});
      expect(jMapN('x'), isNull);
      expect(jMapN(null), isNull);
    });
  });
}
