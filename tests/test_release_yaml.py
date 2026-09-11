"""Structure-aware YAML regression tests using only synthetic metadata."""
import importlib.util
from pathlib import Path
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'scripts/distribution/release_yaml.py'
spec = importlib.util.spec_from_file_location('release_yaml', MODULE)
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)

VALID = 'settings:\n  base:\n    MARKETING_VERSION: "1.2"\n    CURRENT_PROJECT_VERSION: 009\n'


class YAMLTests(unittest.TestCase):
    def test_notes_are_not_settings(self):
        notes = 'notes: |\n  MARKETING_VERSION: 9.0\n  CURRENT_PROJECT_VERSION: 99\n'
        with self.assertRaises(ValueError):
            parser.metadata(notes)
        self.assertEqual(parser.metadata(notes + VALID), ('1.2.0', '9'))

    def test_quoted_text_and_comments_ignored(self):
        self.assertEqual(parser.metadata(
            '# MARKETING_VERSION: 8.0\nnotes: "CURRENT_PROJECT_VERSION: 99"\n' + VALID),
            ('1.2.0', '9'))

    def test_duplicate_keys_anywhere_rejected(self):
        for text in (VALID + 'notes: first\nnotes: second\n',
                     VALID.replace('    CURRENT', '    MARKETING_VERSION: "1.2"\n    CURRENT'),
                     VALID + 'settings: {}\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parser.metadata(text)

    def test_unsafe_or_ambiguous_yaml_rejected(self):
        for text in ('notes: &a [1]\nother: *a\n', 'notes: &a [*a]\n',
                     'notes: !!python/object/apply:os.system ["false"]\n',
                     'notes: !!str hello\n', 'notes: [\n',
                     '---\nnotes: one\n---\nnotes: two\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parser.metadata(text + VALID)

    def test_settings_locations(self):
        for settings in (
                'settings: {MARKETING_VERSION: "1.2", CURRENT_PROJECT_VERSION: 9}\n',
                'settings:\n  configs:\n    Release:\n      MARKETING_VERSION: "1.2"\n      CURRENT_PROJECT_VERSION: 9\n',
                'targets:\n  Example:\n    settings:\n      base:\n        MARKETING_VERSION: "1.2"\n        CURRENT_PROJECT_VERSION: 9\n'):
            self.assertEqual(parser.metadata(settings), ('1.2.0', '9'))

    def test_wrong_locations_mixed_settings_and_conflicts(self):
        for text in (
                'notes:\n  MARKETING_VERSION: 1.2\n  CURRENT_PROJECT_VERSION: 9\n',
                'settings:\n  MARKETING_VERSION: 1.2\n  base:\n    CURRENT_PROJECT_VERSION: 9\n',
                VALID + 'targets:\n  Example:\n    settings:\n      MARKETING_VERSION: 2.0\n',
                VALID.replace('"1.2"', '|\n      1.2'),
                VALID.replace('009', '$(BUILD_NUMBER)')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parser.metadata(text)

    def test_source_spans_preserve_unrelated_bytes(self):
        text = '# 雪\r\nnotes: |\r\n  MARKETING_VERSION: 9.0\r\n' + VALID.replace('\n', '\r\n')
        spans = parser.declarations(text, 'MARKETING_VERSION', True)
        self.assertEqual(len(spans), 1)
        start, end, _ = spans[0]
        self.assertEqual(text[start:end], '"1.2"')
        updated = text[:start] + '"1.2.1"' + text[end:]
        self.assertIn('  MARKETING_VERSION: 9.0\r\n', updated)
        self.assertEqual(parser.metadata(updated), ('1.2.1', '9'))

    def test_limits(self):
        for text in ('notes: ' + '[' * 70 + '0' + ']' * 70,
                     'notes: ' + 'x' * (1024 * 1024)):
            with self.assertRaises(ValueError):
                parser.metadata(text)


if __name__ == '__main__':
    unittest.main()
