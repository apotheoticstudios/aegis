"""Synthetic-only Mail tests; exact fixture oracle, including problem notes."""
import hashlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import tracemalloc
import unittest
from contextlib import redirect_stdout, redirect_stderr
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / 'Fixtures' / 'generate'))
import generate
import mail as mail_fixtures
import mail_reader
import read
import reader_base
from common import NOW, aegis_contracts


class MailTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def build(self, profile='full', huge=False):
        generate.generate(self.root, seed=7, profile=profile, huge=huge)
        self.index = self.root / 'mail/V10/MailData/Envelope Index'
        self.expected = [json.loads(line) for line in (self.root / 'expected/mail.jsonl').read_text().splitlines()]
        self.problems = [p for p in json.loads((self.root / 'expected/problems.json').read_text()) if p['source'] == 'email']

    def write_message(self, rowid, overrides=None, body=b'Readable body', partial=False):
        headers = {'Message-ID': f'<test-{rowid}@example.com>', 'From': 'sender@example.com',
                   'Subject': 'Synthetic subject', 'Date': format_datetime(NOW),
                   'Content-Type': 'text/plain; charset=utf-8'}
        headers.update(overrides or {})
        raw = mail_fixtures.rfc822([(key, value) for key, value in headers.items() if value is not None], body)
        path = next((self.root / 'mail').rglob(f'{rowid}.emlx'))
        if partial:
            target = path.with_name(f'{rowid}.partial.emlx')
            path.rename(target)
            path = target
        path.write_bytes(mail_fixtures.emlx(raw, NOW))
        return path

    def snapshot(self):
        return {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (self.root / 'mail').rglob('*') if p.is_file() and not p.name.endswith('-shm')}

    def check_result(self, result):
        self.assertEqual(result.events, self.expected)
        self.assertEqual(result.problems, self.problems)
        self.assertEqual(result.status.code, 'ok' if self.expected else 'no_data')
        for event in result.events:
            self.assertEqual(aegis_contracts.validate_event(event), [])

    def test_full_exact_edge_cases_4_7_11_and_duplicates(self):
        self.build()
        before = self.snapshot()
        self.check_result(mail_reader.read_mail(self.index, now=NOW))
        self.check_result(mail_reader.read_mail(self.root / 'mail', now=NOW))
        self.assertEqual(self.snapshot(), before)

    def test_empty(self):
        self.build('empty')
        self.check_result(mail_reader.read_mail(self.index, now=NOW))

    def test_drift_without_conversation_id(self):
        self.build('drift')
        self.check_result(mail_reader.read_mail(self.index, now=NOW))
        self.assertTrue(all(e['thread_id'] is None for e in self.expected))

    def test_stream_and_window(self):
        self.build()
        items = []
        result = mail_reader.read_mail(self.index, now=NOW, on_item=lambda kind, item: items.append((kind, item)))
        self.assertEqual(result.events, [])
        self.assertEqual(result.problems, [])
        self.assertEqual([i for k, i in items if k == 'event'], self.expected)
        self.assertEqual([i for k, i in items if k == 'problem'], self.problems)
        cutoff = NOW - timedelta(hours=3)
        result = mail_reader.read_mail(self.index, now=NOW, since=cutoff)
        self.assertEqual(result.events, [e for e in self.expected if e['event_time'] >= reader_base.iso(cutoff)])

    def test_statuses_and_unknown_schema(self):
        self.assertEqual(mail_reader.read_mail(self.root / 'absent').status.code, 'not_found')
        self.build()
        with mock.patch('reader_base._uses_wal', side_effect=PermissionError):
            status = mail_reader.read_mail(self.index).status
        self.assertEqual((status.ok, status.code), (False, 'permission_denied'))
        with mock.patch('mail_reader._emlx', side_effect=PermissionError):
            self.assertEqual(mail_reader.read_mail(self.index).status.code, 'permission_denied')
        garbage = self.root / 'garbage'
        garbage.write_bytes(b'not sqlite' * 20)
        self.assertEqual(mail_reader.read_mail(garbage).status.code, 'unreadable')
        with sqlite3.connect(self.index) as conn:
            conn.execute('DROP TABLE messages')
        with self.assertRaises(reader_base.UnknownSchemaError):
            mail_reader.read_mail(self.index)

    @unittest.skipIf(hasattr(os, 'geteuid') and os.geteuid() == 0, 'root bypasses file modes')
    def test_unreadable_store_mode(self):
        self.build()
        self.index.chmod(0)
        try:
            self.assertEqual(mail_reader.read_mail(self.index).status.code, 'permission_denied')
        finally:
            self.index.chmod(0o600)

    def test_clock_skew_and_rejected_time(self):
        self.build()
        path = next((self.root / "mail").rglob("1.emlx"))
        original = path.read_bytes()
        # Same-length substitution preserves the emlx byte count.
        for year, code in ((b'2027', 'clock_skew'), (b'1999', 'timestamp_out_of_range')):
            path.write_bytes(original.replace(b'2026', year))
            result = mail_reader.read_mail(self.index, now=NOW)
            if code == 'clock_skew':
                self.assertIn(code, result.events[0]['flags'])
            else:
                self.assertTrue(any(p['code'] == code for p in result.problems))

    def test_malformed_headers_keep_the_message(self):
        # One bad header must not lose an email: the raw text, or the next time source, stands in.
        self.build()
        for rowid, header, value in ((1, 'Date', 'sometime last week'), (2, 'From', '<'), (3, 'Message-ID', '<@'),
                                     (4, 'From', 'J. Sample <jordan@example.com>'),
                                     (5, 'Message-ID', '1234.5678@mail.example.com')):
            self.write_message(rowid, {header: value})
        result = mail_reader.read_mail(self.index, now=NOW)
        self.assertEqual(result.status.code, 'ok')
        self.assertNotIn('message_parse_error', {p['code'] for p in result.problems})
        kept = [e for e in result.events if e['body'] == 'Readable body']
        self.assertEqual(len(kept), 5)
        records = {e['source_record_id'] for e in kept}
        self.assertTrue({'<@', '1234.5678@mail.example.com', '<test-4@example.com>'} <= records)
        self.assertTrue(any('jordan@example.com' in (e['sender'] or '') for e in kept))
        with sqlite3.connect(str(self.index)) as conn:
            received = conn.execute('SELECT date_received FROM messages WHERE ROWID = 1').fetchone()[0]
        conn.close()
        dated = next(e for e in kept if e['source_record_id'] == '<test-1@example.com>')
        self.assertEqual((dated['event_time'], dated['event_time_source']),
                         (reader_base.iso(datetime.fromtimestamp(received, timezone.utc)), 'received'))

    def test_python39_header_accessor_exceptions_fall_back_to_raw_text(self):
        self.build()
        original = mail_reader._emlx
        for header, error in (('Date', TypeError), ('From', IndexError), ('Message-ID', IndexError)):
            class BrokenHeader:
                def __init__(self, msg):
                    self.msg = msg

                def get(self, name, default=None):
                    if name == header:
                        raise error('synthetic message text must not leak')
                    return self.msg.get(name, default)

                def raw_items(self):
                    return self.msg.raw_items()

            def parse(path):
                msg, texts, encrypted = original(path)
                return (BrokenHeader(msg) if path.name == '1.emlx' else msg), texts, encrypted

            with self.subTest(header=header), mock.patch('mail_reader._emlx', side_effect=parse):
                result = mail_reader.read_mail(self.index, now=NOW)
            self.assertEqual(result.events, self.expected)
            self.assertEqual(result.problems, self.problems)

    def test_html_without_closing_head_keeps_the_body(self):
        self.build()
        self.write_message(1, {'Content-Type': 'text/html; charset=utf-8'},
                           body=b'<html><head><title>Promo</title><style>.a{color:red}</style><body><p>Hello there</p></body></html>')
        event = next(e for e in mail_reader.read_mail(self.index, now=NOW).events if e['source_record_id'] == '<test-1@example.com>')
        self.assertEqual(event['body'], 'Hello there')

    def test_deleted_as_a_flags_bit_on_older_layouts(self):
        # Some macOS releases have no `deleted` column; bit 1 of `flags` marks a deleted message.
        self.build()
        with sqlite3.connect(str(self.index)) as conn:
            conn.execute('ALTER TABLE messages DROP COLUMN deleted')
            conn.execute('ALTER TABLE messages ADD COLUMN flags INTEGER DEFAULT 0')
            conn.execute('UPDATE messages SET flags = 2 WHERE ROWID = 1')
        conn.close()
        result = mail_reader.read_mail(self.index, now=NOW)
        self.assertEqual(result.events, self.expected[1:])
        self.assertEqual(result.problems, self.problems)

    def test_index_dates_since_2001_on_older_builds(self):
        self.build()
        with sqlite3.connect(str(self.index)) as conn:
            conn.execute('UPDATE messages SET date_received = date_received - 978307200, date_sent = date_sent - 978307200')
        conn.close()
        cutoff = NOW - timedelta(hours=3)
        result = mail_reader.read_mail(self.index, now=NOW, since=cutoff)
        self.assertEqual(result.events, [e for e in self.expected if e['event_time'] >= reader_base.iso(cutoff)])
        self.write_message(1, {'Date': None})
        dated = next(e for e in mail_reader.read_mail(self.index, now=NOW).events if e['source_record_id'] == '<test-1@example.com>')
        self.assertEqual(dated['event_time_source'], 'received')
        self.assertTrue(dated['event_time'].startswith('2026-10-0'))

    def test_selected_rows_use_one_walk_and_sql_window_with_slack(self):
        self.build()
        cutoff = NOW - timedelta(hours=3)
        with sqlite3.connect(self.index) as conn:
            conn.executemany('UPDATE messages SET date_received=? WHERE ROWID=?',
                             [((cutoff - timedelta(days=1, seconds=1)).timestamp(), 1),
                              ((cutoff - timedelta(days=1)).timestamp(), 2),
                              ((cutoff - timedelta(days=2)).timestamp(), 18)])
            conn.execute('UPDATE messages SET deleted=1 WHERE ROWID=3')
        # Row 2's Date is in the exact window, but index time is at the slack boundary.
        self.write_message(2)
        parse, walk = mail_reader._emlx, mail_reader._index_files
        with mock.patch('mail_reader._emlx', wraps=parse) as opened, mock.patch('mail_reader._index_files', wraps=walk) as indexed:
            result = mail_reader.read_mail(self.index, now=NOW, since=cutoff)
        indexed.assert_called_once()
        names = {call.args[0].name for call in opened.call_args_list}
        self.assertFalse(names & {'1.emlx', '3.emlx', '18.emlx', '14.emlx', '15.emlx'})
        self.assertIn('2.emlx', names)
        self.assertIn('<test-2@example.com>', {e['source_record_id'] for e in result.events})
        self.assertTrue(all(e['event_time'] >= reader_base.iso(cutoff) for e in result.events))
        self.assertFalse(any(p['record'] == '18' for p in result.problems))

    def test_deleted_rows_and_empty_window_do_not_open_files(self):
        self.build()
        with sqlite3.connect(self.index) as conn:
            conn.execute('UPDATE messages SET deleted=1')
        with mock.patch('mail_reader._index_files') as indexed, mock.patch('mail_reader._emlx') as opened:
            result = mail_reader.read_mail(self.index, now=NOW)
        self.assertEqual((result.status.code, result.status.count, result.status.problems), ('no_data', 0, 0))
        indexed.assert_not_called()
        opened.assert_not_called()
        with sqlite3.connect(self.index) as conn:
            conn.execute('UPDATE messages SET deleted=0')
        with mock.patch('mail_reader._index_files') as indexed:
            result = mail_reader.read_mail(self.index, now=NOW, since=NOW + timedelta(days=3))
        self.assertEqual(result.status.code, 'no_data')
        indexed.assert_not_called()

    def test_file_vanishing_between_lookup_and_open(self):
        self.build()
        original = mail_reader._emlx

        def vanish(path):
            if path.name == '1.emlx':
                path.unlink()
            return original(path)

        with mock.patch('mail_reader._emlx', side_effect=vanish):
            result = mail_reader.read_mail(self.index, now=NOW)
        self.assertEqual(result.events, self.expected[1:])
        self.assertEqual(result.problems[0], reader_base.problem('body_file_missing', 'email', '1'))

    def test_html_omits_head_title_style_and_script(self):
        self.build()
        self.write_message(1, {'Content-Type': 'text/html; charset=utf-8'},
            b'<HEAD>metadata<title>Wrong title</title><style>.a{color:red}</style></HEAD>'
            b'<body><STYLE>hidden css</STYLE><script>var x=1;</script><title>hidden title</title>'
            b'<p>Hello &amp; welcome</p><p>  Next line. </p></body>')
        result = mail_reader.read_mail(self.index, now=NOW)
        self.assertEqual(result.events[0]['body'], 'Hello & welcome Next line.')

    def test_absent_headers_are_null_but_empty_headers_remain_empty(self):
        self.build()
        self.write_message(1, {'From': None, 'Subject': None})
        self.write_message(2, {'From': '', 'Subject': ''})
        result = mail_reader.read_mail(self.index, now=NOW)
        self.assertIsNone(result.events[0]['sender'])
        self.assertIsNone(result.events[0]['title'])
        self.assertEqual(result.events[1]['sender'], '')
        self.assertEqual(result.events[1]['title'], '')
        for event in result.events[:2]:
            self.assertEqual(aegis_contracts.validate_event(event), [])

    def test_partial_without_readable_text_remains_unavailable(self):
        self.build()
        self.write_message(1, {'Content-Type': 'application/pkcs7-mime'}, body=b'ciphertext', partial=True)
        self.write_message(2, {'Content-Type': 'image/jpeg'}, body=b'attachment', partial=True)
        self.write_message(3, body=b'', partial=True)
        result = mail_reader.read_mail(self.index, now=NOW)
        for event, flags in zip(result.events[:3], (['encrypted', 'truncated'], ['attachment_only', 'truncated'], ['truncated'])):
            self.assertEqual((event['content'], event['body'], event['flags']), ('unavailable', '', flags))
            self.assertEqual(aegis_contracts.validate_event(event), [])

    def test_wal_and_busy(self):
        self.build()
        with sqlite3.connect(self.index) as writer:
            writer.execute('PRAGMA journal_mode=WAL')
            writer.execute('UPDATE messages SET conversation_id=999 WHERE ROWID=1')
            writer.commit()
            before = self.snapshot()
            result = mail_reader.read_mail(self.index, now=NOW)
            self.assertEqual(result.events[0]['thread_id'], '999')
            self.assertEqual(self.snapshot(), before)
        writer.close()
        for suffix in ("-wal", "-shm"):
            Path(str(self.index) + suffix).unlink(missing_ok=True)
        before = self.snapshot()
        mail_reader.read_mail(self.index, now=NOW)
        self.assertEqual(self.snapshot(), before)  # absent sidecars: private copy
        with mock.patch('reader_base._private_copy', side_effect=sqlite3.OperationalError('database busy')):
            self.assertEqual(mail_reader.read_mail(self.index).status.code, 'busy')

    def test_cli_counts_only(self):
        self.build()
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = read.main(['--fixtures', str(self.root), '--source', 'mail'])
        self.assertEqual(code, 0)
        self.assertRegex(out.getvalue(), r'mail\s+ok\s+events 20')
        for event in self.expected:
            for field in ('body', 'title', 'sender'):
                if event[field]:
                    self.assertNotIn(event[field], out.getvalue() + err.getvalue())

    def test_large_candidate_index_streams_with_bounded_memory(self):
        self.build()
        with sqlite3.connect(self.index) as conn:
            conn.executemany('INSERT INTO messages (ROWID, date_received, deleted) VALUES (?, ?, 0)',
                             ((1000 + i, NOW.timestamp()) for i in range(20000)))
        tracemalloc.start()
        try:
            result = mail_reader.read_mail(self.index, now=NOW, on_item=lambda kind, item: None)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual((result.status.count, result.status.problems), (len(self.expected), len(self.problems) + 20000))
        self.assertEqual((result.events, result.problems), ([], []))
        self.assertLess(peak, 4 * 2**20)

    @unittest.skipUnless(os.environ.get('AEGIS_FIXTURES_HUGE') == '1', 'set AEGIS_FIXTURES_HUGE=1')
    def test_huge_attachment_is_skipped_with_bounded_memory(self):
        self.build(huge=True)
        events, problems = [], []
        tracemalloc.start()
        try:
            result = mail_reader.read_mail(self.index, now=NOW, on_item=lambda k, i: (events if k == 'event' else problems).append(i))
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(events, self.expected)
        self.assertEqual(problems, self.problems)
        self.assertEqual(result.events, [])
        self.assertLess(peak, 4 * 2**20)


if __name__ == '__main__':
    unittest.main()
