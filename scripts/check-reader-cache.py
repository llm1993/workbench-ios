"""Execute SQL extracted from the actual native reader against disposable SQLite.
No production database, API, Xcode, Actions or packaging is involved.
"""
from pathlib import Path
import re
import sqlite3
import unittest

source = (Path(__file__).resolve().parents[1] / 'Modules/WeiduKit/Data/Database.swift').read_text(encoding='utf-8')
schema = re.search(r'private func migrate\(\).*?exec\("""(.*?)"""\)', source, re.S)[1]
feed_sql, entry_sql = re.findall(r'try cloudWrite\("""(.*?)""",', source, re.S)


class ReaderCacheTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.executescript(schema)
        self.db.execute('ALTER TABLE feeds ADD COLUMN auto_fulltext INTEGER NOT NULL DEFAULT 0')
        self.feed()

    def tearDown(self):
        self.db.close()

    def feed(self, fid='1', title='Original', url='https://fixture.invalid/rss'):
        self.db.execute(feed_sql, (fid, url, title, '', '', 'Group', 0, 1, None, None, 1))

    def entry(self, eid=9, body='', fulltext=None, detail=False, read=0, star=0, fid='1'):
        self.db.execute(entry_sql, (f'{eid:020d}', fid, str(eid), 'Article', 'https://fixture.invalid/article',
            '', 'summary', body, fulltext, '', None, 1, read, star, int(detail), int(detail)))

    def body(self):
        return self.db.execute('SELECT content_html,fulltext_html,is_read,is_starred FROM entries').fetchone()

    def test_metadata_refresh_preserves_body_and_fulltext(self):
        self.entry(body='source', fulltext='full', detail=True)
        self.entry(read=1, star=1)
        self.assertEqual(self.body(), ('source', 'full', 1, 1))

    def test_detail_replaces_source_and_can_clear_removed_fulltext(self):
        self.entry(body='old', fulltext='old full', detail=True)
        self.entry(body='new', detail=True)
        self.assertEqual(self.body(), ('new', None, 0, 0))

    def test_padded_ids_keep_server_numeric_order_on_equal_dates(self):
        for eid in [9, 10, 100, 2]: self.entry(eid=eid)
        rows = self.db.execute('SELECT id FROM entries ORDER BY fetched_at DESC,id DESC').fetchall()
        self.assertEqual([int(row[0]) for row in rows], [100, 10, 9, 2])

    def test_feed_update_keeps_cache_and_unsubscribe_cascades(self):
        self.entry(body='cached', detail=True)
        self.feed(title='Renamed')
        self.assertEqual(self.body()[0], 'cached')
        self.db.execute('DELETE FROM feeds WHERE id=?', ('1',))
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM entries').fetchone()[0], 0)

    def test_foreign_feed_is_not_silently_cached(self):
        with self.assertRaises(sqlite3.IntegrityError): self.entry(fid='unknown')

    def test_list_batch_failure_rolls_back_earlier_rows(self):
        self.entry(eid=1, body='source', fulltext='full', detail=True)
        self.db.commit()
        with self.assertRaises(sqlite3.IntegrityError):
            with self.db:
                self.entry(eid=1, read=1)
                self.entry(eid=2, fid='unknown')
        self.assertEqual(self.body(), ('source', 'full', 0, 0))
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM entries').fetchone()[0], 1)

    def test_bulk_list_read_excludes_bodies_and_deduplicates_ids(self):
        self.entry(eid=1, body='source', fulltext='full', detail=True)
        self.entry(eid=2, read=1, star=1)
        columns = re.search(r'static let listColumns\s*=\s*"([^"]+)"', source)[1]
        bulk_read = source.split('func listEntries(ids:')[1].split('func entry(id:')[0]
        query = re.search(r'prepare\("([^"]+)"\)', bulk_read)[1]
        query = query.replace(r'\(Database.listColumns)', columns).replace(r'\(placeholders)', '?,?,?')
        rows = self.db.execute(query, (f'{1:020d}', f'{2:020d}', f'{1:020d}')).fetchall()
        self.assertEqual(len(rows), 2)
        self.assertEqual({row[0] for row in rows}, {f'{1:020d}', f'{2:020d}'})
        self.assertNotIn('e.content_html', columns)
        self.assertNotIn('e.fulltext_html', columns)

    def test_selected_feeds_do_not_include_other_cached_subscriptions(self):
        self.feed(fid='2', url='https://other.invalid/rss')
        self.entry(eid=1, fid='1'); self.entry(eid=2, fid='2')
        rows = self.db.execute('SELECT e.id FROM entries e JOIN feeds f ON f.id=e.feed_id WHERE e.feed_id IN (?)', ('1',)).fetchall()
        self.assertEqual([int(row[0]) for row in rows], [1])


if __name__ == '__main__': unittest.main()
