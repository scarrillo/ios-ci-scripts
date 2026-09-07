"""Neutral release-policy fixtures. No hosted enforcement is simulated."""
import importlib.util
from pathlib import Path
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'scripts/distribution/release-state.py'
spec = importlib.util.spec_from_file_location('release_state', MODULE)
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class ReleaseStateTests(unittest.TestCase):
    def test_normalization(self):
        self.assertEqual(state.version('01.08'), (1, 8, 0))
        self.assertEqual(state.build('009'), 9)
        for value in ('', '1', '1.2-beta', '1.2.3.4', ' 1.2', None):
            with self.assertRaises(ValueError):
                state.version(value)
        for value in ('', '-1', '1.0', ' 1', None):
            with self.assertRaises(ValueError):
                state.build(value)

    def test_new_and_unchanged(self):
        self.assertEqual(state.preparation('1.0', '1'), 'new')
        self.assertEqual(state.preparation(None, None, changed=False), 'skip')
        with self.assertRaises(ValueError):
            state.preparation('1.0', 'bad')

    def test_equal_bumps_only_writable(self):
        self.assertEqual(state.preparation('1.2.0', '09', base=('1.2', '9')), 'bump')
        with self.assertRaisesRegex(ValueError, 'contributor-authored'):
            state.preparation('1.2', '9', base=('1.2', '9'), writable=False)

    def test_manual_and_rerun_preserve(self):
        for writable in (True, False):
            for attempt in range(2):
                self.assertEqual(state.preparation('1.3', '10', base=('1.2', '9'),
                                                   writable=writable), 'preserve')

    def test_stale_or_mixed_edits_rejected(self):
        for head in (('1.1', '10'), ('1.3', '8'), ('1.3', '9'), ('1.2', '10')):
            with self.subTest(head=head), self.assertRaises(ValueError):
                state.preparation(*head, base=('1.2', '9'))

    def test_current_base_advance_requires_new_bump(self):
        self.assertEqual(state.preparation('1.2.1', '10', base=('1.2', '9')), 'preserve')
        self.assertEqual(state.preparation('1.2.1', '10', base=('1.2.1', '10')), 'bump')

    def test_baseline_excludes_future_and_unrelated(self):
        tags = [('old', '1.0', 'a'), ('current', '1.1', 'b'),
                ('future', '2.0', 'c'), ('unrelated', '9.0', 'x')]
        self.assertEqual(state.baseline(tags, ['a', 'b']), 'current')
        self.assertEqual(state.baseline(list(reversed(tags)), ['a', 'b']), 'current')
        self.assertIsNone(state.baseline(tags, []))

    def test_baseline_ambiguity_and_invalid_metadata(self):
        with self.assertRaises(ValueError):
            state.baseline([('a', '1.0', 'x'), ('b', '1.0.0', 'y')], ['x', 'y'])
        with self.assertRaises(ValueError):
            state.baseline([('a', 'bad', 'x')], ['x'])


if __name__ == '__main__':
    unittest.main()
